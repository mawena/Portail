#define _GNU_SOURCE
/* Phase 17, T2 : créer, supprimer et formater une partition, place occupée. Les partitions écrites sont
 * extraites dans des fichiers et jugées par fsck.fat, fsck.exfat, e2fsck, ntfsfix et cryptsetup (PC). */
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "fluluks/blockdev.h"
#include "fluluks/error.h"
#include "fluluks/format.h"
#include "fluluks/fs.h"
#include "fluluks/partedit.h"
#include "fluluks/partops.h"
#include "fluluks/probe.h"
#include "fsck_util.h"
#include "tt.h"

#define MIB (1024ull * 1024ull)
#define M 2048ull /* secteurs de 512 octets par Mio */

static char g_out[65536];
static const char PASS[] = "phrase de test";

static int image(char *path, size_t cap, const char *nom, uint64_t bytes) {
  char td[4096];
  if (fu_tmpdir(td, sizeof td) != 0) return -1;
  snprintf(path, cap, "%s/%s", td, nom);
  int fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0644);
  if (fd < 0) return -1;
  int rc = ftruncate(fd, (off_t)bytes);
  close(fd);
  return rc;
}

static fl_bdev *ouvrir(const char *path) {
  fl_bdev *d = NULL;
  return fl_file_bdev_open(path, 512, false, &d) == FL_OK ? d : NULL;
}

/* Copie de [first, first + count) de l'image dans un fichier à part (creux), pour les juges. */
static int extraire(const char *img, uint64_t first, uint64_t count, char *out, size_t cap) {
  char td[4096];
  if (fu_tmpdir(td, sizeof td) != 0) return -1;
  snprintf(out, cap, "%s/extrait-%llu.img", td, (unsigned long long)first);
  int in = open(img, O_RDONLY), o = open(out, O_RDWR | O_CREAT | O_TRUNC, 0644);
  if (in < 0 || o < 0 || ftruncate(o, (off_t)(count * 512)) != 0) return -1;
  static uint8_t buf[MIB];
  static const uint8_t zero[64 * 1024];
  for (uint64_t off = 0; off < count * 512; off += sizeof buf) {
    size_t n = count * 512 - off < sizeof buf ? (size_t)(count * 512 - off) : sizeof buf;
    if (pread(in, buf, n, (off_t)(first * 512 + off)) != (ssize_t)n) return -1;
    for (size_t k = 0; k < n; k += sizeof zero) {
      size_t z = n - k < sizeof zero ? n - k : sizeof zero;
      if (memcmp(buf + k, zero, z) != 0 && pwrite(o, buf + k, z, (off_t)(off + k)) != (ssize_t)z) return -1;
    }
  }
  close(in);
  close(o);
  return 0;
}

/* Lit [first, first + count) dans un tampon alloué (comparaison des voisines). */
static uint8_t *lire(const char *img, uint64_t first, uint64_t count) {
  uint8_t *b = malloc(count * 512);
  int fd = open(img, O_RDONLY);
  if (!b || fd < 0 || pread(fd, b, count * 512, (off_t)(first * 512)) != (ssize_t)(count * 512)) {
    free(b);
    b = NULL;
  }
  if (fd >= 0) close(fd);
  return b;
}

/* Disque GPT ou MBR de 256 Mio : partition 1 de 1 à 21 Mio, partition 2 de 101 à 121 Mio, remplies d'octets
 * reconnaissables ; le trou de 21 à 101 Mio reste libre. */
static fl_bdev *disque(char *img, size_t cap, const char *nom, fl_pt_kind kind) {
  if (image(img, cap, nom, 256 * MIB) != 0) return NULL;
  fl_bdev *d = ouvrir(img);
  fl_pt_layout l;
  if (!d || fl_pt_new_table(d, kind) != FL_OK || fl_pt_load(d, &l) != FL_OK) return d;
  memset(l.e, 0, 2 * sizeof l.e[0]);
  l.e[0].index = 1;
  l.e[0].first_lba = M;
  l.e[0].sector_count = 20 * M;
  l.e[1].index = 2;
  l.e[1].first_lba = 101 * M;
  l.e[1].sector_count = 20 * M;
  l.e[0].mbr_type = l.e[1].mbr_type = 0x83;
  l.e[0].gpt_type[0] = l.e[1].gpt_type[0] = 0xAF;
  l.count = 2;
  if (fl_pt_store(d, &l) != FL_OK) return d;
  static uint8_t motif[MIB];
  memset(motif, 0x5A, sizeof motif);
  for (uint64_t i = 0; i < 20; i++) {
    fl_bdev_write(d, M + i * M, M, motif);
    fl_bdev_write(d, 101 * M + i * M, M, motif);
  }
  fl_bdev_flush(d);
  return d;
}

static fl_fmt_opts opts(fl_fmt_fs fs, bool chiffre, const char *label) {
  fl_fmt_opts o;
  memset(&o, 0, sizeof o);
  o.fs = fs;
  o.encrypted = chiffre;
  o.label = label;
  o.kdf_mem_kib = 8192;
  o.root_uid = o.root_gid = 1000;
  return o;
}

static int juge(const char *part, fl_fmt_fs fs, bool chiffre) {
  if (chiffre) {
    char *a[] = {"cryptsetup", "luksDump", (char *)part, NULL};
    if (fu_run(a, g_out, sizeof g_out) != 0) return -1;
    char pf[4096], plain[4096];
    snprintf(pf, sizeof pf, "%s.pass", part);
    FILE *f = fopen(pf, "wb");
    fwrite(PASS, 1, strlen(PASS), f);
    fclose(f);
    if (fu_extract_luks_ext4(part, pf, plain, sizeof plain) != 0) return -1;
    int rc = fu_e2fsck_n(plain, g_out, sizeof g_out);
    unlink(plain);
    unlink(pf);
    return rc;
  }
  switch (fs) {
    case FL_FMT_EXT4: return fu_e2fsck_n(part, g_out, sizeof g_out);
    case FL_FMT_NTFS: return fu_ntfsfix_n(part, g_out, sizeof g_out);
    default: return fu_fsck_fat_n(part, g_out, sizeof g_out);
  }
}

static void test_create_in_free_space_judged(void) {
  struct { fl_fmt_fs fs; bool chiffre; } cas[] = {
      {FL_FMT_FAT32, false}, {FL_FMT_EXFAT, false}, {FL_FMT_EXT4, false}, {FL_FMT_NTFS, false}, {FL_FMT_EXT4, true}};
  for (size_t i = 0; i < sizeof cas / sizeof cas[0]; i++) {
    char img[4096], part[4096];
    fl_bdev *d = disque(img, sizeof img, "po-create.img", i % 2 ? FL_PT_MBR : FL_PT_GPT);
    TT_ASSERT(d != NULL);
    uint8_t *v1 = lire(img, M, 20 * M), *v2 = lire(img, 101 * M, 20 * M);
    fl_fmt_opts o = opts(cas[i].fs, cas[i].chiffre, "NOUVELLE");
    uint32_t index = 0;
    int rc = fl_part_create(d, 21 * M, 64 * M, &o, PASS, strlen(PASS), NULL, NULL, &index);
    fl_bdev_close(d);
    TT_ASSERT_EQ(rc, FL_OK);
    TT_ASSERT_EQ(index, 3);
    uint8_t *w1 = lire(img, M, 20 * M), *w2 = lire(img, 101 * M, 20 * M);
    TT_ASSERT(v1 && v2 && w1 && w2);
    TT_ASSERT_MEM_EQ(v1, w1, 20 * MIB);
    TT_ASSERT_MEM_EQ(v2, w2, 20 * MIB);
    free(v1); free(v2); free(w1); free(w2);
    char *a[] = {"sfdisk", "--verify", img, NULL};
    TT_ASSERT_EQ(fu_run(a, g_out, sizeof g_out), 0);
    TT_ASSERT_EQ(extraire(img, 21 * M, 64 * M, part, sizeof part), 0);
    rc = juge(part, cas[i].fs, cas[i].chiffre);
    if (rc != 0) fprintf(stderr, "cas %zu : %s\n", i, g_out);
    TT_ASSERT_EQ(rc, 0);
    unlink(part);
    if (getenv("FL_KEEP")) { /* gardée pour tools/fixtures/verify_partitions_with_kernel.sh */
      static const char *noms[] = {"fat32", "exfat", "ext4", "ntfs", "ext4"};
      char garde[4200];
      snprintf(garde, sizeof garde, "%.*s/partops-%s-%s-%s.img", (int)(strrchr(img, '/') - img), img, noms[i],
               cas[i].chiffre ? "luks" : "clair", i % 2 ? "mbr" : "gpt");
      TT_ASSERT_EQ(rename(img, garde), 0);
    } else {
      unlink(img);
    }
  }
}

static void test_create_type_matches_fs(void) {
  struct { fl_pt_kind kind; fl_fmt_fs fs; bool chiffre; uint8_t mbr; uint8_t gpt0; } cas[] = {
      {FL_PT_MBR, FL_FMT_FAT32, false, 0x0C, 0}, {FL_PT_MBR, FL_FMT_NTFS, false, 0x07, 0},
      {FL_PT_MBR, FL_FMT_EXFAT, true, 0x83, 0},  {FL_PT_GPT, FL_FMT_EXFAT, false, 0, 0xA2},
      {FL_PT_GPT, FL_FMT_EXT4, false, 0, 0xAF}};
  for (size_t i = 0; i < sizeof cas / sizeof cas[0]; i++) {
    char img[4096];
    fl_bdev *d = disque(img, sizeof img, "po-type.img", cas[i].kind);
    fl_fmt_opts o = opts(cas[i].fs, cas[i].chiffre, "");
    uint32_t index = 0;
    TT_ASSERT_EQ(fl_part_create(d, 21 * M, 40 * M, &o, PASS, strlen(PASS), NULL, NULL, &index), FL_OK);
    fl_pt_layout l;
    TT_ASSERT_EQ(fl_pt_load(d, &l), FL_OK);
    fl_bdev_close(d);
    TT_ASSERT_EQ(l.count, 3);
    TT_ASSERT_EQ(l.e[2].index, index);
    TT_ASSERT_EQ(l.e[2].mbr_type, cas[i].mbr);
    TT_ASSERT_EQ(l.e[2].gpt_type[0], cas[i].gpt0);
    unlink(img);
  }
}

static void test_create_too_small_refused(void) {
  char img[4096];
  fl_bdev *d = disque(img, sizeof img, "po-small.img", FL_PT_GPT);
  uint8_t *avant = lire(img, 0, 128 * M);
  fl_fmt_opts o = opts(FL_FMT_FAT32, false, "");
  uint32_t index = 0;
  TT_ASSERT_EQ(fl_part_create(d, 21 * M, 16 * M, &o, NULL, 0, NULL, NULL, &index), FL_ENOSPC);
  o = opts(FL_FMT_EXT4, true, "");
  TT_ASSERT_EQ(fl_part_create(d, 21 * M, 20 * M, &o, PASS, strlen(PASS), NULL, NULL, &index), FL_ENOSPC);
  o = opts(FL_FMT_EXT4, false, "");
  TT_ASSERT_EQ(fl_part_create(d, 15 * M, 20 * M, &o, NULL, 0, NULL, NULL, &index), FL_EINVAL); /* chevauche */
  TT_ASSERT_EQ(fl_part_create(d, 21 * M + 1, 20 * M, &o, NULL, 0, NULL, NULL, &index), FL_EINVAL); /* non aligné */
  fl_bdev_close(d);
  uint8_t *apres = lire(img, 0, 128 * M);
  TT_ASSERT_MEM_EQ(avant, apres, 128 * MIB);
  free(avant);
  free(apres);
  unlink(img);
}

static void test_delete_keeps_others(void) {
  char img[4096];
  fl_bdev *d = disque(img, sizeof img, "po-del.img", FL_PT_MBR);
  uint8_t *v2 = lire(img, 101 * M, 20 * M), *p1 = lire(img, M, 20 * M);
  TT_ASSERT_EQ(fl_part_delete(d, 1, M), FL_OK);
  fl_pt_layout l;
  TT_ASSERT_EQ(fl_pt_load(d, &l), FL_OK);
  fl_bdev_close(d);
  TT_ASSERT_EQ(l.count, 1);
  TT_ASSERT_EQ(l.e[0].index, 2);
  uint8_t *w2 = lire(img, 101 * M, 20 * M), *q1 = lire(img, M, 20 * M);
  TT_ASSERT_MEM_EQ(v2, w2, 20 * MIB);
  TT_ASSERT_MEM_EQ(p1, q1, 20 * MIB); /* données non effacées */
  free(v2); free(w2); free(p1); free(q1);
  unlink(img);
}

static void test_format_one_partition_only(void) {
  char img[4096], part[4096];
  fl_bdev *d = disque(img, sizeof img, "po-fmt.img", FL_PT_GPT);
  fl_fmt_opts o = opts(FL_FMT_EXT4, false, "");
  uint32_t index = 0;
  TT_ASSERT_EQ(fl_part_create(d, 21 * M, 64 * M, &o, NULL, 0, NULL, NULL, &index), FL_OK);
  uint8_t *v1 = lire(img, M, 20 * M), *v2 = lire(img, 101 * M, 20 * M);
  o = opts(FL_FMT_EXFAT, false, "AUTRE");
  TT_ASSERT_EQ(fl_part_format(d, index, 21 * M, &o, NULL, 0, NULL, NULL), FL_OK);
  fl_pt_layout l;
  TT_ASSERT_EQ(fl_pt_load(d, &l), FL_OK);
  fl_bdev_close(d);
  TT_ASSERT_EQ(l.e[2].gpt_type[0], 0xA2); /* type mis à jour : données Microsoft */
  uint8_t *w1 = lire(img, M, 20 * M), *w2 = lire(img, 101 * M, 20 * M);
  TT_ASSERT_MEM_EQ(v1, w1, 20 * MIB);
  TT_ASSERT_MEM_EQ(v2, w2, 20 * MIB);
  free(v1); free(v2); free(w1); free(w2);
  TT_ASSERT_EQ(extraire(img, 21 * M, 64 * M, part, sizeof part), 0);
  TT_ASSERT_EQ(fu_fsck_fat_n(part, g_out, sizeof g_out), 0);
  unlink(part);
  unlink(img);
}

static void test_op_refused_when_partition_moved(void) {
  char img[4096];
  fl_bdev *d = disque(img, sizeof img, "po-moved.img", FL_PT_GPT);
  fl_fmt_opts o = opts(FL_FMT_EXT4, false, "");
  TT_ASSERT_EQ(fl_part_delete(d, 1, 2 * M), FL_ECHANGED);
  TT_ASSERT_EQ(fl_part_delete(d, 7, M), FL_ECHANGED);
  TT_ASSERT_EQ(fl_part_format(d, 2, M, &o, NULL, 0, NULL, NULL), FL_ECHANGED);
  fl_bdev_close(d);
  unlink(img);
}

static void test_logical_refused(void) {
  char img[4096];
  TT_ASSERT_EQ(image(img, sizeof img, "po-ext.img", 64 * MIB), 0);
  char *a[] = {"parted", "-s", img, "mklabel", "msdos", "mkpart", "extended", "1MiB", "60MiB", "mkpart", "logical",
               "2MiB", "30MiB", NULL};
  TT_ASSERT_EQ(fu_run(a, g_out, sizeof g_out), 0);
  fl_bdev *d = ouvrir(img);
  fl_pt_layout l;
  TT_ASSERT_EQ(fl_pt_load(d, &l), FL_OK);
  fl_fmt_opts o = opts(FL_FMT_EXT4, false, "");
  uint32_t index = 0;
  TT_ASSERT_EQ(fl_part_delete(d, 5, l.e[0].first_lba), FL_ENOTSUP);
  TT_ASSERT_EQ(fl_part_format(d, 5, l.e[0].first_lba, &o, NULL, 0, NULL, NULL), FL_ENOTSUP);
  TT_ASSERT_EQ(fl_part_create(d, 31 * M, 20 * M, &o, NULL, 0, NULL, NULL, &index), FL_ENOTSUP);
  fl_bdev_close(d);
  unlink(img);
}

static void test_usage_matches_statfs(void) {
  char img[4096];
  fl_bdev *d = disque(img, sizeof img, "po-usage.img", FL_PT_GPT);
  struct { fl_fmt_fs fs; fl_content c; } cas[] = {
      {FL_FMT_EXT4, FL_CONTENT_EXT4}, {FL_FMT_FAT32, FL_CONTENT_FAT32}, {FL_FMT_NTFS, FL_CONTENT_NTFS}};
  for (size_t i = 0; i < 3; i++) {
    fl_fmt_opts o = opts(cas[i].fs, false, "REMPLIE");
    uint32_t index = 0;
    fl_pt_layout l;
    TT_ASSERT_EQ(fl_pt_load(d, &l), FL_OK);
    if (l.count == 3) TT_ASSERT_EQ(fl_part_delete(d, 3, 21 * M), FL_OK);
    TT_ASSERT_EQ(fl_part_create(d, 21 * M, 64 * M, &o, NULL, 0, NULL, NULL, &index), FL_OK);
    fl_bdev *s = NULL;
    fl_fs *fs = NULL;
    TT_ASSERT_EQ(fl_slice_bdev_new(d, 21 * M, 64 * M, &s), FL_OK);
    TT_ASSERT_EQ(fl_fs_mount(s, cas[i].c, true, &fs), FL_OK);
    fl_file *f = NULL;
    TT_ASSERT_EQ(fl_fs_open(fs, "/trois-mio.bin", FL_O_RDWR | FL_O_CREAT, &f), FL_OK);
    static uint8_t buf[3 * MIB];
    memset(buf, 7, sizeof buf);
    TT_ASSERT_EQ(fl_file_pwrite(f, buf, sizeof buf, 0), (int64_t)sizeof buf);
    fl_file_close(f);
    fl_statfs st;
    TT_ASSERT_EQ(fl_fs_statfs(fs, &st), FL_OK);
    TT_ASSERT_EQ(fl_fs_unmount(fs), FL_OK);
    fl_bdev_close(s);
    fl_part_usage u;
    TT_ASSERT_EQ(fl_part_usage_of(d, index, &u), FL_OK);
    TT_ASSERT(u.known);
    TT_ASSERT_EQ(u.content, cas[i].c);
    TT_ASSERT_STR_EQ(u.label, "REMPLIE");
    TT_ASSERT_EQ(u.total_bytes, st.total_bytes);
    TT_ASSERT_EQ(u.used_bytes, st.total_bytes - st.free_bytes);
    TT_ASSERT(u.used_bytes >= 3 * MIB);
  }
  TT_ASSERT_EQ(fl_part_delete(d, 3, 21 * M), FL_OK);
  fl_fmt_opts o = opts(FL_FMT_EXT4, true, "");
  uint32_t index = 0;
  TT_ASSERT_EQ(fl_part_create(d, 21 * M, 64 * M, &o, PASS, strlen(PASS), NULL, NULL, &index), FL_OK);
  fl_part_usage u;
  TT_ASSERT_EQ(fl_part_usage_of(d, index, &u), FL_OK);
  TT_ASSERT(!u.known);
  TT_ASSERT_EQ(u.content, FL_CONTENT_LUKS2);
  fl_bdev_close(d);
  unlink(img);
}

static void test_format_with_size_leaves_rest_free(void) {
  char img[4096];
  TT_ASSERT_EQ(image(img, sizeof img, "po-size.img", 1024 * MIB), 0);
  fl_bdev *d = ouvrir(img);
  fl_fmt_opts o = opts(FL_FMT_EXFAT, false, "TAILLE");
  o.part_bytes = 100 * MIB + 12345;
  TT_ASSERT_EQ(fl_format(d, &o, NULL, 0, NULL, NULL), FL_OK);
  fl_pt_layout l;
  TT_ASSERT_EQ(fl_pt_load(d, &l), FL_OK);
  fl_bdev_close(d);
  TT_ASSERT_EQ(l.count, 1);
  TT_ASSERT_EQ(l.e[0].first_lba, M);
  TT_ASSERT_EQ(l.e[0].sector_count, 100 * M);
  fl_pt_region r[2];
  TT_ASSERT_EQ(fl_pt_free(&l, r, 2), 1);
  TT_ASSERT(r[0].sector_count > 900 * M);
  char *a[] = {"sfdisk", "--json", img, NULL};
  TT_ASSERT_EQ(fu_run(a, g_out, sizeof g_out), 0);
  TT_ASSERT(strstr(g_out, "\"size\": 204800") != NULL);
  unlink(img);
}

int main(void) {
  char *a[] = {"sfdisk", "--version", NULL};
  if (!fu_tools_available() || !fu_fat_tools_available() || !fu_ntfs_tools_available() ||
      fu_run(a, g_out, sizeof g_out) != 0) {
    fprintf(stderr, "juges absents : test sauté\n");
    return 0;
  }
  TT_RUN(test_create_in_free_space_judged);
  TT_RUN(test_create_type_matches_fs);
  TT_RUN(test_create_too_small_refused);
  TT_RUN(test_delete_keeps_others);
  TT_RUN(test_format_one_partition_only);
  TT_RUN(test_op_refused_when_partition_moved);
  TT_RUN(test_logical_refused);
  TT_RUN(test_usage_matches_statfs);
  TT_RUN(test_format_with_size_leaves_rest_free);
  TT_MAIN_END();
}

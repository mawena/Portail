#define _GNU_SOURCE
/* Phase 18, T5 : étiquette d'une partition. Partitions créées par le moteur sur un disque GPT de 256 Mio,
 * extraites dans des fichiers et jugées par fatlabel, exfatlabel, blkid, ntfslabel, fsck.fat, fsck.exfat,
 * e2fsck, ntfsfix et cryptsetup (PC). */
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "fluluks/blockdev.h"
#include "fluluks/error.h"
#include "fluluks/format.h"
#include "fluluks/partedit.h"
#include "fluluks/partops.h"
#include "fsck_util.h"
#include "tt.h"

#define MIB (1024ull * 1024ull)
#define M 2048ull

static char g_out[65536];
static const char PASS[] = "phrase de test";
static char g_img[4200];

/* Partitions : 1 exFAT, 2 FAT32, 3 ext4, 4 NTFS, 5 LUKS2 + ext4. */
static const struct {
  fl_fmt_fs fs;
  bool chiffre;
  uint64_t first, count;
} PARTS[] = {{FL_FMT_EXFAT, false, 1 * M, 40 * M},
             {FL_FMT_FAT32, false, 41 * M, 40 * M},
             {FL_FMT_EXT4, false, 81 * M, 40 * M},
             {FL_FMT_NTFS, false, 121 * M, 40 * M},
             {FL_FMT_EXT4, true, 161 * M, 60 * M}};

static fl_bdev *ouvrir(void) {
  fl_bdev *d = NULL;
  return fl_file_bdev_open(g_img, 512, false, &d) == FL_OK ? d : NULL;
}

static int preparer(void) {
  char td[4096];
  if (fu_tmpdir(td, sizeof td) != 0) return -1;
  snprintf(g_img, sizeof g_img, "%s/etiquettes.img", td);
  int fd = open(g_img, O_RDWR | O_CREAT | O_TRUNC, 0644);
  if (fd < 0 || ftruncate(fd, (off_t)(256 * MIB)) != 0) return -1;
  close(fd);
  fl_bdev *d = ouvrir();
  if (!d || fl_pt_new_table(d, FL_PT_GPT) != FL_OK) return -1;
  int rc = FL_OK;
  for (size_t i = 0; rc == FL_OK && i < sizeof PARTS / sizeof PARTS[0]; i++) {
    fl_fmt_opts o;
    memset(&o, 0, sizeof o);
    o.fs = PARTS[i].fs;
    o.encrypted = PARTS[i].chiffre;
    o.label = "AVANT";
    o.kdf_mem_kib = 8192;
    o.root_uid = o.root_gid = 1000;
    uint32_t index = 0;
    rc = fl_part_create(d, PARTS[i].first, PARTS[i].count, &o, PASS, strlen(PASS), NULL, NULL, &index);
    if (rc == FL_OK && index != i + 1) rc = FL_EINVAL;
  }
  fl_bdev_close(d);
  return rc == FL_OK ? 0 : -1;
}

/* Copie de la partition n (1..5) dans un fichier à part. */
static int extraire(int n, char *out, size_t cap) {
  char td[4096];
  if (fu_tmpdir(td, sizeof td) != 0) return -1;
  snprintf(out, cap, "%s/etiq-p%d.img", td, n);
  uint64_t first = PARTS[n - 1].first, count = PARTS[n - 1].count;
  int in = open(g_img, O_RDONLY), o = open(out, O_RDWR | O_CREAT | O_TRUNC, 0644);
  if (in < 0 || o < 0) return -1;
  static uint8_t buf[MIB];
  int rc = 0;
  for (uint64_t off = 0; rc == 0 && off < count * 512; off += sizeof buf)
    if (pread(in, buf, sizeof buf, (off_t)(first * 512 + off)) != (ssize_t)sizeof buf ||
        pwrite(o, buf, sizeof buf, (off_t)off) != (ssize_t)sizeof buf)
      rc = -1;
  close(in);
  close(o);
  return rc;
}

static uint8_t *lire_part(int n) {
  uint64_t first = PARTS[n - 1].first, count = PARTS[n - 1].count;
  uint8_t *b = malloc(count * 512);
  int fd = open(g_img, O_RDONLY);
  if (!b || fd < 0 || pread(fd, b, count * 512, (off_t)(first * 512)) != (ssize_t)(count * 512)) {
    free(b);
    b = NULL;
  }
  if (fd >= 0) close(fd);
  return b;
}

static int etiqueter(int n, const char *label, const char *pass) {
  fl_bdev *d = ouvrir();
  if (!d) return FL_EIO;
  int rc = fl_part_set_label(d, (uint32_t)n, PARTS[n - 1].first, label, pass, pass ? strlen(pass) : 0);
  fl_bdev_close(d);
  return rc;
}

static int lancer(const char *outil, const char *img) {
  char *a[] = {(char *)outil, (char *)img, NULL};
  return fu_run(a, g_out, sizeof g_out);
}

static void test_fat32_label_both_places(void) {
  TT_ASSERT_EQ(etiqueter(2, "Photos 2026", NULL), FL_OK);
  char p[4200];
  TT_ASSERT_EQ(extraire(2, p, sizeof p), 0);
  TT_ASSERT_EQ(lancer("fatlabel", p), 0);
  TT_ASSERT_STR_EQ(g_out, "PHOTOS 2026\n");
  uint8_t s0[512], s6[512];
  int fd = open(p, O_RDONLY);
  TT_ASSERT(fd >= 0);
  TT_ASSERT_EQ(pread(fd, s0, 512, 0), 512);
  TT_ASSERT_EQ(pread(fd, s6, 512, 6 * 512), 512);
  close(fd);
  TT_ASSERT_MEM_EQ(s0 + 71, "PHOTOS 2026", 11);
  TT_ASSERT_MEM_EQ(s6 + 71, "PHOTOS 2026", 11);
  int rc = fu_fsck_fat_n(p, g_out, sizeof g_out);
  if (rc != 0) fprintf(stderr, "%s\n", g_out);
  TT_ASSERT_EQ(rc, 0);
}

static void test_exfat_label_judged(void) {
  TT_ASSERT_EQ(etiqueter(1, "Été 2026", NULL), FL_OK);
  char p[4200];
  TT_ASSERT_EQ(extraire(1, p, sizeof p), 0);
  char *a[] = {"env", "LC_ALL=C.UTF-8", "exfatlabel", p, NULL}; /* fu_run impose LC_ALL=C : « ?t? » */
  TT_ASSERT_EQ(fu_run(a, g_out, sizeof g_out), 0);
  TT_ASSERT(strstr(g_out, "label: Été 2026\n") != NULL);
  TT_ASSERT_EQ(fu_fsck_fat_n(p, g_out, sizeof g_out), 0);
}

static void test_ext4_label_judged(void) {
  TT_ASSERT_EQ(etiqueter(3, "Données", NULL), FL_OK);
  char p[4200];
  TT_ASSERT_EQ(extraire(3, p, sizeof p), 0);
  char *a[] = {"blkid", "-p", "-s", "LABEL", "-o", "value", p, NULL};
  TT_ASSERT_EQ(fu_run(a, g_out, sizeof g_out), 0);
  TT_ASSERT_STR_EQ(g_out, "Données\n");
  TT_ASSERT_EQ(fu_e2fsck_n(p, g_out, sizeof g_out), 0);
}

static void test_ntfs_label_judged(void) {
  TT_ASSERT_EQ(etiqueter(4, "Échanges Windows", NULL), FL_OK);
  char p[4200];
  TT_ASSERT_EQ(extraire(4, p, sizeof p), 0);
  TT_ASSERT_EQ(lancer("ntfslabel", p), 0);
  TT_ASSERT_STR_EQ(g_out, "Échanges Windows\n");
  TT_ASSERT_EQ(fu_ntfsfix_n(p, g_out, sizeof g_out), 0);
}

static void test_encrypted_label_inside(void) {
  TT_ASSERT_EQ(etiqueter(5, "Coffre", PASS), FL_OK);
  char p[4200], pf[4300], plain[4096];
  TT_ASSERT_EQ(extraire(5, p, sizeof p), 0);
  snprintf(pf, sizeof pf, "%s.pass", p);
  FILE *f = fopen(pf, "wb");
  TT_ASSERT(f);
  fwrite(PASS, 1, strlen(PASS), f);
  fclose(f);
  TT_ASSERT_EQ(fu_extract_luks_ext4(p, pf, plain, sizeof plain), 0);
  char *a[] = {"blkid", "-p", "-s", "LABEL", "-o", "value", plain, NULL};
  int rc = fu_run(a, g_out, sizeof g_out);
  int fk = fu_e2fsck_n(plain, g_out + 1024, sizeof g_out - 1024);
  unlink(plain);
  unlink(pf);
  TT_ASSERT_EQ(rc, 0);
  TT_ASSERT_STR_EQ(g_out, "Coffre\n");
  TT_ASSERT_EQ(fk, 0);
}

static void test_invalid_label_refused_before_write(void) {
  const struct { int n; const char *label; } cas[] = {
      {2, "a/b"}, {2, "douze octets"}, {1, "beaucoup trop long"}, {3, "dix-sept octets!!"}, {4, "x\x01y"}};
  for (size_t i = 0; i < sizeof cas / sizeof cas[0]; i++) {
    uint8_t *avant = lire_part(cas[i].n);
    int rc = etiqueter(cas[i].n, cas[i].label, NULL);
    uint8_t *apres = lire_part(cas[i].n);
    int same = avant && apres && memcmp(avant, apres, PARTS[cas[i].n - 1].count * 512) == 0;
    free(avant);
    free(apres);
    TT_ASSERT_EQ(rc, FL_EINVAL);
    TT_ASSERT(same);
  }
}

static void test_wrong_pass_refused(void) {
  uint8_t *avant = lire_part(5);
  int rc = etiqueter(5, "Autre", "mauvaise phrase");
  int rc2 = etiqueter(5, "Autre", NULL);
  uint8_t *apres = lire_part(5);
  int same = avant && apres && memcmp(avant, apres, PARTS[4].count * 512) == 0;
  free(avant);
  free(apres);
  TT_ASSERT_EQ(rc, FL_EBADPASS);
  TT_ASSERT_EQ(rc2, FL_EBADPASS);
  TT_ASSERT(same);
}

static void test_moved_partition_refused(void) {
  fl_bdev *d = ouvrir();
  TT_ASSERT(d);
  int rc = fl_part_set_label(d, 3, PARTS[2].first + M, "X", NULL, 0);
  int rc2 = fl_part_set_label(d, 9, M, "X", NULL, 0);
  fl_bdev_close(d);
  TT_ASSERT_EQ(rc, FL_ECHANGED);
  TT_ASSERT_EQ(rc2, FL_ECHANGED);
}

int main(void) {
  char *a[] = {"exfatlabel", "-V", NULL};
  if (!fu_tools_available() || !fu_fat_tools_available() || !fu_ntfs_tools_available() ||
      fu_run(a, g_out, sizeof g_out) < 0) {
    fprintf(stderr, "juges absents : test sauté\n");
    return 0;
  }
  if (preparer() != 0) {
    fprintf(stderr, "préparation du disque impossible\n");
    return 1;
  }
  TT_RUN(test_fat32_label_both_places);
  TT_RUN(test_exfat_label_judged);
  TT_RUN(test_ext4_label_judged);
  TT_RUN(test_ntfs_label_judged);
  TT_RUN(test_encrypted_label_inside);
  TT_RUN(test_invalid_label_refused_before_write);
  TT_RUN(test_wrong_pass_refused);
  TT_RUN(test_moved_partition_refused);
  TT_MAIN_END();
}

#define _GNU_SOURCE
/* Phase 17, T1 : table de partitions modifiable. Tables faites par sgdisk et parted, relues par fl_pt_load,
 * réécrites par fl_pt_store et jugées par sfdisk --json et sgdisk -v (PC seulement ; sur le téléphone, seuls
 * les cas sans outil tournent). */
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include "fault_bdev.h"
#include "fluluks/blockdev.h"
#include "fluluks/error.h"
#include "fluluks/partedit.h"
#include "fsck_util.h"
#include "tt.h"

#define MIB (1024ull * 1024ull)

static char g_out[65536];

static int outils(void) {
  char *a[] = {"sgdisk", "--version", NULL}, *b[] = {"parted", "--version", NULL},
       *c[] = {"sfdisk", "--version", NULL};
  return fu_run(a, g_out, sizeof g_out) == 0 && fu_run(b, g_out, sizeof g_out) == 0 &&
         fu_run(c, g_out, sizeof g_out) == 0;
}

/* Image creuse de `bytes` octets, pleine de 0xA5 sur le premier et le dernier Mio. */
static int image(char *path, size_t cap, const char *nom, uint64_t bytes) {
  char td[4096];
  if (fu_tmpdir(td, sizeof td) != 0) return -1;
  snprintf(path, cap, "%s/%s", td, nom);
  int fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0644);
  if (fd < 0) return -1;
  int rc = ftruncate(fd, (off_t)bytes);
  static unsigned char vieux[MIB];
  memset(vieux, 0xA5, sizeof vieux);
  if (rc == 0 && pwrite(fd, vieux, sizeof vieux, 0) != (ssize_t)sizeof vieux) rc = -1;
  if (rc == 0 && pwrite(fd, vieux, sizeof vieux, (off_t)(bytes - sizeof vieux)) != (ssize_t)sizeof vieux) rc = -1;
  close(fd);
  return rc;
}

#define RUN(...)                                                    \
  do {                                                              \
    char *argv_[] = {__VA_ARGS__, NULL};                            \
    int rc_ = fu_run(argv_, g_out, sizeof g_out);                   \
    if (rc_ != 0) fprintf(stderr, "%s: %s\n", argv_[0], g_out);     \
    TT_ASSERT_EQ(rc_, 0);                                           \
  } while (0)

static fl_bdev *ouvrir(const char *path, uint32_t ss) {
  fl_bdev *d = NULL;
  return fl_file_bdev_open(path, ss, false, &d) == FL_OK ? d : NULL;
}

/* Partitions selon sfdisk --json : débuts, tailles et types, dans l'ordre. Rend leur nombre. */
static int sfdisk_parts(const char *img, uint64_t *start, uint64_t *size, char (*type)[40], int cap) {
  char *argv[] = {"sfdisk", "--json", (char *)img, NULL};
  if (fu_run(argv, g_out, sizeof g_out) != 0) return -1;
  int n = 0;
  for (const char *p = strstr(g_out, "\"start\":"); p && n < cap; p = strstr(p + 1, "\"start\":")) {
    unsigned long long s = 0, z = 0;
    const char *q = strstr(p, "\"size\":"), *t = strstr(p, "\"type\":");
    if (!q || !t || sscanf(p, "\"start\": %llu", &s) != 1 || sscanf(q, "\"size\": %llu", &z) != 1) return -1;
    if (sscanf(t, "\"type\": \"%39[^\"]\"", type[n]) != 1) return -1;
    start[n] = s;
    size[n] = z;
    n++;
  }
  return n;
}

static int read_at(const char *img, uint64_t off, void *buf, size_t len) {
  int fd = open(img, O_RDONLY);
  if (fd < 0) return -1;
  ssize_t r = pread(fd, buf, len, (off_t)off);
  close(fd);
  return r == (ssize_t)len ? 0 : -1;
}

static fl_pt_entry *find(fl_pt_layout *l, uint32_t index) {
  for (uint32_t i = 0; i < l->count; i++)
    if (l->e[i].index == index) return &l->e[i];
  return NULL;
}

static void gpt_trois(const char *img) {
  char *argv[] = {"sgdisk", "-n", "1:2048:+10M", "-t", "1:8300", "-c", "1:Données", "-A", "1:set:2",
                  "-n", "2:0:+20M", "-t", "2:0700", "-c", "2:Windows", (char *)img, NULL};
  if (fu_run(argv, g_out, sizeof g_out) != 0) fprintf(stderr, "sgdisk: %s\n", g_out);
}

static void test_load_matches_sfdisk(void) {
  char img[4096];
  TT_ASSERT_EQ(image(img, sizeof img, "pl-gpt.img", 64 * MIB), 0);
  RUN("sgdisk", "-n", "1:2048:+10M", "-t", "1:8300", "-c", "1:Données", "-n", "2:0:+20M", "-t", "2:0700", img);
  uint64_t st[8], sz[8];
  char ty[8][40];
  TT_ASSERT_EQ(sfdisk_parts(img, st, sz, ty, 8), 2);
  fl_bdev *d = ouvrir(img, 512);
  TT_ASSERT(d != NULL);
  fl_pt_layout l;
  TT_ASSERT_EQ(fl_pt_load(d, &l), FL_OK);
  fl_bdev_close(d);
  TT_ASSERT_EQ(l.kind, FL_PT_GPT);
  TT_ASSERT_EQ(l.count, 2);
  for (int i = 0; i < 2; i++) {
    TT_ASSERT_EQ(l.e[i].first_lba, st[i]);
    TT_ASSERT_EQ(l.e[i].sector_count, sz[i]);
  }
  TT_ASSERT_STR_EQ(l.e[0].name, "Données");
  TT_ASSERT_EQ(l.e[0].gpt_type[0], 0xAF); /* 0FC63DAF-… */
  TT_ASSERT_EQ(l.e[1].gpt_type[0], 0xA2); /* EBD0A0A2-… */

  TT_ASSERT_EQ(image(img, sizeof img, "pl-mbr.img", 64 * MIB), 0);
  RUN("parted", "-s", img, "mklabel", "msdos", "mkpart", "primary", "fat32", "1MiB", "11MiB", "mkpart", "primary",
      "ext4", "11MiB", "31MiB");
  TT_ASSERT_EQ(sfdisk_parts(img, st, sz, ty, 8), 2);
  d = ouvrir(img, 512);
  TT_ASSERT_EQ(fl_pt_load(d, &l), FL_OK);
  fl_bdev_close(d);
  TT_ASSERT_EQ(l.kind, FL_PT_MBR);
  TT_ASSERT_EQ(l.count, 2);
  TT_ASSERT_EQ(l.has_extended, false);
  TT_ASSERT_EQ(l.e[0].first_lba, st[0]);
  TT_ASSERT_EQ(l.e[1].sector_count, sz[1]);
  TT_ASSERT_EQ(l.e[1].index, 2);
  TT_ASSERT_EQ(l.first_usable, 1);
}

static void test_store_round_trip_unchanged(void) {
  char img[4096];
  static uint8_t avant[34 * 512], apres[34 * 512], fa[33 * 512], fb[33 * 512];
  TT_ASSERT_EQ(image(img, sizeof img, "pl-rt.img", 64 * MIB), 0);
  gpt_trois(img);
  (void)read_at(img, 0, avant, sizeof avant);
  (void)read_at(img, 64 * MIB - sizeof fa, fa, sizeof fa);
  fl_bdev *d = ouvrir(img, 512);
  fl_pt_layout l;
  TT_ASSERT_EQ(fl_pt_load(d, &l), FL_OK);
  TT_ASSERT_EQ(fl_pt_store(d, &l), FL_OK);
  fl_bdev_close(d);
  TT_ASSERT_EQ(read_at(img, 0, apres, sizeof apres), 0);
  TT_ASSERT_EQ(read_at(img, 64 * MIB - sizeof fb, fb, sizeof fb), 0);
  TT_ASSERT_MEM_EQ(avant, apres, sizeof avant);
  TT_ASSERT_MEM_EQ(fa, fb, sizeof fa);

  uint8_t s0a[512], s0b[512];
  TT_ASSERT_EQ(image(img, sizeof img, "pl-rt-mbr.img", 64 * MIB), 0);
  RUN("parted", "-s", img, "mklabel", "msdos", "mkpart", "primary", "fat32", "1MiB", "11MiB", "set", "1", "boot",
      "on", "mkpart", "primary", "ext4", "11MiB", "31MiB");
  (void)read_at(img, 0, s0a, sizeof s0a);
  d = ouvrir(img, 512);
  TT_ASSERT_EQ(fl_pt_load(d, &l), FL_OK);
  TT_ASSERT_EQ(fl_pt_store(d, &l), FL_OK);
  fl_bdev_close(d);
  TT_ASSERT_EQ(read_at(img, 0, s0b, sizeof s0b), 0);
  TT_ASSERT_MEM_EQ(s0a, s0b, sizeof s0a);
}

static void test_foreign_gpt_entries_preserved(void) {
  char img[4096];
  TT_ASSERT_EQ(image(img, sizeof img, "pl-foreign.img", 64 * MIB), 0);
  gpt_trois(img);
  fl_bdev *d = ouvrir(img, 512);
  fl_pt_layout l, a;
  TT_ASSERT_EQ(fl_pt_load(d, &l), FL_OK);
  a = l;
  fl_pt_region r[4];
  TT_ASSERT(fl_pt_free(&l, r, 4) >= 1);
  fl_pt_entry *n = &l.e[l.count++];
  memset(n, 0, sizeof *n);
  n->index = 3;
  n->first_lba = r[0].first_lba;
  n->sector_count = 8 * MIB / 512;
  memcpy(n->gpt_type, a.e[0].gpt_type, 16);
  TT_ASSERT_EQ(fl_pt_store(d, &l), FL_OK);
  TT_ASSERT_EQ(fl_pt_load(d, &l), FL_OK);
  fl_bdev_close(d);
  TT_ASSERT_EQ(l.count, 3);
  for (uint32_t i = 0; i < 2; i++) {
    fl_pt_entry *x = find(&l, a.e[i].index);
    TT_ASSERT(x != NULL);
    TT_ASSERT_MEM_EQ(x->gpt_guid, a.e[i].gpt_guid, 16);
    TT_ASSERT_MEM_EQ(x->name_raw, a.e[i].name_raw, 72);
    TT_ASSERT_EQ(x->gpt_attrs, a.e[i].gpt_attrs);
  }
  TT_ASSERT_EQ(find(&l, 1)->gpt_attrs, 1ull << 2);
  static const uint8_t zero[16];
  TT_ASSERT(memcmp(find(&l, 3)->gpt_guid, zero, 16) != 0); /* GUID tiré au hasard */
  TT_ASSERT_MEM_EQ(l.disk_guid, a.disk_guid, 16);
  RUN("sgdisk", "-v", img);
  TT_ASSERT(strstr(g_out, "No problems found") != NULL);
}

static void test_backup_gpt_moved_to_end(void) {
  char img[4096];
  TT_ASSERT_EQ(image(img, sizeof img, "pl-grow.img", 64 * MIB), 0);
  gpt_trois(img);
  TT_ASSERT_EQ(truncate(img, (off_t)(64 * MIB + 1024 * MIB)), 0);
  fl_bdev *d = ouvrir(img, 512);
  fl_pt_layout l;
  TT_ASSERT_EQ(fl_pt_load(d, &l), FL_OK);
  TT_ASSERT_EQ(l.last_usable, d->sector_count - 34);
  TT_ASSERT_EQ(fl_pt_store(d, &l), FL_OK);
  fl_bdev_close(d);
  RUN("sgdisk", "-v", img);
  TT_ASSERT(strstr(g_out, "No problems found") != NULL);
}

/* Charge une table GPT de deux partitions faite par le moteur, sur une image de 64 Mio. */
static fl_bdev *base_gpt(char *img, size_t cap, const char *nom, uint32_t ss, fl_pt_layout *l) {
  if (image(img, cap, nom, 64 * MIB) != 0) return NULL;
  fl_bdev *d = ouvrir(img, ss);
  if (!d || fl_pt_new_table(d, FL_PT_GPT) != FL_OK || fl_pt_load(d, l) != FL_OK) return d;
  uint64_t m = MIB / ss;
  l->count = 2;
  memset(l->e, 0, 2 * sizeof l->e[0]);
  l->e[0].index = 1;
  l->e[0].first_lba = m;
  l->e[0].sector_count = 10 * m;
  l->e[0].gpt_type[0] = 0xAF;
  l->e[1].index = 2;
  l->e[1].first_lba = 20 * m;
  l->e[1].sector_count = 10 * m;
  l->e[1].gpt_type[0] = 0xA2;
  if (fl_pt_store(d, l) != FL_OK) return d;
  fl_pt_load(d, l);
  return d;
}

static void test_validate_refusals(void) {
  char img[4096];
  fl_pt_layout l, a;
  fl_bdev *d = base_gpt(img, sizeof img, "pl-val.img", 512, &l);
  TT_ASSERT(d != NULL);
  TT_ASSERT_EQ(l.count, 2);
  TT_ASSERT_EQ(fl_pt_validate(&l), FL_OK);
  uint8_t s1[512], s1b[512];
  TT_ASSERT_EQ(fl_bdev_read(d, 1, 1, s1), FL_OK);

  a = l; /* chevauchement */
  a.e[1].first_lba = a.e[0].first_lba + 8;
  TT_ASSERT_EQ(fl_pt_validate(&a), FL_EINVAL);
  TT_ASSERT_EQ(fl_pt_store(d, &a), FL_EINVAL);
  a = l; /* hors du disque */
  a.e[1].sector_count = d->sector_count;
  TT_ASSERT_EQ(fl_pt_validate(&a), FL_EINVAL);
  TT_ASSERT_EQ(fl_pt_store(d, &a), FL_EINVAL);
  a = l; /* index en double */
  a.e[1].index = 1;
  TT_ASSERT_EQ(fl_pt_validate(&a), FL_EINVAL);
  a = l; /* entrée vide */
  a.e[1].sector_count = 0;
  TT_ASSERT_EQ(fl_pt_validate(&a), FL_EINVAL);
  TT_ASSERT_EQ(fl_bdev_read(d, 1, 1, s1b), FL_OK);
  TT_ASSERT_MEM_EQ(s1, s1b, 512); /* rien écrit */
  fl_bdev_close(d);

  /* MBR : cinquième principale, et au-delà de 2^32 secteurs sur un disque de 3 Tio */
  TT_ASSERT_EQ(image(img, sizeof img, "pl-mbr3t.img", 3ull * 1024 * 1024 * MIB), 0);
  d = ouvrir(img, 512);
  TT_ASSERT_EQ(fl_pt_new_table(d, FL_PT_MBR), FL_OK);
  TT_ASSERT_EQ(fl_pt_load(d, &l), FL_OK);
  TT_ASSERT_EQ(l.kind, FL_PT_MBR);
  TT_ASSERT_EQ(l.last_usable, 0xFFFFFFFFull);
  memset(l.e, 0, 5 * sizeof l.e[0]);
  for (uint32_t i = 0; i < 5; i++) {
    l.e[i].index = i + 1;
    l.e[i].first_lba = 2048 + i * 20480ull;
    l.e[i].sector_count = 20480;
    l.e[i].mbr_type = 0x83;
  }
  l.count = 5;
  TT_ASSERT_EQ(fl_pt_validate(&l), FL_EINVAL); /* fifthPrimaryRefused */
  l.count = 1;
  l.e[0].sector_count = 0xFFFFFFFFull; /* mbrBeyond2TiBRefused */
  TT_ASSERT_EQ(fl_pt_validate(&l), FL_EINVAL);
  TT_ASSERT_EQ(fl_pt_store(d, &l), FL_EINVAL);
  fl_bdev_close(d);
  unlink(img);
}

static void test_hybrid_mbr_refused(void) {
  char img[4096];
  TT_ASSERT_EQ(image(img, sizeof img, "pl-hyb.img", 64 * MIB), 0);
  gpt_trois(img);
  RUN("sgdisk", "-h", "1", img);
  fl_bdev *d = ouvrir(img, 512);
  fl_pt_layout l;
  TT_ASSERT_EQ(fl_pt_load(d, &l), FL_ENOTSUP);
  fl_bdev_close(d);
}

static void test_extended_flagged(void) {
  char img[4096];
  TT_ASSERT_EQ(image(img, sizeof img, "pl-ext.img", 64 * MIB), 0);
  RUN("parted", "-s", img, "mklabel", "msdos", "mkpart", "primary", "fat32", "1MiB", "5MiB", "mkpart", "extended",
      "5MiB", "40MiB", "mkpart", "logical", "6MiB", "10MiB", "mkpart", "logical", "11MiB", "20MiB");
  fl_bdev *d = ouvrir(img, 512);
  fl_pt_layout l;
  TT_ASSERT_EQ(fl_pt_load(d, &l), FL_OK);
  TT_ASSERT_EQ(l.has_extended, true);
  TT_ASSERT_EQ(l.count, 3);
  TT_ASSERT_EQ(find(&l, 5)->logical, true);
  TT_ASSERT_EQ(find(&l, 6)->logical, true);
  TT_ASSERT_EQ(find(&l, 1)->logical, false);
  fl_pt_region r[4];
  TT_ASSERT_EQ(fl_pt_free(&l, r, 4), 0);
  TT_ASSERT_EQ(fl_pt_store(d, &l), FL_ENOTSUP);
  fl_bdev_close(d);
}

static void test_new_table_gpt_and_mbr(void) {
  char img[4096];
  uint8_t b[512];
  static const uint8_t zero[512];
  TT_ASSERT_EQ(image(img, sizeof img, "pl-new.img", 64 * MIB), 0);
  fl_bdev *d = ouvrir(img, 512);
  TT_ASSERT_EQ(fl_pt_new_table(d, FL_PT_GPT), FL_OK);
  fl_bdev_close(d);
  RUN("sgdisk", "-v", img);
  TT_ASSERT(strstr(g_out, "No problems found") != NULL);
  RUN("sfdisk", "--json", img);
  TT_ASSERT(strstr(g_out, "\"label\": \"gpt\"") != NULL);
  TT_ASSERT(strstr(g_out, "\"start\":") == NULL);
  TT_ASSERT_EQ(read_at(img, MIB - 512, b, 512), 0); /* ancienne signature effacée */
  TT_ASSERT_MEM_EQ(b, zero, 512);
  TT_ASSERT_EQ(read_at(img, 64 * MIB - MIB, b, 512), 0);
  TT_ASSERT_MEM_EQ(b, zero, 512);

  TT_ASSERT_EQ(image(img, sizeof img, "pl-new-mbr.img", 64 * MIB), 0);
  d = ouvrir(img, 512);
  TT_ASSERT_EQ(fl_pt_new_table(d, FL_PT_MBR), FL_OK);
  fl_pt_layout l;
  TT_ASSERT_EQ(fl_pt_load(d, &l), FL_OK);
  TT_ASSERT_EQ(l.kind, FL_PT_MBR);
  TT_ASSERT_EQ(l.count, 0);
  TT_ASSERT(l.mbr_signature != 0);
  fl_bdev_close(d);
  RUN("sfdisk", "--json", img);
  TT_ASSERT(strstr(g_out, "\"label\": \"dos\"") != NULL);
  TT_ASSERT(strstr(g_out, "\"start\":") == NULL);
}

static void test_free_regions_aligned(void) {
  char img[4096];
  TT_ASSERT_EQ(image(img, sizeof img, "pl-free.img", 64 * MIB), 0);
  RUN("sgdisk", "-n", "1:2048:22527", "-n", "2:23552:+10M", "-n", "3:61440:+10M", img);
  fl_bdev *d = ouvrir(img, 512);
  fl_pt_layout l;
  TT_ASSERT_EQ(fl_pt_load(d, &l), FL_OK);
  fl_bdev_close(d);
  fl_pt_region r[8];
  TT_ASSERT_EQ(fl_pt_free(&l, r, 8), 2);
  TT_ASSERT_EQ(r[0].first_lba, 22 * 2048); /* trou de 21,5 à 30 Mio : 22 à 30 Mio */
  TT_ASSERT_EQ(r[0].sector_count, 8 * 2048);
  TT_ASSERT_EQ(r[1].first_lba, 40 * 2048);
  TT_ASSERT_EQ(r[1].sector_count % 2048, 0);
  TT_ASSERT(r[1].first_lba + r[1].sector_count - 1 <= l.last_usable);
}

static void test_sector4k_layout(void) {
  char img[4096];
  fl_pt_layout l;
  fl_bdev *d = base_gpt(img, sizeof img, "pl-4k.img", 4096, &l);
  TT_ASSERT(d != NULL);
  TT_ASSERT_EQ(l.kind, FL_PT_GPT);
  TT_ASSERT_EQ(l.sector_size, 4096);
  TT_ASSERT_EQ(l.first_usable, 6);
  TT_ASSERT_EQ(l.last_usable, d->sector_count - 6);
  TT_ASSERT_EQ(l.count, 2);
  TT_ASSERT_EQ(l.e[1].first_lba, 20 * 256);
  fl_pt_region r[4];
  TT_ASSERT_EQ(fl_pt_free(&l, r, 4), 2);
  TT_ASSERT_EQ(r[0].first_lba, 11 * 256);
  fl_bdev_close(d);
}

static int meme_table(const fl_pt_layout *a, const fl_pt_layout *b) {
  if (a->count != b->count) return 0;
  for (uint32_t i = 0; i < a->count; i++)
    if (a->e[i].index != b->e[i].index || a->e[i].first_lba != b->e[i].first_lba ||
        a->e[i].sector_count != b->e[i].sector_count)
      return 0;
  return 1;
}

static void test_gpt_write_cut_leaves_one_valid_copy(void) {
  char img[4096], copie[4096];
  fl_pt_layout ancien, nouveau;
  fl_bdev *d = base_gpt(img, sizeof img, "pl-cut.img", 512, &ancien);
  TT_ASSERT(d != NULL);
  fl_bdev_close(d);
  nouveau = ancien;
  nouveau.e[1].sector_count = 20 * 2048; /* partition 2 agrandie, partition 3 ajoutée */
  nouveau.e[2] = nouveau.e[0];
  nouveau.e[2].index = 3;
  nouveau.e[2].first_lba = 45 * 2048;
  nouveau.e[2].sector_count = 5 * 2048;
  memset(nouveau.e[2].gpt_guid, 0, 16);
  nouveau.count = 3;
  int fini = 0;
  for (uint64_t k = 0; k < 20 && !fini; k++) {
    TT_ASSERT_EQ(fu_copy_image(img, copie, sizeof copie), 0);
    fl_bdev *base = ouvrir(copie, 512), *f = NULL;
    TT_ASSERT_EQ(fl_fault_bdev_new(base, k, FL_ENODEV, &f), FL_OK);
    int rc = fl_pt_store(f, &nouveau);
    fini = rc == FL_OK;
    fl_bdev_close(f);
    fl_bdev_close(base);
    fl_pt_layout lu;
    d = ouvrir(copie, 512);
    TT_ASSERT_EQ(fl_pt_load(d, &lu), FL_OK);
    fl_bdev_close(d);
    TT_ASSERT(meme_table(&lu, &ancien) || meme_table(&lu, &nouveau));
    if (fini) TT_ASSERT(meme_table(&lu, &nouveau));
    unlink(copie);
  }
  TT_ASSERT(fini);
}

int main(void) {
  TT_RUN(test_validate_refusals);
  TT_RUN(test_sector4k_layout);
  TT_RUN(test_gpt_write_cut_leaves_one_valid_copy);
  if (!outils()) {
    fprintf(stderr, "sgdisk, parted ou sfdisk absent : cas jugés sautés\n");
    TT_MAIN_END();
  }
  TT_RUN(test_load_matches_sfdisk);
  TT_RUN(test_store_round_trip_unchanged);
  TT_RUN(test_foreign_gpt_entries_preserved);
  TT_RUN(test_backup_gpt_moved_to_end);
  TT_RUN(test_hybrid_mbr_refused);
  TT_RUN(test_extended_flagged);
  TT_RUN(test_new_table_gpt_and_mbr);
  TT_RUN(test_free_regions_aligned);
  TT_MAIN_END();
}

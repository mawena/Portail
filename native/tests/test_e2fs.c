#define _GNU_SOURCE
/* Phase 18, T3 : e2fsprogs dans le moteur. Images faites par mke2fs du PC (metadata_csum, 64bit,
 * flex_bg), jugées par e2fsck, resize2fs -P, debugfs et blkid du PC. */
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "fluluks/blockdev.h"
#include "fluluks/error.h"
#include "fluluks/partops.h"
#include "fsck_util.h"
#include "tt.h"

#define MIB (1024ull * 1024ull)
#define NFILES 12
#define FILE_BYTES (10 * MIB)

static char g_out[65536];

static void contenu(uint8_t *p, size_t n, uint32_t graine) {
  uint32_t x = graine * 2654435761u + 1;
  for (size_t i = 0; i < n; i++) {
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    p[i] = (uint8_t)x;
  }
}

/* Image ext4 de `bytes` octets ; si `nfiles` > 0, remplie de fichiers f<i> de 10 Mio (mke2fs -d). */
static int faire_image(char *path, size_t cap, const char *nom, uint64_t bytes, int nfiles) {
  char td[4096], dir[4200];
  if (fu_tmpdir(td, sizeof td) != 0) return -1;
  snprintf(path, cap, "%s/%s", td, nom);
  unlink(path);
  const char *d = NULL;
  if (nfiles > 0) {
    snprintf(dir, sizeof dir, "%s/%s.d", td, nom);
    mkdir(dir, 0755);
    uint8_t *buf = malloc(FILE_BYTES);
    if (!buf) return -1;
    for (int i = 0; i < nfiles; i++) {
      char f[4300];
      snprintf(f, sizeof f, "%s/f%d", dir, i);
      contenu(buf, FILE_BYTES, (uint32_t)i + 1);
      int fd = open(f, O_WRONLY | O_CREAT | O_TRUNC, 0644);
      if (fd < 0 || write(fd, buf, FILE_BYTES) != (ssize_t)FILE_BYTES) {
        free(buf);
        return -1;
      }
      close(fd);
    }
    free(buf);
    d = dir;
  }
  char taille[32];
  snprintf(taille, sizeof taille, "%lluk", (unsigned long long)(bytes / 1024));
  char *a[] = {"mke2fs", "-q", "-F", "-t", "ext4", "-O", "metadata_csum,64bit,flex_bg", "-L", "avant",
               "-E", "lazy_itable_init=0,lazy_journal_init=0", NULL, NULL, NULL, NULL, NULL};
  int k = 11;
  if (d) {
    a[k++] = "-d";
    a[k++] = (char *)d;
  }
  a[k++] = path;
  a[k++] = taille;
  return fu_run(a, g_out, sizeof g_out);
}

static fl_bdev *ouvrir(const char *path, bool ro) {
  fl_bdev *d = NULL;
  return fl_file_bdev_open(path, 512, ro, &d) == FL_OK ? d : NULL;
}

static uint8_t *lire_tout(const char *path, size_t *n) {
  int fd = open(path, O_RDONLY);
  if (fd < 0) return NULL;
  struct stat st;
  fstat(fd, &st);
  uint8_t *b = malloc((size_t)st.st_size);
  size_t got = 0;
  while (b && got < (size_t)st.st_size) {
    ssize_t r = pread(fd, b + got, (size_t)st.st_size - got, (off_t)got);
    if (r <= 0) break;
    got += (size_t)r;
  }
  close(fd);
  *n = got;
  return b;
}

/* Fichiers f0..f<n-1> lus par debugfs, égaux à leur contenu d'origine. */
static int fichiers_intacts(const char *img, int nfiles) {
  uint8_t *attendu = malloc(FILE_BYTES), *lu = malloc(FILE_BYTES + 1);
  int ok = attendu && lu;
  for (int i = 0; ok && i < nfiles; i++) {
    char p[32];
    snprintf(p, sizeof p, "/f%d", i);
    contenu(attendu, FILE_BYTES, (uint32_t)i + 1);
    int64_t n = fu_debugfs_cat(img, p, lu, FILE_BYTES + 1);
    if (n != (int64_t)FILE_BYTES || memcmp(attendu, lu, FILE_BYTES) != 0) {
      fprintf(stderr, "fichier %s abîmé (%lld octets)\n", p, (long long)n);
      ok = 0;
    }
  }
  free(attendu);
  free(lu);
  return ok;
}

static void test_check_clean_image(void) {
  char img[4200];
  TT_ASSERT_EQ(faire_image(img, sizeof img, "propre.img", 64 * MIB, 0), 0);
  fl_bdev *d = ouvrir(img, true);
  TT_ASSERT(d);
  fl_check_report r;
  int rc = fl_e2fs_check(d, &r);
  fl_bdev_close(d);
  TT_ASSERT_EQ(rc, FL_OK);
  if (!r.clean) fprintf(stderr, "%s\n", r.report);
  TT_ASSERT(r.clean);
  TT_ASSERT_EQ(r.exit_code, 0);
  TT_ASSERT(strstr(r.report, "Pass 5") != NULL);
}

static void test_check_reports_corruption(void) {
  char img[4200];
  TT_ASSERT_EQ(faire_image(img, sizeof img, "casse.img", 64 * MIB, 1), 0);
  char *a[] = {"debugfs", "-w", "-R", "clri <12>", img, NULL};
  TT_ASSERT_EQ(fu_run(a, g_out, sizeof g_out), 0);
  size_t n1 = 0, n2 = 0;
  uint8_t *avant = lire_tout(img, &n1);
  TT_ASSERT(avant);
  fl_bdev *d = ouvrir(img, true);
  TT_ASSERT(d);
  fl_check_report r;
  int rc = fl_e2fs_check(d, &r);
  fl_bdev_close(d);
  uint8_t *apres = lire_tout(img, &n2);
  int same = apres && n1 == n2 && memcmp(avant, apres, n1) == 0;
  free(avant);
  free(apres);
  TT_ASSERT_EQ(rc, FL_OK);
  TT_ASSERT(!r.clean);
  TT_ASSERT_EQ(r.exit_code, 4);
  TT_ASSERT(strlen(r.report) > 0);
  TT_ASSERT(same);
}

static void test_min_size_matches_resize2fs_p(void) {
  char img[4200];
  TT_ASSERT_EQ(faire_image(img, sizeof img, "min.img", 256 * MIB, 6), 0);
  char *a[] = {"resize2fs", "-P", img, NULL};
  TT_ASSERT_EQ(fu_run(a, g_out, sizeof g_out), 0);
  const char *p = strstr(g_out, "minimum size of the filesystem: ");
  TT_ASSERT(p);
  unsigned long long blocs = strtoull(p + strlen("minimum size of the filesystem: "), NULL, 10);
  fl_bdev *d = ouvrir(img, true);
  TT_ASSERT(d);
  uint64_t octets = 0;
  int rc = fl_e2fs_min_size(d, &octets);
  fl_bdev_close(d);
  TT_ASSERT_EQ(rc, FL_OK);
  TT_ASSERT_EQ(octets, blocs * 4096ull);
}

static int g_last_pct;
static void progres(int pct, void *arg) {
  (void)arg;
  if (pct < g_last_pct) g_last_pct = 1000; /* recul : signalé par l'assertion */
  else g_last_pct = pct;
}

static void redimensionner(uint64_t de, uint64_t vers) {
  char img[4200];
  TT_ASSERT_EQ(faire_image(img, sizeof img, "redim.img", de, NFILES), 0);
  if (vers > de) TT_ASSERT_EQ(truncate(img, (off_t)vers), 0);
  fl_bdev *d = ouvrir(img, false);
  TT_ASSERT(d);
  g_last_pct = -1;
  int rr = fl_e2fs_resize(d, vers, progres, NULL);
  fl_bdev_close(d);
  TT_ASSERT_EQ(rr, FL_OK);
  TT_ASSERT_EQ(g_last_pct, 100);
  if (vers < de) TT_ASSERT_EQ(truncate(img, (off_t)vers), 0);
  int rc = fu_e2fsck_n(img, g_out, sizeof g_out);
  if (rc != 0) fprintf(stderr, "%s\n", g_out);
  TT_ASSERT_EQ(rc, 0);
  char *a[] = {"dumpe2fs", "-h", img, NULL};
  TT_ASSERT_EQ(fu_run(a, g_out, sizeof g_out), 0);
  const char *p = strstr(g_out, "Block count:");
  TT_ASSERT(p);
  TT_ASSERT_EQ(strtoull(p + strlen("Block count:"), NULL, 10), vers / 4096);
  TT_ASSERT(fichiers_intacts(img, NFILES));
}

static void test_grow_then_judged(void) { redimensionner(256 * MIB, 512 * MIB); }
static void test_shrink_then_judged(void) { redimensionner(256 * MIB, 176 * MIB); }

static void test_shrink_below_minimum_refused(void) {
  char img[4200];
  TT_ASSERT_EQ(faire_image(img, sizeof img, "petit.img", 256 * MIB, NFILES), 0);
  size_t n1 = 0, n2 = 0;
  uint8_t *avant = lire_tout(img, &n1);
  fl_bdev *d = ouvrir(img, false);
  if (!d || !avant) {
    fl_bdev_close(d);
    free(avant);
  }
  TT_ASSERT(d && avant);
  int rc1 = fl_e2fs_resize(d, 64 * MIB, NULL, NULL);  /* sous la place occupée */
  int rc2 = fl_e2fs_resize(d, 300 * MIB, NULL, NULL); /* au-delà du volume */
  fl_bdev_close(d);
  uint8_t *apres = lire_tout(img, &n2);
  int same = apres && n1 == n2 && memcmp(avant, apres, n1) == 0;
  free(avant);
  free(apres);
  TT_ASSERT_EQ(rc1, FL_EINVAL);
  TT_ASSERT_EQ(rc2, FL_EINVAL);
  TT_ASSERT(same);
}

static void test_label_set_judged(void) {
  char img[4200];
  TT_ASSERT_EQ(faire_image(img, sizeof img, "etiq.img", 64 * MIB, 0), 0);
  fl_bdev *d = ouvrir(img, false);
  TT_ASSERT(d);
  int rc1 = fl_e2fs_set_label(d, "Données été");
  int rc2 = fl_e2fs_set_label(d, "dix-sept octets!!");
  fl_bdev_close(d);
  TT_ASSERT_EQ(rc1, FL_OK);
  TT_ASSERT_EQ(rc2, FL_EINVAL);
  char *a[] = {"blkid", "-p", "-s", "LABEL", "-o", "value", img, NULL};
  TT_ASSERT_EQ(fu_run(a, g_out, sizeof g_out), 0);
  TT_ASSERT_STR_EQ(g_out, "Données été\n");
  TT_ASSERT_EQ(fu_e2fsck_n(img, g_out, sizeof g_out), 0);
}

static void test_exit_never_kills_process(void) {
  char img[4200], td[4096];
  TT_ASSERT_EQ(fu_tmpdir(td, sizeof td), 0);
  snprintf(img, sizeof img, "%s/vide.img", td);
  int fd = open(img, O_RDWR | O_CREAT | O_TRUNC, 0644);
  TT_ASSERT(fd >= 0);
  TT_ASSERT_EQ(ftruncate(fd, (off_t)(16 * MIB)), 0);
  close(fd);
  fl_bdev *d = ouvrir(img, true);
  TT_ASSERT(d);
  fl_check_report r;
  int rc = fl_e2fs_check(d, &r);
  uint64_t m = 0;
  int rc2 = fl_e2fs_min_size(d, &m);
  fl_bdev_close(d);
  TT_ASSERT_EQ(rc, FL_ECORRUPT);
  TT_ASSERT(!r.clean);
  TT_ASSERT_EQ(r.exit_code, 8);
  TT_ASSERT(strstr(r.report, "superblock") != NULL);
  TT_ASSERT_EQ(rc2, FL_ECORRUPT);
}

static void test_two_calls_sequential(void) {
  char img[4200];
  TT_ASSERT_EQ(faire_image(img, sizeof img, "deux.img", 64 * MIB, 1), 0);
  for (int i = 0; i < 3; i++) {
    fl_bdev *d = ouvrir(img, true);
    TT_ASSERT(d);
    fl_check_report r;
    int rc = fl_e2fs_check(d, &r);
    fl_bdev_close(d);
    TT_ASSERT_EQ(rc, FL_OK);
    TT_ASSERT(r.clean);
  }
}

int main(void) {
  char *a[] = {"resize2fs", NULL};
  if (!fu_tools_available() || fu_run(a, g_out, sizeof g_out) < 0) {
    fprintf(stderr, "juges absents : test sauté\n");
    return 0;
  }
  TT_RUN(test_check_clean_image);
  TT_RUN(test_check_reports_corruption);
  TT_RUN(test_min_size_matches_resize2fs_p);
  TT_RUN(test_grow_then_judged);
  TT_RUN(test_shrink_then_judged);
  TT_RUN(test_shrink_below_minimum_refused);
  TT_RUN(test_label_set_judged);
  TT_RUN(test_exit_never_kills_process);
  TT_RUN(test_two_calls_sequential);
  TT_MAIN_END();
}

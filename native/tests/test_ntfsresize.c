#define _GNU_SOURCE
/* Phase 18, T4 : ntfsresize et ntfsfix -n dans le moteur. Images faites par mkntfs -Q du PC et remplies par
 * ntfs-remplir, jugées par ntfsfix -n, ntfsresize --info, ntfslabel du PC et ntfsjuge.py. */
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

/* Image NTFS de `bytes` octets ; si nfiles > 0, remplie de fichiers f<i> de 10 Mio (ntfs-remplir). */
static int faire_image(char *path, size_t cap, const char *nom, uint64_t bytes, int nfiles) {
  char td[4096], dir[4200];
  if (fu_tmpdir(td, sizeof td) != 0) return -1;
  snprintf(path, cap, "%s/%s", td, nom);
  int fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0644);
  if (fd < 0 || ftruncate(fd, (off_t)bytes) != 0) return -1;
  close(fd);
  char *a[] = {"mkntfs", "-Q", "-F", "-L", "avant", path, NULL};
  if (fu_run(a, g_out, sizeof g_out) != 0) return -1;
  if (nfiles <= 0) return 0;
  snprintf(dir, sizeof dir, "%s/%s.d", td, nom);
  mkdir(dir, 0755);
  uint8_t *buf = malloc(FILE_BYTES);
  if (!buf) return -1;
  for (int i = 0; i < nfiles; i++) {
    char f[4300];
    snprintf(f, sizeof f, "%s/f%d", dir, i);
    contenu(buf, FILE_BYTES, (uint32_t)i + 1);
    int fo = open(f, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fo < 0 || write(fo, buf, FILE_BYTES) != (ssize_t)FILE_BYTES) {
      free(buf);
      return -1;
    }
    close(fo);
  }
  free(buf);
  const char *remplir = getenv("NTFS_REMPLIR");
  if (!remplir) return -1;
  char *b[] = {(char *)remplir, path, dir, NULL};
  return fu_run(b, g_out, sizeof g_out);
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

static int memes_fichiers(const char *m1, const char *m2) {
  size_t n1 = 0, n2 = 0;
  uint8_t *a = lire_tout(m1, &n1), *b = lire_tout(m2, &n2);
  int ok = a && b && n1 == n2 && n1 > 0 && memcmp(a, b, n1) == 0;
  free(a);
  free(b);
  return ok;
}

static void test_check_clean(void) {
  char img[4200];
  TT_ASSERT_EQ(faire_image(img, sizeof img, "propre.img", 64 * MIB, 1), 0);
  fl_bdev *d = ouvrir(img, true);
  TT_ASSERT(d);
  fl_check_report r;
  int rc = fl_ntfs_check(d, &r);
  fl_bdev_close(d);
  if (!r.clean) fprintf(stderr, "%s\n", r.report);
  TT_ASSERT_EQ(rc, FL_OK);
  TT_ASSERT(r.clean);
  TT_ASSERT_EQ(r.exit_code, 0);
  TT_ASSERT(strstr(r.report, "Mounting volume") != NULL);
  TT_ASSERT(strstr(r.report, "Checking filesystem consistency") != NULL);
}

static void test_check_dirty_volume_reported(void) {
  char img[4200];
  TT_ASSERT_EQ(faire_image(img, sizeof img, "sale.img", 64 * MIB, 0), 0);
  char *a[] = {"ntfsfix", img, NULL}; /* ntfsfix laisse le volume marqué à vérifier */
  TT_ASSERT_EQ(fu_run(a, g_out, sizeof g_out), 0);
  TT_ASSERT(fu_ntfs_flags(img) & 1);
  size_t n1 = 0, n2 = 0;
  uint8_t *avant = lire_tout(img, &n1);
  fl_bdev *d = ouvrir(img, true);
  fl_check_report r;
  int rc = d ? fl_ntfs_check(d, &r) : FL_EIO;
  uint64_t m = 0;
  int rc2 = d ? fl_ntfs_min_size(d, &m) : FL_EIO;
  fl_bdev_close(d);
  uint8_t *apres = lire_tout(img, &n2);
  int same = avant && apres && n1 == n2 && memcmp(avant, apres, n1) == 0;
  free(avant);
  free(apres);
  TT_ASSERT_EQ(rc, FL_OK);
  TT_ASSERT(!r.clean);
  TT_ASSERT(strstr(r.report, "dirty") != NULL);
  TT_ASSERT_EQ(rc2, FL_ECORRUPT);
  TT_ASSERT(same);
}

static void test_min_size_matches_ntfsresize_info(void) {
  char img[4200];
  TT_ASSERT_EQ(faire_image(img, sizeof img, "min.img", 256 * MIB, 6), 0);
  char *a[] = {"ntfsresize", "--info", "--force", "--no-progress-bar", img, NULL};
  TT_ASSERT_EQ(fu_run(a, g_out, sizeof g_out), 0);
  const char *p = strstr(g_out, "You might resize at ");
  TT_ASSERT(p);
  long long attendu = strtoll(p + strlen("You might resize at "), NULL, 10);
  fl_bdev *d = ouvrir(img, true);
  TT_ASSERT(d);
  uint64_t octets = 0;
  int rc = fl_ntfs_min_size(d, &octets);
  fl_bdev_close(d);
  TT_ASSERT_EQ(rc, FL_OK);
  long long ecart = (long long)octets - attendu;
  if (ecart < 0) ecart = -ecart;
  TT_ASSERT(ecart <= (long long)MIB);
}

static int g_last_pct;
static void progres(int pct, void *arg) {
  (void)arg;
  g_last_pct = pct < g_last_pct ? 1000 : pct;
}

static void redimensionner(uint64_t de, uint64_t vers) {
  char img[4200], m1[4300], m2[4300], td[4096];
  TT_ASSERT_EQ(faire_image(img, sizeof img, "redim.img", de, NFILES), 0);
  TT_ASSERT_EQ(fu_tmpdir(td, sizeof td), 0);
  snprintf(m1, sizeof m1, "%s/redim-avant.manifest", td);
  snprintf(m2, sizeof m2, "%s/redim-apres.manifest", td);
  TT_ASSERT_EQ(fu_ntfs_manifest(img, m1), 0);
  if (vers > de) TT_ASSERT_EQ(truncate(img, (off_t)vers), 0);
  fl_bdev *d = ouvrir(img, false);
  TT_ASSERT(d);
  g_last_pct = -1;
  int rc = fl_ntfs_resize(d, vers, progres, NULL);
  fl_bdev_close(d);
  TT_ASSERT_EQ(rc, FL_OK);
  TT_ASSERT_EQ(g_last_pct, 100);
  if (vers < de) TT_ASSERT_EQ(truncate(img, (off_t)vers), 0);
  int fx = fu_ntfsfix_n(img, g_out, sizeof g_out);
  if (fx != 0) fprintf(stderr, "%s\n", g_out);
  TT_ASSERT_EQ(fx, 0);
  char *a[] = {"ntfsresize", "--info", "--force", "--no-progress-bar", img, NULL};
  TT_ASSERT_EQ(fu_run(a, g_out, sizeof g_out), 0);
  const char *p = strstr(g_out, "Current volume size: ");
  TT_ASSERT(p);
  long long taille = strtoll(p + strlen("Current volume size: "), NULL, 10);
  TT_ASSERT(taille <= (long long)vers && taille > (long long)(vers - MIB));
  TT_ASSERT_EQ(fu_ntfs_manifest(img, m2), 0);
  TT_ASSERT(memes_fichiers(m1, m2));
}

static void test_grow_then_judged(void) { redimensionner(256 * MIB, 512 * MIB); }
static void test_shrink_then_judged(void) { redimensionner(256 * MIB, 160 * MIB); }

static void test_resize_sets_chkdsk_flag_like_upstream(void) {
  char img[4200];
  TT_ASSERT_EQ(faire_image(img, sizeof img, "chkdsk.img", 64 * MIB, 1), 0);
  TT_ASSERT_EQ(fu_ntfs_flags(img) & 1, 0);
  TT_ASSERT_EQ(truncate(img, (off_t)(96 * MIB)), 0);
  fl_bdev *d = ouvrir(img, false);
  TT_ASSERT(d);
  int rc = fl_ntfs_resize(d, 96 * MIB, NULL, NULL);
  fl_bdev_close(d);
  TT_ASSERT_EQ(rc, FL_OK);
  TT_ASSERT_EQ(fu_ntfs_flags(img) & 1, 1);
}

static void test_shrink_below_minimum_refused(void) {
  char img[4200];
  TT_ASSERT_EQ(faire_image(img, sizeof img, "petit.img", 256 * MIB, NFILES), 0);
  size_t n1 = 0, n2 = 0;
  uint8_t *avant = lire_tout(img, &n1);
  fl_bdev *d = ouvrir(img, false);
  int rc1 = d ? fl_ntfs_resize(d, 64 * MIB, NULL, NULL) : FL_EIO;
  int rc2 = d ? fl_ntfs_resize(d, 300 * MIB, NULL, NULL) : FL_EIO;
  fl_bdev_close(d);
  uint8_t *apres = lire_tout(img, &n2);
  int same = avant && apres && n1 == n2 && memcmp(avant, apres, n1) == 0;
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
  int rc = fl_ntfs_set_label(d, "Données d'été");
  int rc2 = fl_ntfs_set_label(d, "un nom beaucoup trop long pour NTFS ici");
  fl_bdev_close(d);
  TT_ASSERT_EQ(rc, FL_OK);
  TT_ASSERT_EQ(rc2, FL_EINVAL);
  char *a[] = {"ntfslabel", img, NULL};
  TT_ASSERT_EQ(fu_run(a, g_out, sizeof g_out), 0);
  TT_ASSERT_STR_EQ(g_out, "Données d'été\n");
  TT_ASSERT_EQ(fu_ntfsfix_n(img, g_out, sizeof g_out), 0);
}

static void test_exit_never_kills_process(void) {
  char img[4200], td[4096];
  TT_ASSERT_EQ(fu_tmpdir(td, sizeof td), 0);
  snprintf(img, sizeof img, "%s/vide-ntfs.img", td);
  int fd = open(img, O_RDWR | O_CREAT | O_TRUNC, 0644);
  TT_ASSERT(fd >= 0);
  TT_ASSERT_EQ(ftruncate(fd, (off_t)(16 * MIB)), 0);
  close(fd);
  fl_bdev *d = ouvrir(img, true);
  TT_ASSERT(d);
  fl_check_report r;
  int rc = fl_ntfs_check(d, &r);
  uint64_t m = 0;
  int rc2 = fl_ntfs_min_size(d, &m);
  fl_bdev_close(d);
  TT_ASSERT_EQ(rc, FL_ECORRUPT);
  TT_ASSERT(!r.clean);
  TT_ASSERT(strlen(r.report) > 0);
  TT_ASSERT_EQ(rc2, FL_ECORRUPT);
}

int main(void) {
  char *a[] = {"ntfsresize", "--version", NULL};
  if (!fu_ntfs_tools_available() || !getenv("NTFS_REMPLIR") || fu_run(a, g_out, sizeof g_out) < 0) {
    fprintf(stderr, "juges absents : test sauté\n");
    return 0;
  }
  TT_RUN(test_check_clean);
  TT_RUN(test_check_dirty_volume_reported);
  TT_RUN(test_min_size_matches_ntfsresize_info);
  TT_RUN(test_grow_then_judged);
  TT_RUN(test_shrink_then_judged);
  TT_RUN(test_resize_sets_chkdsk_flag_like_upstream);
  TT_RUN(test_shrink_below_minimum_refused);
  TT_RUN(test_label_set_judged);
  TT_RUN(test_exit_never_kills_process);
  TT_MAIN_END();
}

#define _GNU_SOURCE
/* Phase 18, T6 : agrandir et réduire une partition et son système de fichiers (ext4, NTFS, dans LUKS1 et
 * LUKS2). Disque GPT de 512 Mio : partition 1 de 1 à 201 Mio (à redimensionner), partition 2 de 401 à
 * 451 Mio (voisine, remplie d'un motif qui ne doit pas changer). Jugés par sfdisk, e2fsck, debugfs, ntfsfix,
 * ntfsjuge.py et cryptsetup du PC. FL_KEEP=1 garde chaque disque redimensionné
 * (build/native/tmp/redim-<fs>-<clair|luks…>-<agrandie|reduite>.img) pour verify_partitions_with_kernel.sh. */
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "fault_bdev.h"
#include "fluluks/blockdev.h"
#include "fluluks/error.h"
#include "fluluks/format.h"
#include "fluluks/luks.h"
#include "fluluks/partedit.h"
#include "fluluks/partops.h"
#include "fsck_util.h"
#include "tt.h"

#define MIB (1024ull * 1024ull)
#define M 2048ull
#define P1 (1 * M)
#define P1_COUNT (200 * M)
#define P2 (401 * M)
#define P2_COUNT (50 * M)
#define NFILES 8
#define FILE_BYTES (10 * MIB)

enum { EXT4, NTFS, LUKS2, LUKS2_FIXE, LUKS1, FAT32 };

static char g_out[65536];
static char g_td[4096];
static const char PASS[] = "phrase de test";

static void contenu(uint8_t *p, size_t n, uint32_t graine) {
  uint32_t x = graine * 2654435761u + 1;
  for (size_t i = 0; i < n; i++) {
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    p[i] = (uint8_t)x;
  }
}

static int lancer(char **argv) { return fu_run(argv, g_out, sizeof g_out); }

/* Dossier de fichiers f0..f7 (10 Mio chacun), une fois. */
static const char *dossier_fichiers(void) {
  static char dir[4200];
  if (dir[0]) return dir;
  snprintf(dir, sizeof dir, "%s/redim-fichiers", g_td);
  mkdir(dir, 0755);
  uint8_t *buf = malloc(FILE_BYTES);
  for (int i = 0; buf && i < NFILES; i++) {
    char f[4300];
    snprintf(f, sizeof f, "%s/f%d", dir, i);
    contenu(buf, FILE_BYTES, (uint32_t)i + 1);
    int fd = open(f, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) {
      if (write(fd, buf, FILE_BYTES) != (ssize_t)FILE_BYTES) dir[0] = 0;
      close(fd);
    }
  }
  free(buf);
  return dir;
}

/* Image ext4 ou NTFS de `bytes` octets remplie des fichiers. */
static int image_fs(const char *path, uint64_t bytes, int fs) {
  unlink(path);
  if (fs == NTFS) {
    int fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0644);
    if (fd < 0 || ftruncate(fd, (off_t)bytes) != 0) return -1;
    close(fd);
    char *a[] = {"mkntfs", "-Q", "-F", (char *)path, NULL};
    if (lancer(a) != 0) return -1;
    char *b[] = {getenv("NTFS_REMPLIR"), (char *)path, (char *)dossier_fichiers(), NULL};
    return b[0] ? lancer(b) : -1;
  }
  char taille[32];
  snprintf(taille, sizeof taille, "%lluk", (unsigned long long)(bytes / 1024));
  char *a[] = {"mke2fs", "-q", "-F", "-t", "ext4", "-O", "metadata_csum,64bit,flex_bg", "-E",
               "lazy_itable_init=0,lazy_journal_init=0", "-d", (char *)dossier_fichiers(), (char *)path, taille,
               NULL};
  return lancer(a);
}

/* Copie le fichier `src` dans `dst` (périphérique) à partir de l'octet 0. */
static int copier_dans(const char *src, fl_bdev *dst) {
  int fd = open(src, O_RDONLY);
  if (fd < 0) return -1;
  static uint8_t buf[MIB];
  uint64_t off = 0;
  int rc = 0;
  for (;;) {
    ssize_t n = pread(fd, buf, sizeof buf, (off_t)off);
    if (n <= 0) break;
    if (n % dst->sector_size) memset(buf + n, 0, dst->sector_size - n % dst->sector_size), n += dst->sector_size - n % dst->sector_size;
    if (fl_bdev_write(dst, off / dst->sector_size, (uint32_t)(n / dst->sector_size), buf) != FL_OK) {
      rc = -1;
      break;
    }
    off += (uint64_t)n;
  }
  close(fd);
  return rc == 0 && fl_bdev_flush(dst) == FL_OK ? 0 : -1;
}

static fl_bdev *ouvrir(const char *img) {
  fl_bdev *d = NULL;
  return fl_file_bdev_open(img, 512, false, &d) == FL_OK ? d : NULL;
}

/* Disque de test, partition 1 au contenu `kind`. */
static int disque(char *img, size_t cap, int kind) {
  snprintf(img, cap, "%s/redim-%d.img", g_td, kind);
  int fd = open(img, O_RDWR | O_CREAT | O_TRUNC, 0644);
  if (fd < 0 || ftruncate(fd, (off_t)(512 * MIB)) != 0) return -1;
  close(fd);
  fl_bdev *d = ouvrir(img);
  fl_pt_layout l;
  int rc = d ? fl_pt_new_table(d, FL_PT_GPT) : FL_EIO;
  if (rc == FL_OK) rc = fl_pt_load(d, &l);
  if (rc == FL_OK) {
    memset(l.e, 0, 2 * sizeof l.e[0]);
    l.e[0].index = 1;
    l.e[0].first_lba = P1;
    l.e[0].sector_count = P1_COUNT;
    l.e[1].index = 2;
    l.e[1].first_lba = P2;
    l.e[1].sector_count = P2_COUNT;
    l.e[0].gpt_type[0] = l.e[1].gpt_type[0] = 0xAF;
    l.count = 2;
    rc = fl_pt_store(d, &l);
  }
  static uint8_t motif[MIB];
  memset(motif, 0x5A, sizeof motif);
  for (uint64_t i = 0; rc == FL_OK && i < 50; i++) rc = fl_bdev_write(d, P2 + i * M, M, motif);
  fl_bdev *p1 = NULL;
  if (rc == FL_OK) rc = fl_slice_bdev_new(d, P1, P1_COUNT, &p1);
  char tmp[4300];
  snprintf(tmp, sizeof tmp, "%s/redim-contenu.img", g_td);
  if (rc == FL_OK && kind == FAT32) {
    fl_bdev_close(p1);
    p1 = NULL;
    l.count = 1;
    rc = fl_pt_load(d, &l);
    if (rc == FL_OK) {
      /* partition 1 retirée puis recréée en FAT32 par le moteur */
      rc = fl_part_delete(d, 1, P1);
      fl_fmt_opts o;
      memset(&o, 0, sizeof o);
      o.fs = FL_FMT_FAT32;
      uint32_t idx = 0;
      if (rc == FL_OK) rc = fl_part_create(d, P1, P1_COUNT, &o, NULL, 0, NULL, NULL, &idx);
    }
  } else if (rc == FL_OK && (kind == EXT4 || kind == NTFS)) {
    rc = image_fs(tmp, P1_COUNT * 512, kind) == 0 && copier_dans(tmp, p1) == 0 ? FL_OK : FL_EIO;
  } else if (rc == FL_OK) {
    /* conteneur LUKS fait par cryptsetup, puis ext4 écrit à travers le moteur */
    char pf[4300], ct[4300];
    snprintf(pf, sizeof pf, "%s/redim.pass", g_td);
    snprintf(ct, sizeof ct, "%s/redim-luks.img", g_td);
    FILE *f = fopen(pf, "wb");
    fwrite(PASS, 1, strlen(PASS), f);
    fclose(f);
    unlink(ct);
    fd = open(ct, O_RDWR | O_CREAT | O_TRUNC, 0644);
    if (fd < 0 || ftruncate(fd, (off_t)(P1_COUNT * 512)) != 0) return -1;
    close(fd);
    char *a1[] = {"cryptsetup", "luksFormat", "-q", "--type", "luks1", "--pbkdf-force-iterations", "1000",
                  "--key-file", pf, ct, NULL};
    char *a2[] = {"cryptsetup", "luksFormat", "-q", "--type", "luks2", "--pbkdf", "pbkdf2",
                  "--pbkdf-force-iterations", "1000", "--key-file", pf, ct, NULL};
    rc = lancer(kind == LUKS1 ? a1 : a2) == 0 ? FL_OK : FL_EIO;
    if (rc == FL_OK && kind == LUKS2_FIXE) {
      char script[4300], taille[32];
      snprintf(script, sizeof script, "%s/../tools/fixtures/luks2_segment_fixe.py", FL_SOURCE_DIR);
      snprintf(taille, sizeof taille, "%llu", 150ull * MIB);
      char *a[] = {"python3", "-I", script, ct, taille, NULL};
      rc = lancer(a) == 0 ? FL_OK : FL_EIO;
    }
    if (rc == FL_OK) rc = copier_dans(ct, p1) == 0 ? FL_OK : FL_EIO;
    fl_luks *lk = NULL;
    fl_bdev *in = NULL;
    if (rc == FL_OK) rc = fl_luks_open(p1, &lk);
    if (rc == FL_OK) rc = fl_luks_unlock(lk, PASS, strlen(PASS), &in);
    if (rc == FL_OK) rc = image_fs(tmp, fl_bdev_size_bytes(in), EXT4) == 0 && copier_dans(tmp, in) == 0 ? FL_OK : FL_EIO;
    fl_bdev_close(in);
    fl_luks_close(lk);
    unlink(ct);
  }
  unlink(tmp);
  fl_bdev_close(p1);
  fl_bdev_close(d);
  return rc == FL_OK ? 0 : -1;
}

static int extraire(const char *img, uint64_t first, uint64_t count, char *out, size_t cap) {
  snprintf(out, cap, "%s/redim-extrait.img", g_td);
  int in = open(img, O_RDONLY), o = open(out, O_RDWR | O_CREAT | O_TRUNC, 0644);
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

/* Début et taille de la partition 1 selon sfdisk -d. */
static int p1_selon_sfdisk(const char *img, uint64_t *start, uint64_t *size) {
  char *a[] = {"sfdisk", "-d", (char *)img, NULL};
  if (lancer(a) != 0) return -1;
  const char *p = strstr(g_out, "1 : start=");
  if (!p) return -1;
  unsigned long long s = 0, n = 0;
  if (sscanf(p, "1 : start= %llu, size= %llu", &s, &n) != 2) return -1;
  *start = s;
  *size = n;
  return 0;
}

static int voisine_intacte(const char *img) {
  int fd = open(img, O_RDONLY);
  static uint8_t buf[MIB];
  int ok = fd >= 0;
  for (uint64_t i = 0; ok && i < 50; i++) {
    ok = pread(fd, buf, sizeof buf, (off_t)((P2 + i * M) * 512)) == (ssize_t)sizeof buf;
    for (size_t k = 0; ok && k < sizeof buf; k++) ok = buf[k] == 0x5A;
  }
  if (fd >= 0) close(fd);
  return ok;
}

static int fichiers_ext4(const char *img) {
  uint8_t *attendu = malloc(FILE_BYTES), *lu = malloc(FILE_BYTES + 1);
  int ok = attendu && lu;
  for (int i = 0; ok && i < NFILES; i++) {
    char p[32];
    snprintf(p, sizeof p, "/f%d", i);
    contenu(attendu, FILE_BYTES, (uint32_t)i + 1);
    ok = fu_debugfs_cat(img, p, lu, FILE_BYTES + 1) == (int64_t)FILE_BYTES && memcmp(attendu, lu, FILE_BYTES) == 0;
  }
  free(attendu);
  free(lu);
  return ok;
}

/* Juge la partition 1 de `count` secteurs : système de fichiers propre, fichiers intacts. */
static int juger(const char *img, int kind, uint64_t count, const char *manifest_avant) {
  char part[4300];
  if (extraire(img, P1, count, part, sizeof part) != 0) return -1;
  int ok;
  if (kind == NTFS) {
    char m2[4300];
    snprintf(m2, sizeof m2, "%s/redim-apres.manifest", g_td);
    ok = fu_ntfsfix_n(part, g_out, sizeof g_out) == 0 && fu_ntfs_manifest(part, m2) == 0;
    size_t n1 = 0, n2 = 0;
    uint8_t *a = lire_tout(manifest_avant, &n1), *b = lire_tout(m2, &n2);
    ok = ok && a && b && n1 == n2 && memcmp(a, b, n1) == 0;
    free(a);
    free(b);
  } else if (kind == EXT4) {
    ok = fu_e2fsck_n(part, g_out, sizeof g_out) == 0 && fichiers_ext4(part);
  } else {
    char pf[4300], plain[4096];
    snprintf(pf, sizeof pf, "%s/redim.pass", g_td);
    ok = fu_extract_luks_ext4(part, pf, plain, sizeof plain) == 0;
    ok = ok && fu_e2fsck_n(plain, g_out, sizeof g_out) == 0 && fichiers_ext4(plain);
    unlink(plain);
  }
  if (!ok) fprintf(stderr, "juge : %s\n", g_out);
  unlink(part);
  return ok ? 0 : -1;
}

static int g_pct;
static void progres(int pct, void *arg) {
  (void)arg;
  g_pct = pct < g_pct ? 1000 : pct;
}

static void cas(int kind, uint64_t new_count) {
  char img[4200], man[4300];
  TT_ASSERT_EQ(disque(img, sizeof img, kind), 0);
  snprintf(man, sizeof man, "%s/redim-avant.manifest", g_td);
  if (kind == NTFS) {
    char part[4300];
    TT_ASSERT_EQ(extraire(img, P1, P1_COUNT, part, sizeof part), 0);
    TT_ASSERT_EQ(fu_ntfs_manifest(part, man), 0);
  }
  fl_bdev *d = ouvrir(img);
  TT_ASSERT(d);
  bool chiffre = kind == LUKS1 || kind == LUKS2 || kind == LUKS2_FIXE;
  fl_resize_info info;
  int rc = fl_part_resize_info(d, 1, P1, chiffre ? PASS : NULL, chiffre ? strlen(PASS) : 0, &info);
  g_pct = -1;
  int rc2 = rc == FL_OK ? fl_part_resize(d, 1, P1, new_count, chiffre ? PASS : NULL, chiffre ? strlen(PASS) : 0,
                                         progres, NULL)
                        : rc;
  fl_bdev_close(d);
  TT_ASSERT_EQ(rc, FL_OK);
  if (!info.check.clean) fprintf(stderr, "%s\n", info.check.report);
  TT_ASSERT(info.resizable);
  TT_ASSERT(info.check.clean);
  TT_ASSERT_EQ(info.max_bytes, 400 * MIB);
  TT_ASSERT(info.min_bytes < 140 * MIB);
  TT_ASSERT_EQ(rc2, FL_OK);
  TT_ASSERT_EQ(g_pct, 100);
  uint64_t start = 0, size = 0;
  TT_ASSERT_EQ(p1_selon_sfdisk(img, &start, &size), 0);
  TT_ASSERT_EQ(start, P1); /* le début ne bouge jamais */
  TT_ASSERT_EQ(size, new_count);
  TT_ASSERT(voisine_intacte(img));
  TT_ASSERT_EQ(juger(img, kind, new_count, man), 0);
  if (kind == LUKS2_FIXE) {
    char part[4300];
    TT_ASSERT_EQ(extraire(img, P1, new_count, part, sizeof part), 0);
    char *a[] = {"cryptsetup", "luksDump", part, NULL};
    TT_ASSERT_EQ(lancer(a), 0);
    char attendu[64];
    snprintf(attendu, sizeof attendu, "length: %llu [bytes]", (unsigned long long)(new_count * 512 - 16 * MIB));
    if (!strstr(g_out, attendu)) fprintf(stderr, "%s\n", g_out);
    TT_ASSERT(strstr(g_out, attendu) != NULL);
    unlink(part);
  }
  if (getenv("FL_KEEP")) { /* gardée pour tools/fixtures/verify_partitions_with_kernel.sh */
    static const char *noms[] = {"ext4-clair", "ntfs-clair", "ext4-luks2", "ext4-luks2fixe", "ext4-luks1"};
    char garde[4300];
    snprintf(garde, sizeof garde, "%s/redim-%s-%s.img", g_td, noms[kind], new_count > P1_COUNT ? "agrandie" : "reduite");
    TT_ASSERT_EQ(rename(img, garde), 0);
  } else {
    unlink(img);
  }
}

static void test_grow_ext4(void) { cas(EXT4, 300 * M); }
static void test_shrink_ext4(void) { cas(EXT4, 140 * M); }
static void test_grow_ntfs(void) { cas(NTFS, 300 * M); }
static void test_shrink_ntfs(void) { cas(NTFS, 140 * M); }
static void test_grow_luks2_ext4(void) { cas(LUKS2, 400 * M); }
static void test_shrink_luks2_ext4(void) { cas(LUKS2, 140 * M); }
static void test_grow_luks1_ext4(void) { cas(LUKS1, 300 * M); }
static void test_resize_luks2_fixed_segment(void) { cas(LUKS2_FIXE, 300 * M); }

static void inchange(int kind, uint64_t new_count, int attendu) {
  char img[4200];
  TT_ASSERT_EQ(disque(img, sizeof img, kind), 0);
  size_t n1 = 0, n2 = 0;
  uint8_t *avant = lire_tout(img, &n1);
  fl_bdev *d = ouvrir(img);
  int rc = d ? fl_part_resize(d, 1, P1, new_count, NULL, 0, NULL, NULL) : FL_EIO;
  fl_bdev_close(d);
  uint8_t *apres = lire_tout(img, &n2);
  int same = avant && apres && n1 == n2 && memcmp(avant, apres, n1) == 0;
  free(avant);
  free(apres);
  unlink(img);
  TT_ASSERT_EQ(rc, attendu);
  TT_ASSERT(same);
}

static void test_shrink_below_minimum_refused(void) { inchange(EXT4, 40 * M, FL_EINVAL); }
static void test_grow_beyond_free_refused(void) { inchange(EXT4, 401 * M, FL_EINVAL); }
static void test_unaligned_refused(void) { inchange(EXT4, 300 * M + 1, FL_EINVAL); }

static void test_fat_not_resizable(void) {
  char img[4200];
  TT_ASSERT_EQ(disque(img, sizeof img, FAT32), 0);
  fl_bdev *d = ouvrir(img);
  TT_ASSERT(d);
  fl_resize_info info;
  int rc = fl_part_resize_info(d, 1, P1, NULL, 0, &info);
  int rc2 = fl_part_resize(d, 1, P1, 300 * M, NULL, 0, NULL, NULL);
  fl_bdev_close(d);
  unlink(img);
  TT_ASSERT_EQ(rc, FL_OK);
  TT_ASSERT(!info.resizable);
  TT_ASSERT(info.why && strstr(info.why, "FAT32 et exFAT") != NULL);
  TT_ASSERT_EQ(rc2, FL_ENOTSUP);
}

static void test_resize_refused_when_check_fails(void) {
  char img[4200], part[4300];
  TT_ASSERT_EQ(disque(img, sizeof img, EXT4), 0);
  /* inode 12 (premier fichier) effacé dans la partition, puis remis en place */
  TT_ASSERT_EQ(extraire(img, P1, P1_COUNT, part, sizeof part), 0);
  char *a[] = {"debugfs", "-w", "-R", "clri <12>", part, NULL};
  TT_ASSERT_EQ(lancer(a), 0);
  fl_bdev *d = ouvrir(img), *p1 = NULL;
  TT_ASSERT(d);
  TT_ASSERT_EQ(fl_slice_bdev_new(d, P1, P1_COUNT, &p1), FL_OK);
  TT_ASSERT_EQ(copier_dans(part, p1), 0);
  fl_bdev_close(p1);
  fl_bdev_close(d);
  unlink(part);
  size_t n1 = 0, n2 = 0;
  uint8_t *avant = lire_tout(img, &n1);
  d = ouvrir(img);
  fl_resize_info info;
  int rc = d ? fl_part_resize_info(d, 1, P1, NULL, 0, &info) : FL_EIO;
  int rc2 = d ? fl_part_resize(d, 1, P1, 300 * M, NULL, 0, NULL, NULL) : FL_EIO;
  fl_bdev_close(d);
  uint8_t *apres = lire_tout(img, &n2);
  int same = avant && apres && n1 == n2 && memcmp(avant, apres, n1) == 0;
  free(avant);
  free(apres);
  unlink(img);
  TT_ASSERT_EQ(rc, FL_OK);
  TT_ASSERT(!info.check.clean);
  TT_ASSERT(strlen(info.check.report) > 0);
  TT_ASSERT_EQ(rc2, FL_ECORRUPT);
  TT_ASSERT(same);
}

/* Nombre d'écritures de fl_pt_store pour la table de `img` portée à p1_count (sur une copie). */
static uint64_t ecritures_table(const char *img, uint64_t p1_count) {
  char copie[4096];
  if (fu_copy_image(img, copie, sizeof copie) != 0) return 0;
  fl_bdev *d = ouvrir(copie), *f = NULL;
  uint64_t n = 0;
  fl_pt_layout l;
  if (d && fl_fault_bdev_new(d, UINT64_MAX, FL_EIO, &f) == FL_OK && fl_pt_load(f, &l) == FL_OK) {
    l.e[0].sector_count = p1_count;
    if (fl_pt_store(f, &l) == FL_OK) n = fl_fault_bdev_writes(f);
  }
  fl_bdev_close(f);
  fl_bdev_close(d);
  unlink(copie);
  return n;
}

/* Écritures d'un redimensionnement complet (sur une copie). */
static uint64_t ecritures_redim(const char *img, uint64_t new_count) {
  char copie[4096];
  if (fu_copy_image(img, copie, sizeof copie) != 0) return 0;
  fl_bdev *d = ouvrir(copie), *f = NULL;
  uint64_t n = 0;
  if (d && fl_fault_bdev_new(d, UINT64_MAX, FL_EIO, &f) == FL_OK &&
      fl_part_resize(f, 1, P1, new_count, NULL, 0, NULL, NULL) == FL_OK)
    n = fl_fault_bdev_writes(f);
  fl_bdev_close(f);
  fl_bdev_close(d);
  unlink(copie);
  return n;
}

static void coupure(uint64_t new_count, bool grow) {
  char img[4200];
  TT_ASSERT_EQ(disque(img, sizeof img, EXT4), 0);
  uint64_t t = ecritures_table(img, new_count);
  uint64_t total = grow ? 0 : ecritures_redim(img, new_count);
  TT_ASSERT(t > 0);
  TT_ASSERT(grow || total > t);
  uint64_t ok = grow ? t : total - t; /* agrandir : coupé juste après la table ; réduire : juste avant */
  fl_bdev *d = ouvrir(img), *f = NULL;
  TT_ASSERT(d);
  TT_ASSERT_EQ(fl_fault_bdev_new(d, ok, FL_ENODEV, &f), FL_OK);
  int rc = fl_part_resize(f, 1, P1, new_count, NULL, 0, NULL, NULL);
  fl_bdev_close(f);
  fl_bdev_close(d);
  TT_ASSERT(rc != FL_OK);
  uint64_t start = 0, size = 0;
  TT_ASSERT_EQ(p1_selon_sfdisk(img, &start, &size), 0);
  TT_ASSERT_EQ(start, P1);
  TT_ASSERT_EQ(size, grow ? new_count : P1_COUNT); /* agrandir : table écrite ; réduire : table ancienne */
  TT_ASSERT_EQ(juger(img, EXT4, size, NULL), 0);   /* le système de fichiers tient dans sa partition */
  unlink(img);
}

static void test_grow_cut_after_table_keeps_data(void) { coupure(300 * M, true); }
static void test_shrink_cut_before_table_keeps_data(void) { coupure(140 * M, false); }

int main(void) {
  char *a[] = {"cryptsetup", "--version", NULL};
  if (!fu_tools_available() || !fu_ntfs_tools_available() || !getenv("NTFS_REMPLIR") ||
      fu_run(a, g_out, sizeof g_out) != 0 || fu_tmpdir(g_td, sizeof g_td) != 0) {
    fprintf(stderr, "juges absents : test sauté\n");
    return 0;
  }
  TT_RUN(test_grow_ext4);
  TT_RUN(test_shrink_ext4);
  TT_RUN(test_grow_ntfs);
  TT_RUN(test_shrink_ntfs);
  TT_RUN(test_grow_luks2_ext4);
  TT_RUN(test_shrink_luks2_ext4);
  TT_RUN(test_grow_luks1_ext4);
  TT_RUN(test_resize_luks2_fixed_segment);
  TT_RUN(test_shrink_below_minimum_refused);
  TT_RUN(test_grow_beyond_free_refused);
  TT_RUN(test_unaligned_refused);
  TT_RUN(test_fat_not_resizable);
  TT_RUN(test_resize_refused_when_check_fails);
  TT_RUN(test_grow_cut_after_table_keeps_data);
  TT_RUN(test_shrink_cut_before_table_keeps_data);
  TT_MAIN_END();
}

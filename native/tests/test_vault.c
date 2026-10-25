#define _GNU_SOURCE
/* Phase 14, T3 : coffres (fichier LUKS2 sans table + exFAT ou ext4), posés sur un fichier du téléphone
 * (descripteur) ou sur un fichier d'un volume du moteur. Juges externes sur le PC : e2fsck, fsck.exfat,
 * cryptsetup (sans root). FL_KEEP=1 garde build/native/tmp/coffre-<fs>.luks et coffre-<fs>.sha256 pour
 * tools/fixtures/verify_vault_with_kernel.sh. */
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "crypto/fl_crypto.h"
#include "fluluks/blockdev.h"
#include "fluluks/error.h"
#include "fluluks/format.h"
#include "fluluks/fs.h"
#include "fluluks/luks.h"
#include "fluluks/partition.h"
#include "fluluks/probe.h"
#include "fsck_util.h"
#include "tt.h"

#define MIB (1024ull * 1024ull)
#define PASS "phrase de passe du coffre"
#define MEM 8192 /* Kio : Argon2 rapide pour les tests (1 Gio dans l'application) */

static int image(char *path, size_t cap, const char *nom, uint64_t bytes) {
  char td[4096];
  if (fu_tmpdir(td, sizeof td) != 0) return -1;
  snprintf(path, cap, "%s/%s", td, nom);
  int fd = open(path, O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
  if (fd < 0) return -1;
  int rc = ftruncate(fd, (off_t)bytes);
  close(fd);
  return rc;
}

static void motif(uint8_t *p, size_t n, uint32_t graine) {
  for (size_t i = 0; i < n; i++) {
    graine = graine * 1103515245u + 12345u;
    p[i] = (uint8_t)(graine >> 16);
  }
}

static fl_fmt_opts opts(fl_fmt_fs fs) {
  fl_fmt_opts o;
  memset(&o, 0, sizeof o);
  o.fs = fs;
  o.encrypted = true;
  o.label = "Coffre";
  o.kdf_mem_kib = MEM;
  o.root_uid = 1000;
  o.root_gid = 1000;
  o.no_table = true;
  return o;
}

/* Déverrouille et monte le coffre `d` ; *dec et *l à fermer par fermer(). */
static int monter(fl_bdev *d, bool rw, fl_luks **l, fl_bdev **dec, fl_fs **fs) {
  *l = NULL;
  *dec = NULL;
  *fs = NULL;
  int rc = fl_luks_open(d, l);
  if (rc == FL_OK) rc = fl_luks_unlock(*l, PASS, strlen(PASS), dec);
  fl_probe_result p;
  if (rc == FL_OK) rc = fl_probe(*dec, &p);
  if (rc == FL_OK) rc = fl_fs_mount(*dec, p.content, rw, fs);
  return rc;
}

static void fermer(fl_luks *l, fl_bdev *dec, fl_fs *fs) {
  if (fs) fl_fs_unmount(fs);
  fl_bdev_close(dec);
  fl_luks_close(l);
}

static int ecrire(fl_fs *fs, const char *path, const void *buf, size_t len) {
  fl_file *f = NULL;
  int rc = fl_fs_open(fs, path, FL_O_RDWR | FL_O_CREAT | FL_O_TRUNC, &f);
  if (rc != FL_OK) return rc;
  int64_t n = fl_file_pwrite(f, buf, len, 0);
  int rc2 = fl_file_close(f);
  if (n < 0) return (int)n;
  return n == (int64_t)len ? rc2 : FL_EIO;
}

static int lire_egal(fl_fs *fs, const char *path, const void *attendu, size_t len) {
  fl_file *f = NULL;
  int rc = fl_fs_open(fs, path, FL_O_RDONLY, &f);
  if (rc != FL_OK) return rc;
  static uint8_t lu[2 * 1024 * 1024 + 1];
  int64_t n = fl_file_pread(f, lu, sizeof lu, 0);
  fl_file_close(f);
  if (n < 0) return (int)n;
  return n == (int64_t)len && memcmp(lu, attendu, len) == 0 ? FL_OK : FL_ECORRUPT;
}

static void hex(const uint8_t *d, size_t n, char *out) {
  for (size_t i = 0; i < n; i++) sprintf(out + 2 * i, "%02x", d[i]);
}

/* Contenu témoin d'un coffre : deux fichiers, et leur manifeste au format de sha256sum. */
static uint8_t g_gros[1024 * 1024];
static const char g_note[] = "bonjour du coffre\n";

static int remplir_coffre(fl_fs *fs) {
  motif(g_gros, sizeof g_gros, 1414);
  int rc = ecrire(fs, "/note.txt", g_note, strlen(g_note));
  if (rc == FL_OK) rc = fl_fs_mkdir(fs, "/dossier");
  if (rc == FL_OK) rc = ecrire(fs, "/dossier/données.bin", g_gros, sizeof g_gros);
  return rc;
}

static int verifier_coffre(fl_fs *fs) {
  int rc = lire_egal(fs, "/note.txt", g_note, strlen(g_note));
  if (rc == FL_OK) rc = lire_egal(fs, "/dossier/données.bin", g_gros, sizeof g_gros);
  return rc;
}

static int manifeste(const char *path) {
  uint8_t h[32];
  char x[65];
  FILE *f = fopen(path, "w");
  if (!f) return -1;
  fl_hash("sha256", g_note, strlen(g_note), h);
  hex(h, 32, x);
  fprintf(f, "%s  note.txt\n", x);
  fl_hash("sha256", g_gros, sizeof g_gros, h);
  hex(h, 32, x);
  fprintf(f, "%s  dossier/données.bin\n", x);
  return fclose(f);
}

/* Le coffre est un fichier LUKS2 sans table : le scan voit une seule « partition » 0, qui est du LUKS2,
 * et le dernier Mio (où vivrait une GPT de secours) n'est pas effacé. */
static void vaultFormatHasNoTable(void) {
  char img[4096];
  TT_ASSERT_EQ(image(img, sizeof img, "coffre-table.luks", 40 * MIB), 0);
  fl_bdev *d = NULL;
  TT_ASSERT_EQ(fl_file_bdev_open(img, 512, false, &d), FL_OK);
  uint8_t marque[512], lu[512];
  memset(marque, 0xA5, sizeof marque);
  TT_ASSERT_EQ(fl_bdev_write(d, d->sector_count - 1, 1, marque), FL_OK);
  fl_fmt_opts o = opts(FL_FMT_EXFAT);
  TT_ASSERT_EQ(fl_format(d, &o, PASS, strlen(PASS), NULL, NULL), FL_OK);
  fl_part_table t;
  TT_ASSERT_EQ(fl_part_scan(d, &t), FL_OK);
  TT_ASSERT_EQ(t.kind, FL_PT_NONE);
  TT_ASSERT_EQ(t.count, 1);
  TT_ASSERT_EQ(t.parts[0].index, 0);
  TT_ASSERT_EQ(t.parts[0].first_lba, 0);
  TT_ASSERT_EQ(t.parts[0].sector_count, d->sector_count);
  fl_probe_result p;
  TT_ASSERT_EQ(fl_probe(d, &p), FL_OK);
  TT_ASSERT_EQ(p.content, FL_CONTENT_LUKS2);
  TT_ASSERT_EQ(fl_bdev_read(d, d->sector_count - 1, 1, lu), FL_OK);
  TT_ASSERT_MEM_EQ(lu, marque, sizeof lu);
  fl_bdev_close(d);
  unlink(img);
}

static void un_coffre(fl_fmt_fs fs, const char *nom) {
  char img[4096], td[4096], man[4200];
  char fichier[64];
  snprintf(fichier, sizeof fichier, "coffre-%s.luks", nom);
  TT_ASSERT_EQ(image(img, sizeof img, fichier, 48 * MIB), 0);
  fl_bdev *d = NULL, *dec = NULL;
  fl_luks *l = NULL;
  fl_fs *v = NULL;
  TT_ASSERT_EQ(fl_file_bdev_open(img, 512, false, &d), FL_OK);
  fl_fmt_opts o = opts(fs);
  TT_ASSERT_EQ(fl_format(d, &o, PASS, strlen(PASS), NULL, NULL), FL_OK);
  TT_ASSERT_EQ(monter(d, true, &l, &dec, &v), FL_OK);
  fl_statfs st;
  TT_ASSERT_EQ(fl_fs_statfs(v, &st), FL_OK);
  TT_ASSERT(!st.read_only);
  TT_ASSERT_STR_EQ(st.label, "Coffre");
  TT_ASSERT_EQ(remplir_coffre(v), FL_OK);
  if (fs == FL_FMT_EXT4) {
    fl_stat s;
    TT_ASSERT_EQ(fl_fs_stat(v, "/", &s), FL_OK);
    TT_ASSERT_EQ(s.uid, 1000);
    TT_ASSERT_EQ(s.gid, 1000);
  }
  fermer(l, dec, v);
  TT_ASSERT_EQ(monter(d, false, &l, &dec, &v), FL_OK);
  TT_ASSERT_EQ(verifier_coffre(v), FL_OK);
  fermer(l, dec, v);
  fl_bdev_close(d);
  const char *keep = getenv("FL_KEEP");
  if (keep && *keep == '1') {
    TT_ASSERT_EQ(fu_tmpdir(td, sizeof td), 0);
    snprintf(man, sizeof man, "%s/coffre-%s.sha256", td, nom);
    TT_ASSERT_EQ(manifeste(man), 0);
    fprintf(stderr, "gardé : %s et %s\n", img, man);
  } else {
    unlink(img);
  }
}

static void vaultExfatAndExt4MountAndWrite(void) {
  un_coffre(FL_FMT_EXFAT, "exfat");
  un_coffre(FL_FMT_EXT4, "ext4");
}

/* fl_fd_bdev_open prend le descripteur : il est fermé avec le périphérique, et aussi en cas d'échec. */
static void fdBdevOwnsDescriptor(void) {
  char img[4096];
  TT_ASSERT_EQ(image(img, sizeof img, "coffre-fd.luks", 4 * MIB), 0);
  int fd = open(img, O_RDWR | O_CLOEXEC);
  TT_ASSERT(fd >= 0);
  fl_bdev *d = NULL;
  TT_ASSERT_EQ(fl_fd_bdev_open(fd, 512, false, &d), FL_OK);
  TT_ASSERT_EQ(d->sector_size, 512);
  TT_ASSERT_EQ(d->sector_count, 4 * MIB / 512);
  uint8_t a[1024], b[1024];
  motif(a, sizeof a, 7);
  TT_ASSERT_EQ(fl_bdev_write(d, 100, 2, a), FL_OK);
  TT_ASSERT_EQ(fl_bdev_flush(d), FL_OK);
  TT_ASSERT_EQ(fl_bdev_read(d, 100, 2, b), FL_OK);
  TT_ASSERT_MEM_EQ(a, b, sizeof a);
  fl_bdev_close(d);
  errno = 0;
  TT_ASSERT_EQ(fcntl(fd, F_GETFD), -1);
  TT_ASSERT_EQ(errno, EBADF);

  /* échec (taille de secteur nulle) : descripteur fermé quand même */
  fd = open(img, O_RDWR | O_CLOEXEC);
  TT_ASSERT(fd >= 0);
  d = (fl_bdev *)1;
  TT_ASSERT_EQ(fl_fd_bdev_open(fd, 0, false, &d), FL_EINVAL);
  TT_ASSERT(d == NULL);
  errno = 0;
  TT_ASSERT_EQ(fcntl(fd, F_GETFD), -1);
  TT_ASSERT_EQ(errno, EBADF);

  /* lecture seule */
  fd = open(img, O_RDONLY | O_CLOEXEC);
  TT_ASSERT(fd >= 0);
  TT_ASSERT_EQ(fl_fd_bdev_open(fd, 512, true, &d), FL_OK);
  TT_ASSERT_EQ(fl_bdev_read(d, 100, 2, b), FL_OK);
  TT_ASSERT_MEM_EQ(a, b, sizeof a);
  TT_ASSERT_EQ(fl_bdev_write(d, 100, 2, a), FL_EROFS);
  fl_bdev_close(d);
  TT_ASSERT_EQ(fl_fd_bdev_open(-1, 512, false, &d), FL_EINVAL);
  unlink(img);
}

/* --- coffre dans un fichier d'un volume du moteur ------------------------------------------- */

typedef struct {
  char img[4096];
  fl_bdev *dev;
  fl_fs *fs;
  fl_file *f;
  fl_bdev *vd; /* disque du coffre, sur f */
} hote;

static int mkfs(fl_bdev *d, fl_fmt_fs fs) {
  switch (fs) {
    case FL_FMT_EXT4: return fl_mkfs_ext4(d, "Hote", 0, 0);
    case FL_FMT_EXFAT: return fl_mkfs_fat(d, true, "Hote");
    case FL_FMT_FAT32: return fl_mkfs_fat(d, false, "HOTE");
    default: return FL_EINVAL;
  }
}

static int monter_hote(hote *h, bool rw) {
  fl_probe_result p;
  int rc = fl_file_bdev_open(h->img, 512, !rw, &h->dev);
  if (rc == FL_OK) rc = fl_probe(h->dev, &p);
  if (rc == FL_OK) rc = fl_fs_mount(h->dev, p.content, rw, &h->fs);
  return rc;
}

static void demonter_hote(hote *h) {
  fl_bdev_close(h->vd);
  h->vd = NULL;
  fl_file_close(h->f);
  h->f = NULL;
  fl_fs_unmount(h->fs);
  h->fs = NULL;
  fl_bdev_close(h->dev);
  h->dev = NULL;
}

/* Image hôte de `taille`, formatée en `hfs`, montée en écriture, avec /coffre.luks (place écrite par des
 * zéros) formaté en coffre `vfs`. h->vd reste ouvert. */
static int preparer(hote *h, const char *nom, uint64_t taille, fl_fmt_fs hfs, fl_fmt_fs vfs, uint64_t vtaille) {
  memset(h, 0, sizeof *h);
  if (image(h->img, sizeof h->img, nom, taille) != 0) return FL_EIO;
  int rc = fl_file_bdev_open(h->img, 512, false, &h->dev);
  if (rc == FL_OK) rc = mkfs(h->dev, hfs);
  fl_bdev_close(h->dev);
  h->dev = NULL;
  if (rc == FL_OK) rc = monter_hote(h, true);
  if (rc == FL_OK) rc = fl_fs_open(h->fs, "/coffre.luks", FL_O_RDWR | FL_O_CREAT, &h->f);
  static uint8_t zeros[1024 * 1024];
  for (uint64_t off = 0; rc == FL_OK && off < vtaille; off += sizeof zeros) {
    int64_t n = fl_file_pwrite(h->f, zeros, sizeof zeros, off);
    if (n < 0) rc = (int)n;
  }
  if (rc == FL_OK) rc = fl_fsfile_bdev_new(h->f, vtaille, false, &h->vd);
  fl_fmt_opts o = opts(vfs);
  if (rc == FL_OK) rc = fl_format(h->vd, &o, PASS, strlen(PASS), NULL, NULL);
  return rc;
}

/* Copie du volume déchiffré d'un coffre vers un fichier, pour fsck. */
static int extraire(fl_bdev *vd, const char *dst) {
  fl_luks *l = NULL;
  fl_bdev *dec = NULL;
  int rc = fl_luks_open(vd, &l);
  if (rc == FL_OK) rc = fl_luks_unlock(l, PASS, strlen(PASS), &dec);
  FILE *f = rc == FL_OK ? fopen(dst, "wb") : NULL;
  if (rc == FL_OK && !f) rc = FL_EIO;
  static uint8_t buf[1024 * 1024];
  uint32_t n = (uint32_t)(sizeof buf / 512);
  for (uint64_t lba = 0; rc == FL_OK && lba < dec->sector_count; lba += n) {
    uint32_t k = dec->sector_count - lba < n ? (uint32_t)(dec->sector_count - lba) : n;
    rc = fl_bdev_read(dec, lba, k, buf);
    if (rc == FL_OK && fwrite(buf, 512, k, f) != k) rc = FL_EIO;
  }
  if (f && fclose(f) != 0 && rc == FL_OK) rc = FL_EIO;
  fl_bdev_close(dec);
  fl_luks_close(l);
  return rc;
}

static int juger(const char *img, fl_fmt_fs fs, const char *quoi) {
  char out[1 << 14];
  int rc;
  if (fs == FL_FMT_EXT4) {
    if (!fu_tools_available()) return 0;
    rc = fu_e2fsck_n(img, out, sizeof out);
  } else {
    if (!fu_fat_tools_available()) return 0;
    rc = fu_fsck_fat_n(img, out, sizeof out);
  }
  if (rc != 0) fprintf(stderr, "%s pas propre (%d) :\n%s\n", quoi, rc, out);
  return rc;
}

static void sur_hote(fl_fmt_fs hfs, fl_fmt_fs vfs, const char *nom) {
  hote h;
  char img[64];
  snprintf(img, sizeof img, "hote-%s.img", nom);
  TT_ASSERT_EQ(preparer(&h, img, 128 * MIB, hfs, vfs, 64 * MIB), FL_OK);
  fl_luks *l = NULL;
  fl_bdev *dec = NULL;
  fl_fs *v = NULL;
  TT_ASSERT_EQ(monter(h.vd, true, &l, &dec, &v), FL_OK);
  TT_ASSERT_EQ(remplir_coffre(v), FL_OK);
  /* l'hôte ne se démonte pas tant que le fichier du coffre est ouvert */
  TT_ASSERT_EQ(fl_fs_unmount(h.fs), FL_EINVAL);
  fermer(l, dec, v);
  demonter_hote(&h);
  TT_ASSERT_EQ(juger(h.img, hfs, "hôte"), 0);

  /* relu en lecture seule par un nouveau montage de l'hôte */
  TT_ASSERT_EQ(monter_hote(&h, false), FL_OK);
  TT_ASSERT_EQ(fl_fs_open(h.fs, "/coffre.luks", FL_O_RDONLY, &h.f), FL_OK);
  TT_ASSERT_EQ(fl_fsfile_bdev_new(h.f, 64 * MIB, true, &h.vd), FL_OK);
  TT_ASSERT(h.vd->read_only);
  TT_ASSERT_EQ(monter(h.vd, false, &l, &dec, &v), FL_OK);
  TT_ASSERT_EQ(verifier_coffre(v), FL_OK);
  fermer(l, dec, v);
  char td[4096], plain[4200];
  TT_ASSERT_EQ(fu_tmpdir(td, sizeof td), 0);
  snprintf(plain, sizeof plain, "%s/coffre-clair-%s.img", td, nom);
  TT_ASSERT_EQ(extraire(h.vd, plain), FL_OK);
  demonter_hote(&h);
  TT_ASSERT_EQ(juger(plain, vfs, "coffre"), 0);
  unlink(plain);
  unlink(h.img);
}

static void vaultOnEngineFileRoundTrip(void) {
  sur_hote(FL_FMT_EXT4, FL_FMT_EXFAT, "ext4-exfat");
  sur_hote(FL_FMT_EXFAT, FL_FMT_EXFAT, "exfat-exfat");
  sur_hote(FL_FMT_EXFAT, FL_FMT_EXT4, "exfat-ext4");
}

/* --- quatre fils : deux dans le coffre, deux dans son hôte, en même temps ---------------------- */

#define ZONE (2 * 1024 * 1024)
#define BLOC (64 * 1024)

typedef struct {
  fl_fs *fs;
  const char *path;
  uint32_t graine;
  uint8_t modele[ZONE];
  atomic_int *stop;
  int err;
  unsigned tours;
} fil;

static void *travail(void *arg) {
  fil *t = arg;
  static _Thread_local uint8_t bloc[BLOC], lu[BLOC];
  fl_file *f = NULL;
  t->err = fl_fs_open(t->fs, t->path, FL_O_RDWR | FL_O_CREAT | FL_O_TRUNC, &f);
  if (t->err == FL_OK && fl_file_pwrite(f, t->modele, ZONE, 0) != ZONE) t->err = FL_EIO;
  uint32_t g = t->graine;
  while (t->err == FL_OK && !atomic_load(t->stop)) {
    g = g * 1103515245u + 12345u;
    uint64_t off = (uint64_t)((g >> 8) % (ZONE / BLOC)) * BLOC;
    motif(bloc, BLOC, g);
    if (fl_file_pwrite(f, bloc, BLOC, off) != BLOC) t->err = FL_EIO;
    if (t->err == FL_OK && fl_file_pread(f, lu, BLOC, off) != BLOC) t->err = FL_EIO;
    if (t->err == FL_OK && memcmp(lu, bloc, BLOC) != 0) t->err = FL_ECORRUPT;
    if (t->err == FL_OK) memcpy(t->modele + off, bloc, BLOC);
    if (t->err == FL_OK && ++t->tours % 16 == 0) t->err = fl_fs_sync(t->fs);
  }
  int rc = fl_file_close(f);
  if (t->err == FL_OK) t->err = rc;
  return NULL;
}

static void vaultOnEngineFileNoDeadlock(void) {
  alarm(300); /* un interblocage tue le test (SIGALRM) au lieu de le laisser pendre */
  hote h;
  TT_ASSERT_EQ(preparer(&h, "hote-fils.img", 160 * MIB, FL_FMT_EXFAT, FL_FMT_EXFAT, 64 * MIB), FL_OK);
  fl_luks *l = NULL;
  fl_bdev *dec = NULL;
  fl_fs *v = NULL;
  TT_ASSERT_EQ(monter(h.vd, true, &l, &dec, &v), FL_OK);
  atomic_int stop = 0;
  static fil fils[4];
  const char *noms[4] = {"/a.bin", "/b.bin", "/h1.bin", "/h2.bin"};
  pthread_t th[4];
  for (int i = 0; i < 4; i++) {
    fils[i].fs = i < 2 ? v : h.fs;
    fils[i].path = noms[i];
    fils[i].graine = 100u + (uint32_t)i;
    motif(fils[i].modele, ZONE, 900u + (uint32_t)i);
    fils[i].stop = &stop;
    fils[i].err = FL_OK;
    fils[i].tours = 0;
    TT_ASSERT_EQ(pthread_create(&th[i], NULL, travail, &fils[i]), 0);
  }
  sleep(10);
  atomic_store(&stop, 1);
  for (int i = 0; i < 4; i++) pthread_join(th[i], NULL);
  alarm(0);
  for (int i = 0; i < 4; i++) {
    fprintf(stderr, "  %s : %u tours\n", noms[i], fils[i].tours);
    TT_ASSERT_EQ(fils[i].err, FL_OK);
    TT_ASSERT(fils[i].tours > 0);
  }
  fermer(l, dec, v);
  demonter_hote(&h);
  TT_ASSERT_EQ(juger(h.img, FL_FMT_EXFAT, "hôte"), 0);

  /* tout est relu après un nouveau montage */
  TT_ASSERT_EQ(monter_hote(&h, false), FL_OK);
  TT_ASSERT_EQ(fl_fs_open(h.fs, "/coffre.luks", FL_O_RDONLY, &h.f), FL_OK);
  TT_ASSERT_EQ(fl_fsfile_bdev_new(h.f, 64 * MIB, true, &h.vd), FL_OK);
  TT_ASSERT_EQ(monter(h.vd, false, &l, &dec, &v), FL_OK);
  for (int i = 0; i < 4; i++) {
    int rc = lire_egal(i < 2 ? v : h.fs, noms[i], fils[i].modele, ZONE);
    if (rc != FL_OK) fprintf(stderr, "%s relu : %d\n", noms[i], rc);
    TT_ASSERT_EQ(rc, FL_OK);
  }
  fermer(l, dec, v);
  demonter_hote(&h);
  unlink(h.img);
}

/* Sur FAT32, un fichier ne dépasse pas 4 Gio − 1 octet : un coffre plus grand est refusé d'emblée. */
static void hostFat32Caps4GiB(void) {
  hote h;
  memset(&h, 0, sizeof h);
  TT_ASSERT_EQ(image(h.img, sizeof h.img, "hote-fat32.img", 64 * MIB), 0);
  TT_ASSERT_EQ(fl_file_bdev_open(h.img, 512, false, &h.dev), FL_OK);
  TT_ASSERT_EQ(mkfs(h.dev, FL_FMT_FAT32), FL_OK);
  fl_bdev_close(h.dev);
  h.dev = NULL;
  TT_ASSERT_EQ(monter_hote(&h, true), FL_OK);
  TT_ASSERT_EQ(fl_fs_open(h.fs, "/coffre.luks", FL_O_RDWR | FL_O_CREAT, &h.f), FL_OK);
  static uint8_t zeros[1024 * 1024];
  TT_ASSERT_EQ(fl_file_pwrite(h.f, zeros, sizeof zeros, 0), (int64_t)sizeof zeros);
  TT_ASSERT_EQ(fl_file_pwrite(h.f, zeros, 1, 4 * 1024 * MIB - 1), FL_EFBIG);
  TT_ASSERT_EQ(fl_file_truncate(h.f, 4 * 1024 * MIB), FL_EFBIG);
  fl_bdev *vd = (fl_bdev *)1;
  TT_ASSERT_EQ(fl_fsfile_bdev_new(h.f, 4 * 1024 * MIB, false, &vd), FL_EFBIG);
  TT_ASSERT(vd == NULL);
  /* au plus 4 Gio − 1 octet, en secteurs entiers : 4 Gio − 512, mais le fichier n'a qu'1 Mio */
  TT_ASSERT_EQ(fl_fsfile_bdev_new(h.f, 4 * 1024 * MIB - 512, false, &vd), FL_EINVAL);
  TT_ASSERT_EQ(fl_fsfile_bdev_new(h.f, MIB + 512, false, &vd), FL_EINVAL); /* plus grand que le fichier */
  TT_ASSERT_EQ(fl_fsfile_bdev_new(h.f, MIB - 1, false, &vd), FL_EINVAL);   /* pas en secteurs entiers */
  TT_ASSERT_EQ(fl_fsfile_bdev_new(h.f, MIB, false, &vd), FL_OK);
  TT_ASSERT_EQ(vd->sector_count, MIB / 512);
  h.vd = vd;
  demonter_hote(&h);
  unlink(h.img);
}

static int test_pass(const char *img, const char *contenu) {
  char cle[4200], td[4096], out[4096];
  if (fu_tmpdir(td, sizeof td) != 0) return -1;
  snprintf(cle, sizeof cle, "%s/coffre-cle.txt", td);
  FILE *f = fopen(cle, "wb");
  if (!f) return -1;
  fwrite(contenu, 1, strlen(contenu), f);
  fclose(f);
  char *argv[] = {"env", "LC_ALL=C", "cryptsetup", "open", "--test-passphrase", "--key-file", cle,
                  (char *)img, NULL};
  int rc = fu_run(argv, out, sizeof out);
  unlink(cle);
  return rc;
}

/* cryptsetup (sans root) lit le coffre : en-tête et mot de passe. */
static void cryptsetupOpensVault(void) {
  char out[1 << 14];
  char *v[] = {"cryptsetup", "--version", NULL};
  if (fu_run(v, out, sizeof out) != 0) {
    fprintf(stderr, "  cryptsetup absent : test sauté\n");
    return;
  }
  char img[4096];
  TT_ASSERT_EQ(image(img, sizeof img, "coffre-cryptsetup.luks", 40 * MIB), 0);
  fl_bdev *d = NULL;
  TT_ASSERT_EQ(fl_file_bdev_open(img, 512, false, &d), FL_OK);
  fl_fmt_opts o = opts(FL_FMT_EXFAT);
  TT_ASSERT_EQ(fl_format(d, &o, PASS, strlen(PASS), NULL, NULL), FL_OK);
  fl_bdev_close(d);
  char *dump[] = {"env", "LC_ALL=C", "cryptsetup", "luksDump", img, NULL};
  TT_ASSERT_EQ(fu_run(dump, out, sizeof out), 0);
  TT_ASSERT(strstr(out, "Version:       \t2") != NULL);
  TT_ASSERT(strstr(out, "  0: luks2") != NULL);
  TT_ASSERT_EQ(test_pass(img, PASS), 0);
  TT_ASSERT(test_pass(img, "faux mot de passe") != 0);
  unlink(img);
}

int main(void) {
  TT_RUN(vaultFormatHasNoTable);
  TT_RUN(vaultExfatAndExt4MountAndWrite);
  TT_RUN(fdBdevOwnsDescriptor);
  TT_RUN(vaultOnEngineFileRoundTrip);
  TT_RUN(vaultOnEngineFileNoDeadlock);
  TT_RUN(hostFat32Caps4GiB);
  TT_RUN(cryptsetupOpensVault);
  TT_MAIN_END();
}

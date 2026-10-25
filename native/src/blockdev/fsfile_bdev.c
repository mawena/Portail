/* Disque d'un coffre posé sur un fichier d'un volume du moteur (phase 14).
 *
 * Secteurs de 512 octets, lus et écrits par fl_file_pread / fl_file_pwrite du volume porteur ; le vidage
 * synchronise le porteur (fl_fs_sync : tampons des fichiers ouverts, caches, puis vidage de son disque).
 * Le fichier n'est pas possédé. Les appels arrivent ici depuis le système de fichiers du coffre, verrou
 * commun des systèmes de fichiers tenu (fs_internal.h) : il est récursif, l'appel au porteur le reprend. */
#include <stdlib.h>

#include "fluluks/blockdev.h"
#include "fluluks/error.h"
#include "fluluks/fs.h"
#include "fluluks/probe.h"
#include "fs/fs_internal.h"

#define SECTOR 512u
#define FAT_MAX_FILE 0xFFFFFFFFull /* 4 Gio − 1 octet */

typedef struct {
  fl_file *f;
} fsfile_priv;

static int fsfile_read(fl_bdev *d, uint64_t lba, uint32_t count, void *buf) {
  fsfile_priv *p = d->priv;
  size_t total = (size_t)count * SECTOR, done = 0;
  unsigned char *out = buf;
  while (done < total) {
    int64_t n = fl_file_pread(p->f, out + done, total - done, lba * SECTOR + done);
    if (n < 0) return (int)n;
    if (n == 0) return FL_EIO; /* fichier raccourci sous le coffre */
    done += (size_t)n;
  }
  return FL_OK;
}

static int fsfile_write(fl_bdev *d, uint64_t lba, uint32_t count, const void *buf) {
  fsfile_priv *p = d->priv;
  int64_t n = fl_file_pwrite(p->f, buf, (size_t)count * SECTOR, lba * SECTOR);
  return n < 0 ? (int)n : FL_OK; /* jamais de compte court (fs.h) */
}

static int fsfile_flush(fl_bdev *d) {
  fsfile_priv *p = d->priv;
  return d->read_only ? FL_OK : fl_fs_sync(p->f->fs);
}

static void fsfile_destroy(fl_bdev *d) {
  free(d->priv);
  free(d);
}

static const fl_bdev_ops fsfile_ops = {fsfile_read, fsfile_write, fsfile_flush, fsfile_destroy};

/* Vrai si le porteur est un FAT12/16/32 (fichiers de 4 Gio − 1 octet au plus). */
static bool host_is_fat(fl_fs *fs) {
  fl_probe_result r;
  if (fl_probe(fs->dev, &r) != FL_OK) return false;
  return r.content == FL_CONTENT_FAT12 || r.content == FL_CONTENT_FAT16 || r.content == FL_CONTENT_FAT32;
}

int fl_fsfile_bdev_new(fl_file *f, uint64_t size, bool read_only, fl_bdev **out) {
  if (out) *out = NULL;
  if (!f || !out || size == 0 || size % SECTOR) return FL_EINVAL;
  if (!read_only && (f->flags & FL_O_RDWR) == 0) return FL_EROFS;
  if (size > FAT_MAX_FILE && host_is_fat(f->fs)) return FL_EFBIG;
  /* le fichier couvre au moins `size` octets : son dernier secteur se lit en entier */
  unsigned char last[SECTOR];
  int64_t n = fl_file_pread(f, last, SECTOR, size - SECTOR);
  if (n < 0) return (int)n;
  if (n != SECTOR) return FL_EINVAL;
  fl_bdev *d = calloc(1, sizeof *d);
  fsfile_priv *p = calloc(1, sizeof *p);
  if (!d || !p) {
    free(d);
    free(p);
    return FL_ENOMEM;
  }
  p->f = f;
  d->ops = &fsfile_ops;
  d->sector_size = SECTOR;
  d->sector_count = size / SECTOR;
  d->read_only = read_only;
  d->priv = p;
  *out = d;
  return FL_OK;
}

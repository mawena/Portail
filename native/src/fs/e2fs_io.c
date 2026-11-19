/* io_manager d'e2fsprogs sur fl_bdev (phase 18) : remplace unix_io_manager pour e2fsck et resize2fs.
 * Le nom ouvert est ignoré : le canal parle au volume confié par fl_e2fs_io_bind (src/partops/e2fs.c),
 * sous le verrou d'e2fsprogs. Lectures et écritures en octets, ramenées aux secteurs du volume (lecture,
 * modification, écriture pour un bout de secteur). */

#define _GNU_SOURCE

#include "fs/e2fs_io.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>

#include "ext2fs/ext2_fs.h"
#include "ext2fs/ext2fs.h"
#include "fluluks/error.h"

static struct struct_io_manager fl_manager;
static fl_bdev *g_bound;
static int g_first_err; /* première erreur du volume (code FL_E…) depuis fl_e2fs_io_bind */

void fl_e2fs_io_bind(fl_bdev *vol) {
  g_bound = vol;
  g_first_err = FL_OK;
}

int fl_e2fs_io_error(void) { return g_first_err; }

typedef struct {
  fl_bdev *bd;
  int err; /* première erreur d'écriture (rendue aussi par flush) */
  struct struct_io_stats stats;
} chan;

static errcode_t to_errcode(int rc) {
  switch (rc) {
    case FL_OK: return 0;
    case FL_EROFS: return EROFS;
    case FL_ENOMEM: return ENOMEM;
    case FL_EINVAL: return EXT2_ET_LLSEEK_FAILED;
    case FL_ENODEV: return ENODEV;
    case FL_ETIMEDOUT: return ETIMEDOUT;
    default: return EXT2_ET_SHORT_READ;
  }
}

/* Octets [off, off + len) du volume ; hors du volume : refus (e2fsck signale alors un système de fichiers
 * plus grand que sa partition). */
static errcode_t rw_bytes(chan *c, uint64_t off, size_t len, void *buf, bool write) {
  fl_bdev *d = c->bd;
  uint32_t ss = d->sector_size;
  uint64_t size = fl_bdev_size_bytes(d);
  if (off > size || len > size - off) return write ? EXT2_ET_SHORT_WRITE : EXT2_ET_SHORT_READ;
  uint8_t *p = buf;
  uint8_t *tmp = NULL;
  int rc = FL_OK;
  while (len > 0 && rc == FL_OK) {
    uint64_t lba = off / ss;
    uint32_t in = (uint32_t)(off % ss);
    if (in == 0 && len >= ss) {
      uint64_t n = len / ss;
      if (n > 2048) n = 2048;
      rc = write ? fl_bdev_write(d, lba, (uint32_t)n, p) : fl_bdev_read(d, lba, (uint32_t)n, p);
      p += n * ss;
      off += n * ss;
      len -= (size_t)(n * ss);
      continue;
    }
    if (!tmp && !(tmp = malloc(ss))) return ENOMEM;
    size_t k = ss - in < len ? ss - in : len;
    rc = fl_bdev_read(d, lba, 1, tmp);
    if (rc == FL_OK) {
      if (write) {
        memcpy(tmp + in, p, k);
        rc = fl_bdev_write(d, lba, 1, tmp);
      } else {
        memcpy(p, tmp + in, k);
      }
    }
    p += k;
    off += k;
    len -= k;
  }
  free(tmp);
  if (rc != FL_OK && g_first_err == FL_OK) g_first_err = rc;
  return to_errcode(rc);
}

static errcode_t blk_rw(io_channel ch, unsigned long long block, int count, void *data, bool write) {
  chan *c = ch->private_data;
  size_t len = count < 0 ? (size_t)(-count) : (size_t)count * (size_t)ch->block_size;
  uint64_t off = block * (uint64_t)ch->block_size;
  errcode_t e = rw_bytes(c, off, len, data, write);
  if (write) {
    c->stats.bytes_written += len;
    if (e && !c->err) c->err = (int)e;
    if (e && ch->write_error) return ch->write_error(ch, (unsigned long)block, count, data, len, 0, e);
  } else {
    c->stats.bytes_read += len;
    if (e && ch->read_error) return ch->read_error(ch, (unsigned long)block, count, data, len, 0, e);
  }
  return e;
}

static errcode_t fl_open(const char *name, int flags, io_channel *out) {
  if (!g_bound) return EXT2_ET_BAD_DEVICE_NAME;
  if ((flags & IO_FLAG_RW) && g_bound->read_only) return EROFS;
  io_channel ch = calloc(1, sizeof *ch);
  chan *c = calloc(1, sizeof *c);
  char *nm = strdup(name ? name : "fl");
  if (!ch || !c || !nm) {
    free(ch);
    free(c);
    free(nm);
    return ENOMEM;
  }
  c->bd = g_bound;
  c->stats.num_fields = 2;
  ch->magic = EXT2_ET_MAGIC_IO_CHANNEL;
  ch->manager = &fl_manager;
  ch->name = nm;
  ch->block_size = 1024;
  ch->refcount = 1;
  ch->private_data = c;
  *out = ch;
  return 0;
}

static errcode_t fl_close(io_channel ch) {
  if (--ch->refcount > 0) return 0;
  chan *c = ch->private_data;
  errcode_t e = c->err ? (errcode_t)c->err : to_errcode(c->bd->read_only ? FL_OK : fl_bdev_flush(c->bd));
  free(c);
  free(ch->name);
  free(ch);
  return e;
}

static errcode_t fl_set_blksize(io_channel ch, int blksize) {
  ch->block_size = blksize;
  return 0;
}

static errcode_t fl_read_blk64(io_channel ch, unsigned long long block, int count, void *data) {
  return blk_rw(ch, block, count, data, false);
}

static errcode_t fl_write_blk64(io_channel ch, unsigned long long block, int count, const void *data) {
  return blk_rw(ch, block, count, (void *)data, true);
}

static errcode_t fl_read_blk(io_channel ch, unsigned long block, int count, void *data) {
  return fl_read_blk64(ch, block, count, data);
}

static errcode_t fl_write_blk(io_channel ch, unsigned long block, int count, const void *data) {
  return fl_write_blk64(ch, block, count, data);
}

static errcode_t fl_write_byte(io_channel ch, unsigned long offset, int size, const void *data) {
  chan *c = ch->private_data;
  if (size < 0) return EXT2_ET_INVALID_ARGUMENT;
  errcode_t e = rw_bytes(c, offset, (size_t)size, (void *)data, true);
  if (e && !c->err) c->err = (int)e;
  return e;
}

static errcode_t fl_flush(io_channel ch) {
  chan *c = ch->private_data;
  if (c->err) return (errcode_t)c->err;
  return c->bd->read_only ? 0 : to_errcode(fl_bdev_flush(c->bd));
}

static errcode_t fl_set_option(io_channel ch, const char *option, const char *arg) {
  (void)ch;
  (void)option;
  (void)arg;
  return EXT2_ET_INVALID_ARGUMENT;
}

static errcode_t fl_get_stats(io_channel ch, io_stats *st) {
  chan *c = ch->private_data;
  *st = &c->stats;
  return 0;
}

/* Zéros écrits par blocs de 64 Kio (resize2fs : tables d'inodes des nouveaux groupes). */
static errcode_t fl_zeroout(io_channel ch, unsigned long long block, unsigned long long count) {
  static const uint8_t zero[64 * 1024];
  chan *c = ch->private_data;
  uint64_t off = block * (uint64_t)ch->block_size, len = count * (uint64_t)ch->block_size;
  while (len > 0) {
    size_t k = len < sizeof zero ? (size_t)len : sizeof zero;
    errcode_t e = rw_bytes(c, off, k, (void *)zero, true);
    if (e) {
      if (!c->err) c->err = (int)e;
      return e;
    }
    off += k;
    len -= k;
  }
  return 0;
}

static struct struct_io_manager fl_manager = {
    .magic = EXT2_ET_MAGIC_IO_MANAGER,
    .name = "Portail I/O Manager",
    .open = fl_open,
    .close = fl_close,
    .set_blksize = fl_set_blksize,
    .read_blk = fl_read_blk,
    .write_blk = fl_write_blk,
    .flush = fl_flush,
    .write_byte = fl_write_byte,
    .set_option = fl_set_option,
    .get_stats = fl_get_stats,
    .read_blk64 = fl_read_blk64,
    .write_blk64 = fl_write_blk64,
    .zeroout = fl_zeroout,
};

io_manager fl_e2fs_bdev_manager(void) { return &fl_manager; }

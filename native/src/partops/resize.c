/* Agrandir ou réduire une partition et son système de fichiers (phase 18) : ext4 (resize2fs) et NTFS
 * (ntfsresize), en clair ou dans LUKS1/LUKS2. Le début de la partition ne bouge jamais. Ordre des écritures :
 * agrandir = table, puis segment LUKS de taille fixe, puis système de fichiers ; réduire = système de
 * fichiers, puis segment LUKS, puis table. Une coupure entre deux étapes laisse donc toujours un système de
 * fichiers qui tient dans sa partition. Vérification en lecture seule exigée avant (e2fsck -fn, ntfsfix -n). */

#include <stdlib.h>
#include <string.h>

#include "fluluks/error.h"
#include "fluluks/luks.h"
#include "fluluks/partedit.h"
#include "fluluks/partops.h"
#include "fluluks/probe.h"

#define MIB (1024ull * 1024ull)

static const char WHY_FAT[] =
    "FAT32 et exFAT ne se redimensionnent pas ici : copiez les fichiers ailleurs, puis recréez la partition";
static const char WHY_OTHER[] = "Seuls ext4 et NTFS se redimensionnent, en clair ou chiffrés";
static const char WHY_LOGICAL[] = "Une partition logique (MBR étendu) ne se redimensionne pas ici";

typedef struct {
  fl_pt_layout *l;
  int i;              /* position de la partition dans l->e */
  fl_bdev *part;      /* la partition */
  fl_luks *lk;        /* LUKS ouvert, ou NULL */
  fl_bdev *vol;       /* système de fichiers : la partition ou le volume déchiffré */
  uint64_t luks_off;  /* début des données chiffrées dans la partition (0 en clair) */
  uint64_t luks_fixed;/* segment LUKS2 de taille fixe (0 sinon) */
  fl_content content; /* du système de fichiers */
} target;

static void close_vol(target *t) {
  fl_bdev_close(t->vol == t->part ? NULL : t->vol);
  fl_luks_close(t->lk);
  fl_bdev_close(t->part);
  t->vol = t->part = NULL;
  t->lk = NULL;
}

static void release(target *t) {
  close_vol(t);
  free(t->l);
  t->l = NULL;
}

/* Ouvre la partition (et LUKS) à sa taille actuelle dans la table. */
static int open_vol(fl_bdev *disk, target *t, const void *pass, size_t passlen) {
  const fl_pt_entry *p = &t->l->e[t->i];
  int rc = fl_slice_bdev_new(disk, p->first_lba, p->sector_count, &t->part);
  if (rc != FL_OK) return rc;
  fl_probe_result pr;
  rc = fl_probe(t->part, &pr);
  if (rc != FL_OK) return rc;
  t->vol = t->part;
  t->luks_off = t->luks_fixed = 0;
  t->content = pr.content;
  if (pr.content == FL_CONTENT_LUKS1 || pr.content == FL_CONTENT_LUKS2) {
    rc = fl_luks_payload(t->part, &t->luks_off, &t->luks_fixed);
    if (rc == FL_OK) rc = pass ? fl_luks_open(t->part, &t->lk) : FL_EBADPASS;
    if (rc == FL_OK) rc = fl_luks_unlock(t->lk, pass, passlen, &t->vol);
    if (rc != FL_OK) {
      t->vol = NULL;
      return rc;
    }
    rc = fl_probe(t->vol, &pr);
    if (rc != FL_OK) return rc;
    t->content = pr.content;
  }
  return FL_OK;
}

static int load(fl_bdev *disk, uint32_t index, uint64_t expect_first_lba, target *t) {
  memset(t, 0, sizeof *t);
  t->l = calloc(1, sizeof *t->l);
  if (!t->l) return FL_ENOMEM;
  int rc = fl_pt_load(disk, t->l);
  if (rc != FL_OK) return rc;
  t->i = -1;
  for (uint32_t k = 0; k < t->l->count; k++)
    if (t->l->e[k].index == index) t->i = (int)k;
  if (t->i < 0 || t->l->e[t->i].first_lba != expect_first_lba) return FL_ECHANGED;
  return FL_OK;
}

/* Dernier secteur (exclu) que la partition peut atteindre : début de la partition suivante, ou fin de la
 * zone utilisable. */
static uint64_t limit_end(const fl_pt_layout *l, int i) {
  const fl_pt_entry *p = &l->e[i];
  uint64_t end = l->last_usable + 1;
  for (uint32_t k = 0; k < l->count; k++)
    if ((int)k != i && l->e[k].first_lba >= p->first_lba + p->sector_count && l->e[k].first_lba < end)
      end = l->e[k].first_lba;
  return end;
}

static int info_of(fl_bdev *disk, target *t, fl_resize_info *out) {
  const fl_pt_entry *p = &t->l->e[t->i];
  uint32_t ss = disk->sector_size;
  uint64_t cur = p->sector_count * ss;
  out->content = t->content;
  if (p->logical || t->l->has_extended) {
    out->why = WHY_LOGICAL;
    return FL_OK;
  }
  int rc;
  uint64_t fs_min = 0;
  switch (t->content) {
    case FL_CONTENT_EXT4:
      rc = fl_e2fs_check(t->vol, &out->check);
      if (rc == FL_OK && out->check.clean) rc = fl_e2fs_min_size(t->vol, &fs_min);
      break;
    case FL_CONTENT_NTFS:
      rc = fl_ntfs_check(t->vol, &out->check);
      if (rc == FL_OK && out->check.clean) rc = fl_ntfs_min_size(t->vol, &fs_min);
      break;
    case FL_CONTENT_FAT12:
    case FL_CONTENT_FAT16:
    case FL_CONTENT_FAT32:
    case FL_CONTENT_EXFAT: out->why = WHY_FAT; return FL_OK;
    default: out->why = WHY_OTHER; return FL_OK;
  }
  if (rc == FL_ECORRUPT) { /* illisible : le rapport le dit, rien n'est proposé */
    out->check.clean = false;
    rc = FL_OK;
  }
  if (rc != FL_OK) return rc;
  out->resizable = true;
  uint64_t m = MIB / ss;
  uint64_t end = limit_end(t->l, t->i);
  uint64_t max_count = (end - p->first_lba) / m * m;
  if (max_count < p->sector_count) max_count = p->sector_count;
  out->max_bytes = max_count * ss;
  if (!out->check.clean) {
    out->min_bytes = cur;
    return FL_OK;
  }
  uint64_t need = fs_min + t->luks_off;
  uint64_t min = (need + MIB - 1) / MIB * MIB;
  out->min_bytes = min < cur ? min : cur;
  return FL_OK;
}

int fl_part_resize_info(fl_bdev *disk, uint32_t index, uint64_t expect_first_lba, const void *pass, size_t passlen,
                        fl_resize_info *out) {
  if (!disk || !out || disk->sector_size < 512 || disk->sector_size > MIB) return FL_EINVAL;
  memset(out, 0, sizeof *out);
  target t;
  int rc = load(disk, index, expect_first_lba, &t);
  if (rc == FL_OK) rc = open_vol(disk, &t, pass, passlen);
  if (rc == FL_OK) rc = info_of(disk, &t, out);
  release(&t);
  return rc;
}

/* Système de fichiers de `t->vol` porté à `bytes`. */
static int resize_fs(target *t, uint64_t bytes, fl_progress_fn cb, void *arg) {
  if (t->content == FL_CONTENT_EXT4) return fl_e2fs_resize(t->vol, bytes, cb, arg);
  return fl_ntfs_resize(t->vol, bytes, cb, arg);
}

typedef struct {
  fl_progress_fn cb;
  void *arg;
  int from, span;
} sub_progress;

static void sub_cb(int pct, void *arg) {
  sub_progress *s = arg;
  if (s->cb) s->cb(s->from + pct * s->span / 100, s->arg);
}

int fl_part_resize(fl_bdev *disk, uint32_t index, uint64_t expect_first_lba, uint64_t new_count, const void *pass,
                   size_t passlen, fl_progress_fn cb, void *arg) {
  if (!disk || disk->sector_size < 512 || disk->sector_size > MIB) return FL_EINVAL;
  uint32_t ss = disk->sector_size;
  target t;
  fl_resize_info info;
  memset(&info, 0, sizeof info);
  int rc = load(disk, index, expect_first_lba, &t);
  if (rc == FL_OK) rc = open_vol(disk, &t, pass, passlen);
  if (rc == FL_OK) rc = info_of(disk, &t, &info);
  if (rc == FL_OK && !info.resizable) rc = FL_ENOTSUP;
  if (rc == FL_OK && !info.check.clean) rc = FL_ECORRUPT;
  uint64_t new_bytes = new_count * ss;
  if (rc == FL_OK && (new_count % (MIB / ss) != 0 || new_bytes < info.min_bytes || new_bytes > info.max_bytes))
    rc = FL_EINVAL;
  if (rc != FL_OK) {
    release(&t);
    return rc;
  }
  fl_pt_entry *p = &t.l->e[t.i];
  uint64_t old_count = p->sector_count;
  if (new_count == old_count) {
    release(&t);
    return FL_OK;
  }
  uint64_t inner = new_bytes - t.luks_off; /* taille du système de fichiers */
  sub_progress sp = {cb, arg, 10, 80};
  if (cb) cb(0, arg);
  if (new_count > old_count) {
    /* agrandir : table, segment LUKS fixe, système de fichiers */
    close_vol(&t);
    p->sector_count = new_count;
    rc = fl_pt_validate(t.l);
    if (rc == FL_OK) rc = fl_pt_store(disk, t.l);
    if (rc == FL_OK) {
      rc = fl_slice_bdev_new(disk, p->first_lba, new_count, &t.part);
      if (rc == FL_OK && t.luks_fixed) rc = fl_luks2_set_segment_size(t.part, inner);
      fl_bdev_close(t.part);
      t.part = NULL;
    }
    if (cb && rc == FL_OK) cb(10, arg);
    if (rc == FL_OK) rc = open_vol(disk, &t, pass, passlen);
    if (rc == FL_OK) rc = resize_fs(&t, inner, sub_cb, &sp);
  } else {
    /* réduire : système de fichiers, segment LUKS fixe, table */
    rc = resize_fs(&t, inner, sub_cb, &sp);
    close_vol(&t);
    if (rc == FL_OK && t.luks_fixed) {
      rc = fl_slice_bdev_new(disk, p->first_lba, old_count, &t.part);
      if (rc == FL_OK) rc = fl_luks2_set_segment_size(t.part, inner);
      fl_bdev_close(t.part);
      t.part = NULL;
    }
    if (rc == FL_OK) {
      p->sector_count = new_count;
      rc = fl_pt_validate(t.l);
      if (rc == FL_OK) rc = fl_pt_store(disk, t.l);
    }
  }
  if (rc == FL_OK) rc = fl_bdev_flush(disk);
  if (rc == FL_OK && cb) cb(100, arg);
  release(&t);
  return rc;
}

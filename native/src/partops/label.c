/* Étiquette d'une partition (phase 18) : FAT12/16/32 et exFAT par FatFs (et BS_VolLab en FAT), ext4 par
 * e2fsprogs, NTFS par ntfs-3g ; dans un volume LUKS, l'étiquette du système de fichiers intérieur. Le nom
 * de partition GPT n'est pas modifié. Permise aussi sur une partition logique (MBR étendu). */

#include <stdlib.h>
#include <string.h>

#include "fluluks/error.h"
#include "fluluks/fs.h"
#include "fluluks/luks.h"
#include "fluluks/partedit.h"
#include "fluluks/partops.h"
#include "fluluks/probe.h"
#include "format/format_internal.h"
#include "fs/fs_internal.h"

static int fmt_of(fl_content c, fl_fmt_fs *out) {
  switch (c) {
    case FL_CONTENT_FAT12:
    case FL_CONTENT_FAT16:
    case FL_CONTENT_FAT32: *out = FL_FMT_FAT32; return FL_OK;
    case FL_CONTENT_EXFAT: *out = FL_FMT_EXFAT; return FL_OK;
    case FL_CONTENT_EXT4: *out = FL_FMT_EXT4; return FL_OK;
    case FL_CONTENT_NTFS: *out = FL_FMT_NTFS; return FL_OK;
    default: return FL_ENOTSUP;
  }
}

/* Étiquette du système de fichiers de `v` (partition en clair ou volume déchiffré). */
static int set_on(fl_bdev *v, const char *label) {
  fl_probe_result pr;
  int rc = fl_probe(v, &pr);
  if (rc != FL_OK) return rc;
  fl_fmt_fs f;
  rc = fmt_of(pr.content, &f);
  if (rc != FL_OK) return rc;
  if (fl_fmt_check_label(f, label) != FL_OK) return FL_EINVAL;
  switch (f) {
    case FL_FMT_EXT4: return fl_e2fs_set_label(v, label);
    case FL_FMT_NTFS: return fl_ntfs_set_label(v, label);
    default: break;
  }
  fl_fs *fs = NULL;
  rc = fl_fs_mount(v, pr.content, true, &fs);
  if (rc != FL_OK) return rc;
  rc = fl_fat_set_label(fs, label);
  int u = fl_fs_unmount(fs);
  return rc != FL_OK ? rc : u;
}

int fl_part_set_label(fl_bdev *disk, uint32_t index, uint64_t expect_first_lba, const char *label, const void *pass,
                      size_t passlen) {
  if (!disk || !label) return FL_EINVAL;
  fl_pt_layout *l = calloc(1, sizeof *l);
  if (!l) return FL_ENOMEM;
  int rc = fl_pt_load(disk, l);
  const fl_pt_entry *p = NULL;
  for (uint32_t i = 0; rc == FL_OK && i < l->count; i++)
    if (l->e[i].index == index) p = &l->e[i];
  if (rc == FL_OK && (!p || p->first_lba != expect_first_lba)) rc = FL_ECHANGED;
  fl_bdev *s = NULL;
  if (rc == FL_OK) rc = fl_slice_bdev_new(disk, p->first_lba, p->sector_count, &s);
  free(l);
  if (rc != FL_OK) return rc;

  fl_probe_result pr;
  rc = fl_probe(s, &pr);
  if (rc == FL_OK && (pr.content == FL_CONTENT_LUKS1 || pr.content == FL_CONTENT_LUKS2)) {
    fl_luks *lk = NULL;
    fl_bdev *inner = NULL;
    rc = pass ? fl_luks_open(s, &lk) : FL_EBADPASS;
    if (rc == FL_OK) rc = fl_luks_unlock(lk, pass, passlen, &inner);
    if (rc == FL_OK) rc = set_on(inner, label);
    fl_bdev_close(inner);
    fl_luks_close(lk);
  } else if (rc == FL_OK) {
    rc = set_on(s, label);
  }
  fl_bdev_close(s);
  return rc;
}

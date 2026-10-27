/* Formatage complet d'un disque (phase 8) : vérifications, puis table, LUKS2 éventuel, système de fichiers.
 *
 * Rien n'est écrit avant que tout soit vérifié : options, étiquette, phrase de passe, et taille de la
 * future partition (calculée par fl_part_layout) face au minimum du système de fichiers (plus 16 Mio
 * d'en-tête LUKS2). Les premier et dernier Mio du disque (fl_part_write_single), puis de la partition, sont
 * effacés : anciens GPT, LUKS, superblocs btrfs, étiquettes ZFS. La phrase de passe n'est pas copiée ; la
 * clé maîtresse reste dans le volume déchiffré (mémoire sécurisée) jusqu'à sa fermeture ici.
 *
 * Sans table (no_table, coffres de la phase 14) : LUKS2 ou système de fichiers sur tout le disque, seul le
 * Mio de tête est effacé. */
#include "fluluks/error.h"
#include "fluluks/format.h"
#include "format/format_internal.h"

#define MIB (1024ull * 1024ull)
#define LUKS_HDR (16 * MIB)

/* Taille minimale du système de fichiers sur un volume à secteurs de `ss` octets. FAT32 : FatFs exige
 * 65 525 clusters ; au plus petit (un secteur par cluster) : données, deux FAT, réservés, alignement. */
static uint64_t min_fs(fl_fmt_fs fs, uint32_t ss) {
  if (fs == FL_FMT_FAT32) {
    uint64_t clusters = 65525 + 2;
    uint64_t fat = (clusters * 4 + ss - 1) / ss * ss;
    return clusters * ss + 2 * fat + 32ull * ss + 2 * MIB;
  }
  return 8 * MIB; /* exFAT, ext4 (journal), NTFS ($LogFile) */
}

static void report(void (*progress)(int, void *), void *arg, int pct) {
  if (progress) progress(pct, arg);
}

uint64_t fl_fmt_min_bytes(fl_fmt_fs fs, uint32_t ss, bool encrypted) {
  return min_fs(fs, ss) + (encrypted ? LUKS_HDR : 0);
}

int fl_fmt_check(const fl_bdev *disk, const fl_fmt_opts *o, const void *pass, size_t passlen, uint64_t count) {
  if (!disk || !o || o->fs < FL_FMT_FAT32 || o->fs > FL_FMT_NTFS) return FL_EINVAL;
  if (disk->read_only) return FL_EROFS;
  int rc = fl_fmt_check_label(o->fs, o->label);
  if (rc != FL_OK) return rc;
  if (o->encrypted && (!pass || passlen == 0 || o->kdf_mem_kib < 8192)) return FL_EINVAL;
  if (count * disk->sector_size < fl_fmt_min_bytes(o->fs, disk->sector_size, o->encrypted)) return FL_ENOSPC;
  /* FatFs : FAT32 sous 2^32 secteurs (2 Tio en secteurs de 512 octets) ; les secteurs chiffrés sont ceux du disque */
  uint64_t vol_sectors = count - (o->encrypted ? LUKS_HDR / disk->sector_size : 0);
  if (o->fs == FL_FMT_FAT32 && vol_sectors >= (1ull << 32)) return FL_EFBIG;
  return FL_OK;
}

int fl_fmt_slice(fl_bdev *disk, uint64_t first, uint64_t count, const fl_fmt_opts *o, bool wipe_end,
                 uint64_t hidden_sectors, const void *pass, size_t passlen, void (*progress)(int pct, void *arg),
                 void *arg) {
  fl_bdev *part = NULL, *vol = NULL;
  int rc = fl_slice_bdev_new(disk, first, count, &part);
  if (rc != FL_OK) return rc;
  uint64_t align = MIB / disk->sector_size;
  /* anciennes signatures du début ; sans table, la fin (GPT de secours d'un disque) n'est pas touchée */
  rc = fl_fmt_zero(part, 0, align);
  if (rc == FL_OK && wipe_end) rc = fl_fmt_zero(part, count - align, align);
  report(progress, arg, 10);

  if (rc == FL_OK && o->encrypted) {
    rc = fl_luks2_format(part, pass, passlen, o->kdf_mem_kib, &vol);
    report(progress, arg, 60);
  } else {
    vol = part;
  }
  if (rc == FL_OK) {
    switch (o->fs) {
      case FL_FMT_FAT32: rc = fl_mkfs_fat(vol, false, o->label); break;
      case FL_FMT_EXFAT: rc = fl_mkfs_fat(vol, true, o->label); break;
      case FL_FMT_EXT4: rc = fl_mkfs_ext4(vol, o->label, o->root_uid, o->root_gid); break;
      case FL_FMT_NTFS: rc = fl_mkfs_ntfs(vol, o->label, o->encrypted ? 0 : hidden_sectors); break;
    }
    report(progress, arg, 95);
  }
  if (vol && vol != part) fl_bdev_close(vol);
  fl_bdev_close(part);
  if (rc == FL_OK) rc = fl_bdev_flush(disk);
  return rc;
}

int fl_format(fl_bdev *disk, const fl_fmt_opts *o, const void *pass, size_t passlen,
              void (*progress)(int pct, void *arg), void *arg) {
  if (!disk || !o) return FL_EINVAL;
  uint64_t first = 0, count = disk->sector_count;
  bool gpt = false;
  int rc;
  if (!o->no_table) {
    rc = fl_part_layout(disk, &first, &count, &gpt);
    if (rc != FL_OK) return rc;
    uint64_t align = MIB / disk->sector_size, want = o->part_bytes / disk->sector_size / align * align;
    if (o->part_bytes && want < count) count = want; /* taille choisie : le reste du disque reste libre */
  }
  rc = fl_fmt_check(disk, o, pass, passlen, count);
  if (rc != FL_OK) return rc;
  report(progress, arg, 0);
  if (!o->no_table) {
    rc = fl_part_write_one(disk, o->fs, o->encrypted, first, count, gpt);
    if (rc != FL_OK) return rc;
  }
  rc = fl_fmt_slice(disk, first, count, o, !o->no_table, first, pass, passlen, progress, arg);
  if (rc == FL_OK) report(progress, arg, 100);
  return rc;
}

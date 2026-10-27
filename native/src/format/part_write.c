#include <stdlib.h>
#include <string.h>

#include "fluluks/error.h"
#include "fluluks/format.h"
#include "format/format_internal.h"
#include "fluluks/partedit.h"
#include "part/part_internal.h"

#define MIB (1024u * 1024u)
#define GPT_ENTRIES 128u
#define GPT_ENTRY_SIZE 128u

/* Types GPT, en octets sur le disque (trois premiers champs en petit-boutiste). */
static const uint8_t TYPE_LINUX[16] = {0xAF, 0x3D, 0xC6, 0x0F, 0x83, 0x84, 0x72, 0x47,
                                       0x8E, 0x79, 0x3D, 0x69, 0xD8, 0x47, 0x7D, 0xE4}; /* 0FC63DAF-… */
static const uint8_t TYPE_MSDATA[16] = {0xA2, 0xA0, 0xD0, 0xEB, 0xE5, 0xB9, 0x33, 0x44,
                                        0x87, 0xC0, 0x68, 0xB6, 0xB7, 0x26, 0x99, 0xC7}; /* EBD0A0A2-… */

int fl_fmt_zero(fl_bdev *d, uint64_t lba, uint64_t n) {
  uint32_t per = MIB / d->sector_size;
  uint8_t *z = calloc(per, d->sector_size);
  if (!z) return FL_ENOMEM;
  int rc = FL_OK;
  while (n > 0 && rc == FL_OK) {
    uint32_t k = n < per ? (uint32_t)n : per;
    rc = fl_bdev_write(d, lba, k, z);
    lba += k;
    n -= k;
  }
  free(z);
  return rc;
}

static uint8_t mbr_type(fl_fmt_fs fs, bool encrypted) {
  if (encrypted || fs == FL_FMT_EXT4) return 0x83;
  return fs == FL_FMT_FAT32 ? 0x0C : 0x07;
}

int fl_part_layout(const fl_bdev *d, uint64_t *first_lba, uint64_t *count, bool *gpt_out) {
  if (!d || d->sector_size < 512 || d->sector_size > MIB) return FL_EINVAL;
  uint64_t align = MIB / d->sector_size;
  uint64_t total = d->sector_count;
  if (total < 4 * align) return FL_ENOSPC;
  bool gpt = total * d->sector_size > 2ull * 1024 * 1024 * MIB;
  uint64_t esec = (GPT_ENTRIES * GPT_ENTRY_SIZE + d->sector_size - 1) / d->sector_size;
  uint64_t end = gpt ? total - 1 - esec : total; /* premier secteur hors partition possible */
  uint64_t n = (end - align) / align * align;
  if (!gpt && n > 0xFFFFFFFFull) return FL_EINVAL; /* MBR : 2^32 secteurs au plus */
  *first_lba = align;
  *count = n;
  *gpt_out = gpt;
  return FL_OK;
}

void fl_fmt_part_type(fl_fmt_fs fs, bool encrypted, uint8_t *mbr, uint8_t gpt[16]) {
  *mbr = mbr_type(fs, encrypted);
  memcpy(gpt, (encrypted || fs == FL_FMT_EXT4) ? TYPE_LINUX : TYPE_MSDATA, 16);
}

int fl_part_write_one(fl_bdev *d, fl_fmt_fs fs, bool encrypted, uint64_t first, uint64_t count, bool gpt) {
  /* nouvelle table (premier et dernier Mio effacés), puis sa partition unique */
  int rc = fl_pt_new_table(d, gpt ? FL_PT_GPT : FL_PT_MBR);
  fl_pt_layout *l = rc == FL_OK ? calloc(1, sizeof *l) : NULL;
  if (rc == FL_OK && !l) rc = FL_ENOMEM;
  if (rc == FL_OK) rc = fl_pt_load(d, l);
  if (rc == FL_OK) {
    fl_pt_entry *p = &l->e[l->count++];
    memset(p, 0, sizeof *p);
    p->index = 1;
    p->first_lba = first;
    p->sector_count = count;
    uint8_t mt, gt[16];
    fl_fmt_part_type(fs, encrypted, &mt, gt);
    if (gpt) memcpy(p->gpt_type, gt, 16);
    else p->mbr_type = mt;
    rc = fl_pt_store(d, l);
  }
  free(l);
  return rc;
}

int fl_part_write_single(fl_bdev *d, fl_fmt_fs fs, bool encrypted, uint64_t *first_lba, uint64_t *count) {
  if (!d || !first_lba || !count) return FL_EINVAL;
  if (fs < FL_FMT_FAT32 || fs > FL_FMT_NTFS) return FL_EINVAL;
  if (d->read_only) return FL_EROFS;
  uint64_t first, n;
  bool gpt;
  int rc = fl_part_layout(d, &first, &n, &gpt);
  if (rc == FL_OK) rc = fl_part_write_one(d, fs, encrypted, first, n, gpt);
  if (rc != FL_OK) return rc;
  *first_lba = first;
  *count = n;
  return FL_OK;
}

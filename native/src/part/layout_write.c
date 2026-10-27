/* Écriture d'une table de partitions modifiable (phase 17).
 *
 * GPT : copie de secours d'abord (entrées, puis en-tête), puis copie principale (entrées, MBR protecteur,
 * en-tête en dernier), puis vidage. Une coupure entre deux écritures laisse toujours une copie valide :
 * l'ancienne principale jusqu'à ce que ses entrées soient remplacées, puis la nouvelle de secours. La fin
 * utilisable suit la taille du disque (un disque cloné sur plus grand retrouve sa place).
 * MBR : un seul secteur ; le code d'amorçage, la signature et les octets des entrées inchangées sont
 * gardés, une entrée nouvelle ou changée est écrite en adressage LBA (CHS hors limites). */
#include <stdlib.h>
#include <string.h>

#include "fluluks/error.h"
#include "fluluks/format.h"
#include "fluluks/partedit.h"
#include "format/format_internal.h"
#include "part/crc32.h"
#include "part/part_internal.h"

#define MIB (1024ull * 1024ull)

static uint32_t rd32(const uint8_t *p) {
  return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}
static void le32(uint8_t *p, uint32_t v) { for (int i = 0; i < 4; i++) p[i] = (uint8_t)(v >> (8 * i)); }
static void le64(uint8_t *p, uint64_t v) { for (int i = 0; i < 8; i++) p[i] = (uint8_t)(v >> (8 * i)); }

int fl_pt_random_guid(uint8_t g[16]) {
  int rc = fl_random(g, 16);
  if (rc != FL_OK) return rc;
  g[7] = (uint8_t)((g[7] & 0x0F) | 0x40); /* version 4 */
  g[8] = (uint8_t)((g[8] & 0x3F) | 0x80); /* variante RFC 4122 */
  return FL_OK;
}

static void gpt_header(uint8_t *s, uint64_t self, uint64_t alt, uint64_t first_usable, uint64_t last_usable,
                       const uint8_t guid[16], uint64_t entries_lba, uint32_t entries_crc) {
  memcpy(s, "EFI PART", 8);
  le32(s + 8, 0x00010000);
  le32(s + 12, 92);
  le64(s + 24, self);
  le64(s + 32, alt);
  le64(s + 40, first_usable);
  le64(s + 48, last_usable);
  memcpy(s + 56, guid, 16);
  le64(s + 72, entries_lba);
  le32(s + 80, 128);
  le32(s + 84, 128);
  le32(s + 88, entries_crc);
  le32(s + 16, fl_crc32(s, 92));
}

/* MBR protecteur : gardé s'il est déjà là (seule sa taille suit le disque), sinon écrit à neuf. */
static void protective(uint8_t *s0, uint64_t total) {
  uint32_t size = total - 1 > 0xFFFFFFFFull ? 0xFFFFFFFFu : (uint32_t)(total - 1);
  int found = -1;
  for (int i = 0; i < 4; i++)
    if (s0[446 + 16 * i + 4] == 0xEE) found = i;
  if (found < 0 || s0[510] != 0x55 || s0[511] != 0xAA) {
    memset(s0 + 440, 0, 72);
    uint8_t *e = s0 + 446;
    e[1] = 0x00; e[2] = 0x02; e[3] = 0x00;
    e[4] = 0xEE;
    e[5] = 0xFF; e[6] = 0xFF; e[7] = 0xFF;
    le32(e + 8, 1);
    found = 0;
    s0[510] = 0x55;
    s0[511] = 0xAA;
  }
  le32(s0 + 446 + 16 * found + 12, size);
}

static int store_gpt(fl_bdev *d, const fl_pt_layout *l) {
  uint32_t ss = d->sector_size;
  uint64_t total = d->sector_count, esec = fl_pt_gpt_entry_sectors(ss);
  uint64_t last_usable = total - 2 - esec;
  uint8_t *ent = calloc(esec, ss), *h = calloc(1, ss), *s0 = malloc(ss), *s0new = malloc(ss);
  int rc = ent && h && s0 && s0new ? FL_OK : FL_ENOMEM;
  static const uint8_t zero[16];
  for (uint32_t i = 0; rc == FL_OK && i < l->count; i++) {
    const fl_pt_entry *p = &l->e[i];
    uint8_t *x = ent + 128 * (p->index - 1);
    memcpy(x, p->gpt_type, 16);
    if (memcmp(p->gpt_guid, zero, 16) == 0) rc = fl_pt_random_guid(x + 16);
    else memcpy(x + 16, p->gpt_guid, 16);
    le64(x + 32, p->first_lba);
    le64(x + 40, p->first_lba + p->sector_count - 1);
    le64(x + 48, p->gpt_attrs);
    memcpy(x + 56, p->name_raw, 72);
  }
  uint32_t ecrc = rc == FL_OK ? fl_crc32(ent, 128 * 128) : 0;
  if (rc == FL_OK) rc = fl_bdev_read(d, 0, 1, s0);
  if (rc == FL_OK) {
    memcpy(s0new, s0, ss);
    protective(s0new, total);
    rc = fl_bdev_write(d, total - 1 - esec, (uint32_t)esec, ent);
  }
  if (rc == FL_OK) {
    gpt_header(h, total - 1, 1, l->first_usable, last_usable, l->disk_guid, total - 1 - esec, ecrc);
    rc = fl_bdev_write(d, total - 1, 1, h);
  }
  if (rc == FL_OK) rc = fl_bdev_write(d, 2, (uint32_t)esec, ent);
  if (rc == FL_OK && memcmp(s0, s0new, ss) != 0) rc = fl_bdev_write(d, 0, 1, s0new);
  if (rc == FL_OK) {
    memset(h, 0, ss);
    gpt_header(h, 1, total - 1, l->first_usable, last_usable, l->disk_guid, 2, ecrc);
    rc = fl_bdev_write(d, 1, 1, h);
  }
  free(ent);
  free(h);
  free(s0);
  free(s0new);
  return rc;
}

static int store_mbr(fl_bdev *d, const fl_pt_layout *l) {
  uint8_t *s0 = malloc(d->sector_size), *old = malloc(d->sector_size);
  int rc = s0 && old ? fl_bdev_read(d, 0, 1, s0) : FL_ENOMEM;
  if (rc == FL_OK) {
    memcpy(old, s0, d->sector_size);
    le32(s0 + 440, l->mbr_signature);
    for (uint32_t slot = 0; slot < 4; slot++) {
      uint8_t *x = s0 + 446 + 16 * slot;
      const fl_pt_entry *p = NULL;
      for (uint32_t i = 0; i < l->count; i++)
        if (!l->e[i].logical && l->e[i].index == slot + 1) p = &l->e[i];
      if (!p) {
        memset(x, 0, 16);
        continue;
      }
      if (x[4] == p->mbr_type && rd32(x + 8) == p->first_lba && rd32(x + 12) == p->sector_count) continue;
      x[0] = 0x00;
      x[1] = 0xFE; x[2] = 0xFF; x[3] = 0xFF;
      x[4] = p->mbr_type;
      x[5] = 0xFE; x[6] = 0xFF; x[7] = 0xFF;
      le32(x + 8, (uint32_t)p->first_lba);
      le32(x + 12, (uint32_t)p->sector_count);
    }
    s0[510] = 0x55;
    s0[511] = 0xAA;
    if (memcmp(old, s0, d->sector_size) != 0) rc = fl_bdev_write(d, 0, 1, s0);
  }
  free(s0);
  free(old);
  return rc;
}

int fl_pt_store(fl_bdev *d, const fl_pt_layout *l) {
  if (!d || !l || d->sector_size != l->sector_size || d->sector_count < 4 * (MIB / d->sector_size)) return FL_EINVAL;
  if (d->read_only) return FL_EROFS;
  if (l->kind == FL_PT_NONE || l->has_extended) return FL_ENOTSUP;
  int rc = fl_pt_validate(l);
  if (rc != FL_OK) return rc;
  if (l->kind == FL_PT_GPT) {
    for (uint32_t i = 0; i < l->count; i++) /* le disque a pu rétrécir depuis la lecture */
      if (l->e[i].first_lba + l->e[i].sector_count - 1 > d->sector_count - 2 - fl_pt_gpt_entry_sectors(d->sector_size))
        return FL_EINVAL;
    rc = store_gpt(d, l);
  } else {
    rc = store_mbr(d, l);
  }
  return rc == FL_OK ? fl_bdev_flush(d) : rc;
}

int fl_pt_new_table(fl_bdev *d, fl_pt_kind kind) {
  if (!d || (kind != FL_PT_GPT && kind != FL_PT_MBR) || d->sector_size < 512 || d->sector_size > MIB) return FL_EINVAL;
  if (d->read_only) return FL_EROFS;
  uint64_t m = MIB / d->sector_size;
  if (d->sector_count < 4 * m) return FL_ENOSPC;
  fl_pt_layout *l = calloc(1, sizeof *l);
  if (!l) return FL_ENOMEM;
  l->kind = kind;
  l->sector_size = d->sector_size;
  l->sector_count = d->sector_count;
  int rc;
  if (kind == FL_PT_GPT) {
    l->first_usable = 2 + fl_pt_gpt_entry_sectors(d->sector_size);
    l->last_usable = d->sector_count - 2 - fl_pt_gpt_entry_sectors(d->sector_size);
    rc = fl_pt_random_guid(l->disk_guid);
  } else {
    l->first_usable = 1;
    l->last_usable = (d->sector_count < (1ull << 32) ? d->sector_count : (1ull << 32)) - 1;
    do rc = fl_random(&l->mbr_signature, sizeof l->mbr_signature);
    while (rc == FL_OK && l->mbr_signature == 0);
  }
  /* anciens en-têtes (GPT, LUKS, superblocs) : premier et dernier Mio effacés */
  if (rc == FL_OK) rc = fl_fmt_zero(d, 0, m);
  if (rc == FL_OK) rc = fl_fmt_zero(d, d->sector_count - m, m);
  if (rc == FL_OK) rc = fl_pt_store(d, l);
  free(l);
  return rc;
}

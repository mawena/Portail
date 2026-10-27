/* Table de partitions modifiable (phase 17) : lecture complète, contrôle et espaces libres.
 *
 * La lecture garde tout ce que l'écriture (layout_write.c) doit reproduire : GUID du disque et des
 * partitions, attributs, noms bruts, signature MBR. Un MBR hybride ou un GPT à un tableau d'entrées
 * inhabituel est refusé (FL_ENOTSUP) plutôt que réécrit avec une perte. Un secteur 0 qui est un secteur de
 * démarrage FAT, exFAT ou NTFS (disque sans table) donne une table NONE. */
#include <stdlib.h>
#include <string.h>

#include "fluluks/error.h"
#include "fluluks/partedit.h"
#include "part/crc32.h"
#include "part/part_internal.h"

#define MIB (1024ull * 1024ull)

static uint32_t rd32(const uint8_t *p) {
  return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}
static uint64_t rd64(const uint8_t *p) { return (uint64_t)rd32(p) | (uint64_t)rd32(p + 4) << 32; }

static void name_to_utf8(const uint8_t *src, char *dst, size_t cap) {
  size_t pos = 0;
  for (int i = 0; i < 36; i++) {
    uint32_t u = (uint32_t)src[2 * i] | (uint32_t)src[2 * i + 1] << 8;
    if (u == 0) break;
    if (u >= 0xD800 && u <= 0xDBFF && i + 1 < 36) {
      uint32_t lo = (uint32_t)src[2 * i + 2] | (uint32_t)src[2 * i + 3] << 8;
      if (lo >= 0xDC00 && lo <= 0xDFFF) {
        u = 0x10000 + ((u - 0xD800) << 10) + (lo - 0xDC00);
        i++;
      } else {
        u = 0xFFFD;
      }
    } else if (u >= 0xD800 && u <= 0xDFFF) {
      u = 0xFFFD;
    }
    char t[4];
    size_t n;
    if (u < 0x80) { t[0] = (char)u; n = 1; }
    else if (u < 0x800) { t[0] = (char)(0xC0 | u >> 6); t[1] = (char)(0x80 | (u & 0x3F)); n = 2; }
    else if (u < 0x10000) {
      t[0] = (char)(0xE0 | u >> 12); t[1] = (char)(0x80 | ((u >> 6) & 0x3F)); t[2] = (char)(0x80 | (u & 0x3F)); n = 3;
    } else {
      t[0] = (char)(0xF0 | u >> 18); t[1] = (char)(0x80 | ((u >> 12) & 0x3F));
      t[2] = (char)(0x80 | ((u >> 6) & 0x3F)); t[3] = (char)(0x80 | (u & 0x3F)); n = 4;
    }
    if (pos + n >= cap) break;
    memcpy(dst + pos, t, n);
    pos += n;
  }
  dst[pos] = '\0';
}

uint64_t fl_pt_gpt_entry_sectors(uint32_t ss) { return (128ull * 128ull + ss - 1) / ss; }

/* En-tête GPT à `lba` et son tableau d'entrées (128 × 128 octets, alloué). FL_ECORRUPT si invalide,
 * FL_ENOTSUP si valide mais d'un autre format de tableau. */
static int gpt_read(fl_bdev *d, uint64_t lba, uint8_t *h, uint8_t **ents) {
  uint32_t ss = d->sector_size;
  *ents = NULL;
  if (lba >= d->sector_count) return FL_ECORRUPT;
  int rc = fl_bdev_read(d, lba, 1, h);
  if (rc != FL_OK) return rc;
  if (memcmp(h, "EFI PART", 8) != 0) return FL_ECORRUPT;
  uint32_t hsize = rd32(h + 12);
  if (hsize < 92 || hsize > 512) return FL_ECORRUPT;
  uint8_t hb[512];
  memcpy(hb, h, hsize);
  memset(hb + 16, 0, 4);
  if (fl_crc32(hb, hsize) != rd32(h + 16) || rd64(h + 24) != lba) return FL_ECORRUPT;
  uint64_t elba = rd64(h + 72);
  uint32_t nent = rd32(h + 80), esize = rd32(h + 84);
  if (nent != 128 || esize != 128) return FL_ENOTSUP;
  uint64_t esec = fl_pt_gpt_entry_sectors(ss);
  if (!fl_range_ok(elba, esec, d->sector_count)) return FL_ECORRUPT;
  uint8_t *e = calloc(esec, ss);
  if (!e) return FL_ENOMEM;
  rc = fl_bdev_read(d, elba, (uint32_t)esec, e);
  if (rc == FL_OK && fl_crc32(e, 128 * 128) != rd32(h + 88)) rc = FL_ECORRUPT;
  if (rc != FL_OK) {
    free(e);
    return rc;
  }
  *ents = e;
  return FL_OK;
}

static int load_gpt(fl_bdev *d, fl_pt_layout *l) {
  uint8_t *h = malloc(d->sector_size), *e = NULL;
  if (!h) return FL_ENOMEM;
  int rc = gpt_read(d, 1, h, &e);
  if (rc == FL_ECORRUPT) rc = gpt_read(d, d->sector_count - 1, h, &e);
  if (rc == FL_OK) {
    uint64_t esec = fl_pt_gpt_entry_sectors(d->sector_size);
    l->kind = FL_PT_GPT;
    l->first_usable = rd64(h + 40);
    l->last_usable = d->sector_count - 2 - esec; /* fin du disque, même s'il a grandi depuis */
    memcpy(l->disk_guid, h + 56, 16);
    static const uint8_t zero[16];
    for (uint32_t i = 0; i < 128; i++) {
      const uint8_t *x = e + 128 * i;
      if (memcmp(x, zero, 16) == 0) continue;
      fl_pt_entry *p = &l->e[l->count++];
      p->index = i + 1;
      p->first_lba = rd64(x + 32);
      uint64_t last = rd64(x + 40);
      p->sector_count = last >= p->first_lba ? last - p->first_lba + 1 : 0; /* invalide : refusé au contrôle */
      memcpy(p->gpt_type, x, 16);
      memcpy(p->gpt_guid, x + 16, 16);
      p->gpt_attrs = rd64(x + 48);
      memcpy(p->name_raw, x + 56, 72);
      name_to_utf8(x + 56, p->name, sizeof p->name);
    }
  }
  free(e);
  free(h);
  return rc;
}

static int is_extended(uint8_t t) { return t == 0x05 || t == 0x0F || t == 0x85; }

/* Secteur de démarrage d'un système de fichiers posé sans table. */
static int boot_sector(const uint8_t *s0) {
  return memcmp(s0 + 3, "NTFS    ", 8) == 0 || memcmp(s0 + 3, "EXFAT   ", 8) == 0 ||
         memcmp(s0 + 82, "FAT32   ", 8) == 0 || memcmp(s0 + 54, "FAT1", 4) == 0;
}

static int load_mbr(fl_bdev *d, const uint8_t *s0, fl_pt_layout *l) {
  fl_part_table *t = calloc(1, sizeof *t);
  if (!t) return FL_ENOMEM;
  int rc = fl_mbr_read(d, s0, t);
  if (rc == FL_OK) {
    l->kind = FL_PT_MBR;
    l->first_usable = 1;
    l->last_usable = (d->sector_count < (1ull << 32) ? d->sector_count : (1ull << 32)) - 1;
    l->mbr_signature = rd32(s0 + 440);
    for (int i = 0; i < 4; i++)
      if (is_extended(s0[446 + 16 * i + 4]) && rd32(s0 + 446 + 16 * i + 12) != 0) l->has_extended = true;
    for (uint32_t i = 0; i < t->count; i++) {
      fl_pt_entry *p = &l->e[l->count++];
      p->index = t->parts[i].index;
      p->first_lba = t->parts[i].first_lba;
      p->sector_count = t->parts[i].sector_count;
      p->mbr_type = t->parts[i].mbr_type;
      p->logical = p->index >= 5;
    }
  }
  free(t);
  return rc;
}

int fl_pt_load(fl_bdev *d, fl_pt_layout *out) {
  if (!d || !out || d->sector_size < 512) return FL_EINVAL;
  memset(out, 0, sizeof *out);
  out->kind = FL_PT_NONE;
  out->sector_size = d->sector_size;
  out->sector_count = d->sector_count;
  if (d->sector_count < 2) return FL_OK;
  uint8_t *s0 = malloc(d->sector_size);
  if (!s0) return FL_ENOMEM;
  int rc = fl_bdev_read(d, 0, 1, s0);
  if (rc != FL_OK || s0[510] != 0x55 || s0[511] != 0xAA || memcmp(s0, "LUKS\xBA\xBE", 6) == 0 || boot_sector(s0)) {
    free(s0);
    return rc;
  }
  int protective = 0, others = 0, bad_status = 0;
  for (int i = 0; i < 4; i++) {
    const uint8_t *x = s0 + 446 + 16 * i;
    if (x[0] != 0x00 && x[0] != 0x80) bad_status = 1;
    if (x[4] == 0xEE) protective = 1;
    else if (x[4] != 0 && rd32(x + 12) != 0) others = 1;
  }
  if (bad_status) rc = FL_OK; /* ce n'est pas une table : NONE */
  else if (protective && others) rc = FL_ENOTSUP; /* MBR hybride */
  else if (protective) rc = load_gpt(d, out);
  else rc = load_mbr(d, s0, out);
  free(s0);
  return rc;
}

int fl_pt_validate(const fl_pt_layout *l) {
  if (!l || l->count > 128) return FL_EINVAL;
  if (l->kind == FL_PT_NONE) return l->count == 0 ? FL_OK : FL_EINVAL;
  for (uint32_t i = 0; i < l->count; i++) {
    const fl_pt_entry *a = &l->e[i];
    if (a->sector_count == 0 || a->first_lba < l->first_usable) return FL_EINVAL;
    if (a->first_lba > l->last_usable || a->sector_count - 1 > l->last_usable - a->first_lba) return FL_EINVAL;
    if (l->kind == FL_PT_GPT && (a->index < 1 || a->index > 128)) return FL_EINVAL;
    if (l->kind == FL_PT_MBR && (a->logical ? a->index < 5 : (a->index < 1 || a->index > 4))) return FL_EINVAL;
    for (uint32_t j = 0; j < i; j++) {
      const fl_pt_entry *b = &l->e[j];
      if (a->index == b->index) return FL_EINVAL;
      uint64_t ae = a->first_lba + a->sector_count, be = b->first_lba + b->sector_count;
      if (a->first_lba < be && b->first_lba < ae) return FL_EINVAL;
    }
  }
  return FL_OK;
}

static int by_start(const void *x, const void *y) {
  const fl_pt_entry *a = *(const fl_pt_entry *const *)x, *b = *(const fl_pt_entry *const *)y;
  return a->first_lba < b->first_lba ? -1 : a->first_lba > b->first_lba;
}

uint32_t fl_pt_free(const fl_pt_layout *l, fl_pt_region *out, uint32_t cap) {
  if (!l || l->kind == FL_PT_NONE || l->has_extended || l->sector_size == 0 || l->count > 128) return 0;
  const fl_pt_entry *s[128];
  for (uint32_t i = 0; i < l->count; i++) s[i] = &l->e[i];
  qsort(s, l->count, sizeof s[0], by_start);
  uint64_t m = MIB / l->sector_size, cur = l->first_usable, n = 0;
  for (uint32_t i = 0; i <= l->count; i++) {
    uint64_t gap_end = i < l->count ? s[i]->first_lba : l->last_usable + 1; /* exclu */
    uint64_t a = (cur + m - 1) / m * m, b = gap_end / m * m;
    if (b > a && b - a >= m) {
      if (n < cap) {
        out[n].first_lba = a;
        out[n].sector_count = b - a;
      }
      n++;
    }
    if (i < l->count && s[i]->first_lba + s[i]->sector_count > cur) cur = s[i]->first_lba + s[i]->sector_count;
  }
  return (uint32_t)n;
}

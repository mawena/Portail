#ifndef FL_PART_INTERNAL_H
#define FL_PART_INTERNAL_H

#include "fluluks/partition.h"

#define FL_PART_MAX 128

/* Lit le GPT (primaire puis secours). FL_OK si un en-tête valide a été lu (count peut être 0),
 * FL_ECORRUPT si aucun n'est valide, autre code en cas d'erreur d'E/S. */
int fl_gpt_read(fl_bdev *d, fl_part_table *out);

/* Lit les partitions du MBR (secteur 0 déjà lu, 512 octets, signature vérifiée), y compris
 * les logiques. Les entrées 0xEE sont ignorées. */
int fl_mbr_read(fl_bdev *d, const uint8_t *sector0, fl_part_table *out);

/* Secteurs du tableau d'entrées GPT (128 × 128 octets) pour des secteurs de `ss` octets. */
uint64_t fl_pt_gpt_entry_sectors(uint32_t ss);
/* GUID aléatoire (version 4, variante RFC 4122), dans l'ordre des octets de GPT. */
int fl_pt_random_guid(uint8_t g[16]);

/* a + b <= limit sans dépassement. */
static inline int fl_range_ok(uint64_t a, uint64_t b, uint64_t limit) {
  return a <= limit && b <= limit - a;
}

#endif

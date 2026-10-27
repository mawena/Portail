#ifndef FLULUKS_PARTOPS_H
#define FLULUKS_PARTOPS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "fluluks/blockdev.h"
#include "fluluks/format.h"
#include "fluluks/probe.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Opérations sur une partition d'un disque USB (phase 17). Chacune relit la table et revérifie tout avant
 * d'écrire ; une opération sur une partition existante rend FL_ECHANGED si `index` n'est plus au début
 * `expect_first_lba` attendu. Partition étendue ou logique (MBR) : FL_ENOTSUP, sauf indication contraire.
 * Jamais d'appel sur un disque dont un volume est monté (vérifié par l'appelant, comme fl_format). */

typedef void (*fl_progress_fn)(int pct, void *arg);

/* Nouvelle partition [first_lba, first_lba + count) dans un espace libre, alignée sur 1 Mio, puis son
 * système de fichiers (LUKS2 si demandé). La table est écrite avant le système de fichiers. Avant toute
 * écriture : FL_EINVAL (non aligné, chevauchement, hors du disque, plus de place dans la table, options),
 * FL_ENOSPC (trop petite pour ce format), FL_EFBIG (FAT32 sur 2^32 secteurs ou plus). `o->part_bytes` et
 * `o->no_table` sont ignorés. `index_out` reçoit l'index de la nouvelle partition. */
int fl_part_create(fl_bdev *disk, uint64_t first_lba, uint64_t count, const fl_fmt_opts *o,
                   const void *pass, size_t passlen, fl_progress_fn cb, void *arg, uint32_t *index_out);

/* Retire la partition de la table ; ses données ne sont pas effacées. */
int fl_part_delete(fl_bdev *disk, uint32_t index, uint64_t expect_first_lba);

/* Formate la seule partition `index` (premier et dernier Mio effacés, LUKS2 éventuel, système de
 * fichiers) ; son type dans la table suit le format. Mêmes refus que fl_part_create. */
int fl_part_format(fl_bdev *disk, uint32_t index, uint64_t expect_first_lba, const fl_fmt_opts *o,
                   const void *pass, size_t passlen, fl_progress_fn cb, void *arg);

typedef struct {
  fl_content content;
  char label[64];
  bool known;                     /* faux : chiffrée, inconnue ou illisible */
  uint64_t used_bytes, total_bytes;
} fl_part_usage;

/* Contenu, étiquette et place occupée de la partition `index` (logiques comprises), par un montage en
 * lecture seule du système de fichiers. FL_ENOENT si l'index n'existe pas. */
int fl_part_usage_of(fl_bdev *disk, uint32_t index, fl_part_usage *out);

#ifdef __cplusplus
}
#endif

#endif

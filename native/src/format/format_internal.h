#ifndef FL_FORMAT_INTERNAL_H
#define FL_FORMAT_INTERNAL_H

#include <stdbool.h>
#include <stdint.h>

#include "fluluks/blockdev.h"
#include "fluluks/format.h"

/* Nombre de caractères (unités UTF-16) d'une étiquette UTF-8 valide sans caractère de contrôle ; -1 sinon
 * (label.c). */
int fl_label_utf16_units(const char *s);
/* FL_OK si `label` (NULL = vide) convient au système de fichiers, FL_EINVAL sinon (label.c) : FAT32 11
 * caractères ASCII sans "*+,./:;<=>?[\]|, exFAT 11, ext4 16 octets, NTFS 32 (unités UTF-16). */
int fl_fmt_check_label(fl_fmt_fs fs, const char *label);
/* Place qu'aurait la partition de fl_part_write_single, sans rien écrire (part_write.c). */
int fl_part_layout(const fl_bdev *d, uint64_t *first_lba, uint64_t *count, bool *gpt);
/* Écrit `n` secteurs de zéros à partir de `lba`, par paquets d'au plus 1 Mio (part_write.c). */
int fl_fmt_zero(fl_bdev *d, uint64_t lba, uint64_t n);

/* Écrit une table neuve (MBR, ou GPT si `gpt`) à la seule partition [first, first + count), du type qui
 * convient au format (part_write.c). */
int fl_part_write_one(fl_bdev *d, fl_fmt_fs fs, bool encrypted, uint64_t first, uint64_t count, bool gpt);
/* Types de partition pour un format : octet MBR et GUID GPT (part_write.c). */
void fl_fmt_part_type(fl_fmt_fs fs, bool encrypted, uint8_t *mbr, uint8_t gpt[16]);
/* Taille minimale d'une partition pour ce format, en-tête LUKS2 compris (format.c). */
uint64_t fl_fmt_min_bytes(fl_fmt_fs fs, uint32_t ss, bool encrypted);
/* Vérifications d'avant écriture d'un formatage sur `count` secteurs : options, étiquette, phrase, taille
 * minimale (FL_ENOSPC), FAT32 au-delà de 2^32 secteurs (FL_EFBIG) (format.c). */
int fl_fmt_check(const fl_bdev *disk, const fl_fmt_opts *o, const void *pass, size_t passlen, uint64_t count);
/* Formate la tranche [first, first + count) de `disk` : premier Mio (et dernier si wipe_end) effacés, LUKS2
 * si demandé, système de fichiers (NTFS : hidden_sectors en clair), vidage du disque. Progression 10, 60,
 * 95 (format.c). */
int fl_fmt_slice(fl_bdev *disk, uint64_t first, uint64_t count, const fl_fmt_opts *o, bool wipe_end,
                 uint64_t hidden_sectors, const void *pass, size_t passlen, void (*progress)(int pct, void *arg),
                 void *arg);

#endif

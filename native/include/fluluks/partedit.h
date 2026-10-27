#ifndef FLULUKS_PARTEDIT_H
#define FLULUKS_PARTEDIT_H

#include <stdbool.h>
#include <stdint.h>
#include "fluluks/blockdev.h"
#include "fluluks/partition.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Table de partitions modifiable (phase 17). fl_part_scan (phase 1) reste celle du montage : celle-ci
 * garde tout ce qu'il faut pour réécrire la table à l'identique hors des entrées changées. */

typedef struct {
  uint32_t index;            /* GPT : 1..128 (position dans le tableau) ; MBR : 1..4, logiques 5.. */
  uint64_t first_lba, sector_count;
  uint8_t  mbr_type;         /* 0 en GPT */
  uint8_t  gpt_type[16], gpt_guid[16]; /* GUID nul : tiré au hasard à l'écriture */
  uint64_t gpt_attrs;
  char     name[73];         /* nom GPT en UTF-8 (lecture seule : l'écriture garde name_raw) */
  uint8_t  name_raw[72];     /* nom GPT tel qu'écrit (UTF-16LE) */
  bool     logical;          /* MBR : dans une partition étendue */
} fl_pt_entry;

typedef struct {
  fl_pt_kind kind;           /* NONE : aucune table (disque vierge ou système de fichiers sans table) */
  uint32_t sector_size;
  uint64_t sector_count;
  uint64_t first_usable, last_usable; /* GPT : de l'en-tête, fin recalculée sur la taille du disque ;
                                         MBR : 1 et min(fin du disque, 2^32 - 1) */
  uint8_t  disk_guid[16];
  uint32_t mbr_signature;
  bool     has_extended;     /* MBR avec partition étendue : seule l'étiquette se change */
  uint32_t count;
  fl_pt_entry e[128];
} fl_pt_layout;

typedef struct {
  uint64_t first_lba, sector_count;
} fl_pt_region;

/* Lit la table : GPT valide (principal, sinon secours), MBR (logiques comprises), ou NONE. FL_ENOTSUP
 * pour une table qu'on ne sait pas réécrire sans rien perdre : MBR hybride (protecteur plus d'autres
 * entrées), GPT à autre chose que 128 entrées de 128 octets. */
int fl_pt_load(fl_bdev *d, fl_pt_layout *out);

/* FL_OK, ou FL_EINVAL : entrée vide ou hors de [first_usable, last_usable], chevauchement, index en double
 * ou hors bornes, MBR à plus de 4 principales. */
int fl_pt_validate(const fl_pt_layout *l);

/* Écrit la table décrite par `l` (validée d'abord) : GPT dans l'ordre secours (entrées, en-tête),
 * principal (entrées, MBR protecteur, en-tête en dernier), puis vidage ; MBR en un secteur. Garde le code
 * d'amorçage, la signature, le GUID du disque, les attributs, les noms et les octets des entrées MBR
 * inchangées. FL_ENOTSUP pour un MBR à partition étendue ou une table NONE. */
int fl_pt_store(fl_bdev *d, const fl_pt_layout *l);

/* Nouvelle table vide (MBR ou GPT) : premier et dernier Mio effacés, GUID ou signature aléatoires. */
int fl_pt_new_table(fl_bdev *d, fl_pt_kind kind);

/* Espaces libres de `l`, début et fin alignés sur 1 Mio, d'un Mio au moins, dans l'ordre du disque.
 * Rend leur nombre (au plus cap écrits). Aucun pour une table NONE ou un MBR à partition étendue. */
uint32_t fl_pt_free(const fl_pt_layout *l, fl_pt_region *out, uint32_t cap);

#ifdef __cplusplus
}
#endif

#endif

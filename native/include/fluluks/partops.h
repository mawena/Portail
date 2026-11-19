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

/* Étiquette de la partition `index` (phase 18), logiques comprises : FAT12/16/32 (entrée du dossier racine et
 * BS_VolLab du secteur de démarrage et de sa copie, en majuscules), exFAT, ext4, NTFS ; chiffrée : étiquette
 * du système de fichiers intérieur, phrase exigée (FL_EBADPASS sinon). Étiquette refusée par les règles du
 * formatage : FL_EINVAL avant toute écriture. Le nom de partition GPT ne change pas. */
int fl_part_set_label(fl_bdev *disk, uint32_t index, uint64_t expect_first_lba, const char *label, const void *pass,
                      size_t passlen);

/* --- ext4 par e2fsprogs (phase 18) ------------------------------------------------------------------
 * `vol` est la partition ou le volume LUKS déchiffré ; aucune de ces fonctions ne garde `vol` après son
 * retour. Un seul appel à la fois (verrou commun), sur un fil à pile de 8 Mio. */

typedef struct {
  bool clean;        /* rien à redire : code 0, journal rejoué, superbloc valide et sans erreur */
  int exit_code;     /* code d'e2fsck (0, 4 : erreurs laissées, 8 : vérification impossible) */
  char report[4096]; /* début de la sortie de l'outil, toujours terminé par NUL */
} fl_check_report;

/* e2fsck -fn : rien n'est écrit. FL_OK dès que la vérification a pu se faire (propre ou non) ;
 * FL_ECORRUPT si le système de fichiers ne s'ouvre pas (rapport rempli quand même) ; FL_ENODEV,
 * FL_ETIMEDOUT… si le disque ne répond plus. */
int fl_e2fs_check(fl_bdev *vol, fl_check_report *out);
/* Taille minimale du système de fichiers, comme « resize2fs -P », en octets. FL_ECORRUPT si le système
 * de fichiers doit d'abord être vérifié (erreurs notées, journal à rejouer). */
int fl_e2fs_min_size(fl_bdev *vol, uint64_t *bytes);
/* Système de fichiers porté à `new_bytes` (arrondi au bloc inférieur), au plus la taille de `vol`, au
 * moins fl_e2fs_min_size. FL_EINVAL hors de ces bornes, FL_ECORRUPT comme ci-dessus, FL_ENOTSUP si une
 * fonction du système de fichiers l'interdit (stable_inodes en réduction), FL_EFBIG au-delà de 2^32 blocs
 * sans 64bit. Taille inchangée : FL_OK sans écriture. */
int fl_e2fs_resize(fl_bdev *vol, uint64_t new_bytes, fl_progress_fn cb, void *arg);
/* Étiquette (16 octets au plus, sinon FL_EINVAL), écrite dans le superbloc et ses copies. */
int fl_e2fs_set_label(fl_bdev *vol, const char *label);

/* --- NTFS par ntfs-3g (phase 18) : mêmes règles que pour ext4 -------------------------------------------- */

/* ntfsfix -n, puis la vérification de cohérence de ntfsresize --info ; rien n'est écrit. `clean` faux aussi
 * pour un volume marqué à vérifier par Windows. FL_ECORRUPT si le volume ne s'ouvre pas. */
int fl_ntfs_check(fl_bdev *vol, fl_check_report *out);
/* Taille de partition minimale, comme « ntfsresize --info » (volume réduit au plus court, plus la copie du
 * secteur de démarrage). FL_ECORRUPT si le volume est marqué à vérifier ou incohérent. */
int fl_ntfs_min_size(fl_bdev *vol, uint64_t *bytes);
/* Volume porté à `new_bytes` (au plus la taille de `vol`, au moins fl_ntfs_min_size : FL_EINVAL sinon).
 * Comme ntfsresize, le volume est ensuite marqué à vérifier par Windows. */
int fl_ntfs_resize(fl_bdev *vol, uint64_t new_bytes, fl_progress_fn cb, void *arg);
/* Étiquette (règles du formatage : 32 caractères), comme ntfslabel. */
int fl_ntfs_set_label(fl_bdev *vol, const char *label);

#ifdef __cplusplus
}
#endif

#endif

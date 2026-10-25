#ifndef FLULUKS_LUKS_H
#define FLULUKS_LUKS_H

#include <stddef.h>
#include <stdint.h>

#include "fluluks/blockdev.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct fl_luks fl_luks;

/* Lit et valide l'en-tête. FL_ENOTSUP si ce n'est pas du LUKS (ou version inconnue),
 * FL_ECORRUPT si l'en-tête est incohérent. `dev` doit rester ouvert tant que `l` ou un
 * périphérique déchiffré en dépend. */
int fl_luks_open(fl_bdev *dev, fl_luks **out);
/* 1 ou 2. */
int fl_luks_version(const fl_luks *l);
/* Ex. "aes-xts-plain64". Valable jusqu'à fl_luks_close. */
const char *fl_luks_cipher(const fl_luks *l);
/* Plus grande mémoire Argon2 (Kio) parmi les keyslots utilisables (pris en charge, de priorité non nulle,
 * liés au segment), pour vérifier avant le déverrouillage que la mémoire suffit. 0 si tous ces slots
 * utilisent PBKDF2 (et toujours pour LUKS1). FL_EINVAL si l ou out est NULL (*out inchangé). */
int fl_luks_max_kdf_memory_kib(const fl_luks *l, uint32_t *out);
/* Essaie chaque keyslot actif ; FL_EBADPASS si aucun ne convient (*decrypted = NULL).
 * Le bdev rendu emprunte `dev` et possède sa propre copie de la clé maître (mémoire
 * sécurisée). Ordre de fermeture : fl_bdev_close(decrypted), puis fl_luks_close(l),
 * puis fermeture de `dev`. */
int fl_luks_unlock(fl_luks *l, const void *pass, size_t passlen, fl_bdev **decrypted);
/* Comme fl_luks_unlock, mais avec le seul emplacement `slot` (LUKS2 : 0 à 31, LUKS1 : 0 à 7) : les
 * autres ne sont pas essayés (leur dérivation de clé n'est pas calculée). slot = −1 : tous. FL_ENOENT si
 * l'emplacement n'existe pas ou n'est pas utilisable. */
int fl_luks_unlock_slot(fl_luks *l, int slot, const void *pass, size_t passlen, fl_bdev **decrypted);
/* Efface tout secret ; NULL accepté. */
void fl_luks_close(fl_luks *l);

/* Emplacements de clé (phase 14). Ces fonctions lisent l'en-tête de `dev` elles-mêmes : `dev` ne doit
 * pas être modifié par ailleurs pendant l'appel ; un volume déjà déverrouillé reste valable (la clé
 * maîtresse ne change pas).
 *
 * Bit n de *mask : l'emplacement n existe (LUKS1 : actif ; LUKS2 : présent dans l'en-tête, n < 32).
 * FL_ENOTSUP si ce n'est pas du LUKS. */
int fl_luks_slots(fl_bdev *dev, uint32_t *mask);
/* Crée ou remplace l'emplacement `slot` (0 à 31) de phrase `nw` (Argon2id, kdf_time passes, kdf_mem_kib
 * Kio, 4 fils ; bandes AF de 4 000, aes-xts-plain64, comme fl_luks2_format). `auth` doit ouvrir n'importe
 * quel emplacement (clé maîtresse vérifiée par son condensé, jamais rendue). Rien n'est écrit avant que
 * tout soit vérifié. Ordre des écritures, chacune vidée : zone de clé neuve (dans un espace libre de la
 * zone des emplacements), en-tête primaire, en-tête secondaire (seqid + 1), puis effacement de l'ancienne
 * zone : une coupure à n'importe quel moment laisse l'ancienne ou la nouvelle phrase valable.
 * FL_EINVAL (slot hors bornes, nw vide, kdf_mem_kib < 8 192, kdf_time hors de 1 à 1 000), FL_EBADPASS,
 * FL_ENOTSUP (LUKS1, ou en-tête LUKS2 que ce code ne réécrit pas), FL_ENOSPC (zone des emplacements ou
 * zone JSON pleine). */
int fl_luks2_slot_set(fl_bdev *dev, int slot, const void *auth, size_t authlen, const void *nw, size_t nwlen,
                      uint32_t kdf_mem_kib, uint32_t kdf_time);
/* Retire l'emplacement `slot` (mêmes garanties d'ordre ; sa zone est effacée après les en-têtes).
 * FL_ENOENT s'il n'existe pas, FL_EBUSY si c'est le dernier emplacement lié aux données, FL_EBADPASS si
 * `auth` n'ouvre aucun emplacement (le retiré compris). */
int fl_luks2_slot_remove(fl_bdev *dev, int slot, const void *auth, size_t authlen);

#ifdef __cplusplus
}
#endif

#endif

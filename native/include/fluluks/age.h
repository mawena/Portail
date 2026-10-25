#ifndef FLULUKS_AGE_H
#define FLULUKS_AGE_H
/* Format age v1 (https://age-encryption.org/v1), destinataire « scrypt » seul (phase 14).
 * Écriture et lecture en flux sur les entrées et sorties des archives (fluluks/archive.h) ; la lecture est à
 * accès aléatoire, par morceau de 64 Kio authentifié (ChaCha20-Poly1305). Les clés vivent en mémoire
 * sécurisée et sont effacées à la fermeture ; le mot de passe n'est jamais copié au-delà de l'appel. */
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "fluluks/archive.h"

#ifdef __cplusplus
extern "C" {
#endif

#define FL_AGE_LOG2N_DEFAULT 18 /* scrypt N = 2^18, r = 8, p = 1 : 256 Mio */
#define FL_AGE_LOG2N_MAX 22     /* au-delà, refusé même si la mémoire le permet */

typedef struct fl_agew fl_agew;

/* Écrit l'en-tête (destinataire scrypt de facteur log2n, 1 à 22) et le nonce sur `out`.
 * FL_EINVAL : paramètres ; FL_ENOMEM : mémoire de scrypt ; erreur de `out` rendue telle quelle.
 * `out` doit vivre jusqu'à fl_agew_close. */
int fl_agew_open(const fl_arc_out *out, const void *pass, size_t passlen, uint8_t log2n, fl_agew **w);
/* Données en clair, par morceaux de toute taille. */
int fl_agew_write(fl_agew *w, const void *buf, size_t len);
/* commit : écrit le dernier morceau (marqué) ; sinon plus rien n'est écrit. Libère `w` (efface les clés).
 * Rend la première erreur rencontrée. */
int fl_agew_close(fl_agew *w, bool commit);

typedef struct fl_ager fl_ager;

/* Ouvre un fichier age : en-tête, mot de passe, MAC de l'en-tête, dernier morceau (troncature).
 * FL_ENOTSUP : pas un fichier age v1, armure ASCII, ou destinataire autre qu'un scrypt seul ;
 * FL_EBADPASS : mot de passe faux ; FL_ECORRUPT : en-tête, MAC, longueur impossible, dernier morceau ;
 * FL_ENOMEM : facteur de travail au-dessus de max_log2n (ou mémoire). `in` doit vivre jusqu'à fl_ager_close. */
int fl_ager_open(const fl_arc_in *in, const void *pass, size_t passlen, uint8_t max_log2n, fl_ager **r);
/* Taille en clair (calculée d'après la taille du chiffré). */
int64_t fl_ager_size(const fl_ager *r);
/* Lit `len` octets du clair à partir de `off` : octets lus (0 à la fin), FL_ECORRUPT si un morceau est
 * abîmé, permuté ou tronqué, FL_EIO si l'entrée échoue. Pas sûr entre fils : un appel à la fois. */
int64_t fl_ager_pread(fl_ager *r, void *buf, size_t len, uint64_t off);
void fl_ager_close(fl_ager *r);

/* 1 si `in` est un fichier age à destinataire scrypt seul (facteur dans *log2n), 0 sinon (autre fichier,
 * autre destinataire, en-tête invalide), < 0 si l'entrée échoue. Aucun mot de passe. */
int fl_age_peek(const fl_arc_in *in, uint8_t *log2n);

/* Change le mot de passe : même clé de fichier sous un nouvel en-tête (facteur log2n), nonce et morceaux
 * recopiés sans être déchiffrés vers la sortie, chacun vérifié au passage. Rien n'est écrit si l'ancien
 * mot de passe est faux (FL_EBADPASS) ; FL_ECORRUPT si un morceau est abîmé (la sortie est alors à jeter). */
int fl_age_rewrap(const fl_arc_in *in, const fl_arc_out *out, const void *old, size_t oldlen, const void *nw,
                  size_t nwlen, uint8_t log2n);

#ifdef __cplusplus
}
#endif

#endif

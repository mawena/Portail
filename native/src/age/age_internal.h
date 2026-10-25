#ifndef FL_AGE_INTERNAL_H
#define FL_AGE_INTERNAL_H
/* Format age v1 : en-tête, clés et morceaux (partagés par l'écrivain, le lecteur et le changement de mot
 * de passe). */
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include <mbedtls/chachapoly.h>

#include "fluluks/age.h"

#define AGE_CHUNK 65536                  /* clair d'un morceau plein */
#define AGE_TAG 16                       /* étiquette Poly1305 */
#define AGE_FULL (AGE_CHUNK + AGE_TAG)   /* chiffré d'un morceau plein */
#define AGE_HDR_MAX 16384                /* en-tête plus long : refusé */
#define AGE_FILE_KEY 16
#define AGE_NONCE 16

typedef struct {
  uint8_t salt[16];
  uint8_t log2n;
  uint8_t body[32];     /* clé de fichier chiffrée (16 octets + étiquette) */
  uint8_t mac[32];
  size_t mac_input_len; /* octets couverts par le MAC : de « age-… » jusqu'à « --- » inclus */
  size_t len;           /* longueur de l'en-tête, saut de ligne final compris */
} age_hdr;

/* Analyse un en-tête (n octets disponibles). FL_OK, FL_ENOTSUP (pas age v1, armure, autre destinataire
 * qu'un scrypt seul), FL_ECORRUPT (en-tête mal formé). */
int age_hdr_parse(const uint8_t *buf, size_t n, age_hdr *h);
/* Lit le début de `in` (au plus AGE_HDR_MAX octets) dans *buf (à libérer par free) et l'analyse. */
int age_hdr_read(const fl_arc_in *in, uint8_t **buf, size_t *n, age_hdr *h);
/* Construit l'en-tête complet (destinataire scrypt, MAC) pour la clé de fichier `fk` et le mot de passe.
 * *out alloué (free) de longueur *len. */
int age_hdr_build(const uint8_t fk[AGE_FILE_KEY], const void *pass, size_t passlen, uint8_t log2n, uint8_t **out,
                  size_t *len);
/* Déchiffre la clé de fichier (fk, 16 octets) avec le mot de passe, puis vérifie le MAC de l'en-tête
 * (hdr_bytes : l'en-tête lu). FL_ENOMEM si h->log2n > max_log2n, FL_EBADPASS, FL_ECORRUPT. */
int age_unwrap(const age_hdr *h, const uint8_t *hdr_bytes, const void *pass, size_t passlen, uint8_t max_log2n,
               uint8_t fk[AGE_FILE_KEY]);
/* Clé de charge : HKDF-SHA256(sel = nonce, ikm = fk, info « payload »). */
int age_payload_key(const uint8_t fk[AGE_FILE_KEY], const uint8_t nonce[AGE_NONCE], uint8_t key[32]);
/* Morceau `idx` : nonce de 11 octets gros-boutiste ‖ drapeau de fin. */
int age_chunk_seal(mbedtls_chachapoly_context *c, uint64_t idx, bool last, const uint8_t *in, size_t len,
                   uint8_t *out);
/* Ouvre un morceau chiffré de ctlen octets (>= AGE_TAG) ; FL_ECORRUPT si l'authentification échoue. */
int age_chunk_open(mbedtls_chachapoly_context *c, uint64_t idx, bool last, const uint8_t *in, size_t ctlen,
                   uint8_t *out);
/* Lecture exacte : FL_OK, FL_ECORRUPT si l'entrée est plus courte, FL_EIO. */
int age_pread_exact(const fl_arc_in *in, void *buf, size_t len, uint64_t off);

/* Disposition des morceaux d'un chiffré de `ct` octets (après le nonce). FL_ECORRUPT si impossible. */
typedef struct {
  uint64_t chunks;   /* nombre de morceaux (>= 1) */
  size_t last_len;   /* chiffré du dernier morceau */
  int64_t plain;     /* taille en clair */
} age_layout;
int age_layout_of(int64_t ct, age_layout *l);

#endif

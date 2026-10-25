#ifndef FL_LUKS2_INTERNAL_H
#define FL_LUKS2_INTERNAL_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define L2_MAX_SLOTS 64
#define L2_MAX_DIGESTS 64
#define L2_MAX_SALT 128
#define L2_MAX_DIGEST 64
#define L2_NAME 72

enum { L2_KDF_PBKDF2 = 1, L2_KDF_ARGON2I, L2_KDF_ARGON2ID };

typedef struct {
  uint32_t id;    /* numéro de l'emplacement dans le JSON */
  bool supported; /* type/KDF/hash/chiffrement pris en charge (sinon slot ignoré) */
  int priority; /* 1 normal, 2 haute (0 = jamais : conservé mais ignoré) */
  uint32_t key_size;
  uint32_t stripes;
  char af_hash[32];
  uint64_t area_off, area_size;
  char area_enc[L2_NAME];
  uint32_t area_key_size;
  int kdf;
  char kdf_hash[32];
  uint32_t time, memory, cpus, iterations;
  uint8_t salt[L2_MAX_SALT];
  size_t salt_len;
  int digest; /* indice du digest lié (qui liste aussi le segment 0), -1 sinon */
} l2_slot;

typedef struct {
  char hash[32];
  uint32_t iterations;
  uint8_t salt[L2_MAX_SALT];
  size_t salt_len;
  uint8_t digest[L2_MAX_DIGEST];
  size_t digest_len;
} l2_digest;

typedef struct {
  uint64_t seg_off;
  uint64_t seg_size; /* 0 = dynamique (jusqu'à la fin) */
  uint64_t iv_tweak;
  uint32_t sector_size;
  char seg_enc[L2_NAME];
  int nslots, ndigests;
  l2_slot slots[L2_MAX_SLOTS]; /* triés : priorité décroissante */
  l2_digest digests[L2_MAX_DIGESTS];
} luks2;

/* Analyse la zone JSON (terminée par NUL) ; dev_size en octets. */
int fl_luks2_parse_json(const char *json, uint64_t dev_size, luks2 *out);

/* cJSON_Parse sous le verrou de luks2_json.c (cJSON écrit une variable globale à chaque analyse). */
struct cJSON;
struct cJSON *fl_luks2_cjson_parse(const char *json);

#include "fluluks/blockdev.h"

/* Image d'un en-tête LUKS2 vérifié (binaire, JSON, somme). */
typedef struct {
  uint8_t *buf; /* size octets ; NULL si l'en-tête est absent ou invalide */
  size_t size;
  uint64_t seqid;
  uint64_t off; /* position sur le disque */
} l2_img;

typedef struct {
  l2_img hdr[2]; /* [0] primaire, [1] secondaire */
  int cur;       /* en-tête retenu : seqid le plus grand dont le JSON s'analyse (égalité : primaire) */
} l2_hdrs;

/* Lit les deux en-têtes de `dev` et analyse celui à retenir dans *x (alloué par l'appelant). Mêmes codes
 * que fl_luks_open. En cas de succès, h est à libérer par fl_luks2_hdrs_free. */
int fl_luks2_load(fl_bdev *dev, bool primary_ok, l2_hdrs *h, luks2 *x);
void fl_luks2_hdrs_free(l2_hdrs *h);

/* Retrouve la clé maîtresse (mk : 64 octets de mémoire sécurisée) avec `pass`, par l'emplacement d'identifiant
 * `slot` (−1 : tous, par priorité). *mkl, *digest : longueur de la clé et indice du digest qui l'a vérifiée.
 * FL_EBADPASS, FL_ENOENT (slot ≥ 0 absent ou inutilisable), ou erreur d'un emplacement (FL_ENOMEM, FL_EIO…). */
int fl_luks2_recover_mk(fl_bdev *dev, const luks2 *x, int slot, const void *pass, size_t passlen, uint8_t *mk,
                        size_t *mkl, int *digest);

#endif

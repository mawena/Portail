/* Colle entre scrypt de référence (third_party/scrypt, Tarsnap, copie non modifiée) et le moteur :
 * PBKDF2-HMAC-SHA256 de mbedTLS, allocations effacées avant libération, et fl_scrypt. */
#include <errno.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <mbedtls/pkcs5.h>

#include "crypto/fl_crypto.h"
#include "crypto_scrypt.h"
#include "fluluks/error.h"
#include "fluluks/secure.h"
#include "sha256.h"

/* PBKDF2_SHA256 ne peut pas rendre d'erreur (signature d'amont) : un échec de mbedTLS (allocation) est
 * noté ici et fl_scrypt le rend, la sortie étant alors jetée. */
static _Thread_local int g_pbkdf2_echec;

void PBKDF2_SHA256(const uint8_t *passwd, size_t passwdlen, const uint8_t *salt, size_t saltlen, uint64_t c,
                   uint8_t *buf, size_t dklen) {
  if (c > UINT32_MAX || dklen > UINT32_MAX ||
      mbedtls_pkcs5_pbkdf2_hmac_ext(MBEDTLS_MD_SHA256, passwd, passwdlen, salt, saltlen, (unsigned)c,
                                    (uint32_t)dklen, buf) != 0) {
    g_pbkdf2_echec = 1;
    fl_memzero(buf, dklen);
  }
}

/* En-tête de 16 octets devant chaque tampon : sa taille, pour l'effacer à la libération. */
#define ENTETE 16

void *fl_scrypt_malloc(size_t n) {
  if (n > SIZE_MAX - ENTETE) {
    errno = ENOMEM;
    return NULL;
  }
  uint8_t *p = malloc(n + ENTETE);
  if (!p) {
    errno = ENOMEM;
    return NULL;
  }
  memcpy(p, &n, sizeof n);
  return p + ENTETE;
}

void fl_scrypt_free(void *q) {
  if (!q) return;
  uint8_t *p = (uint8_t *)q - ENTETE;
  size_t n;
  memcpy(&n, p, sizeof n);
  fl_memzero(q, n);
  free(p);
}

int fl_scrypt(const void *pass, size_t passlen, const void *salt, size_t saltlen, uint8_t log2n, uint32_t r,
              uint32_t p, void *out, size_t outlen) {
  if (log2n < 1 || log2n > 22 || r == 0 || p == 0 || (uint64_t)r * p >= (1u << 30) || !out || outlen == 0 ||
      (!pass && passlen) || (!salt && saltlen))
    return FL_EINVAL;
  static const uint8_t vide[1];
  g_pbkdf2_echec = 0;
  errno = 0;
  int rc = fl_crypto_scrypt_ref(pass ? pass : vide, passlen, salt ? salt : vide, saltlen, (uint64_t)1 << log2n, r,
                                p, out, outlen);
  if (rc != 0 || g_pbkdf2_echec) {
    fl_memzero(out, outlen);
    return errno == EINVAL || errno == EFBIG ? FL_EINVAL : FL_ENOMEM;
  }
  return FL_OK;
}

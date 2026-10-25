#ifndef FL_SCRYPT_SHA256_H
#define FL_SCRYPT_SHA256_H
/* Remplace le sha256.h de libcperciva pour third_party/scrypt/crypto_scrypt-ref.c (copie d'amont non
 * modifiée) : seul PBKDF2_SHA256 y sert ; il est fourni par src/crypto/scrypt_glue.c sur mbedTLS. */
#include <stddef.h>
#include <stdint.h>

void PBKDF2_SHA256(const uint8_t *, size_t, const uint8_t *, size_t, uint64_t, uint8_t *, size_t);

/* Allocations du fichier de référence, redirigées (définitions de compilation malloc et free, voir
 * cmake/third_party.cmake) : chaque tampon est effacé avant d'être rendu au système. */
void *fl_scrypt_malloc(size_t n);
void fl_scrypt_free(void *p);

#endif

#define _POSIX_C_SOURCE 200809L
/* Phase 14, T1 : scrypt (fichier de référence de Tarsnap, PBKDF2-SHA256 de mbedTLS).
 * Vecteurs du § 12 du RFC 7914 ; le quatrième (N = 2^20, 1 Gio) seulement avec l'argument « lent ». */
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#include "crypto/fl_crypto.h"
#include "fluluks/error.h"
#include "tt.h"

static size_t unhex(const char *h, uint8_t *out, size_t max) {
  size_t n = strlen(h) / 2;
  if (n > max) return 0;
  for (size_t i = 0; i < n; i++) {
    unsigned v;
    if (sscanf(h + 2 * i, "%2x", &v) != 1) return 0;
    out[i] = (uint8_t)v;
  }
  return n;
}

static void verifier(const char *pw, const char *salt, uint8_t log2n, uint32_t r, uint32_t p, const char *hex) {
  uint8_t out[64], exp[64];
  TT_ASSERT_EQ(unhex(hex, exp, sizeof exp), 64);
  memset(out, 0xAA, sizeof out);
  TT_ASSERT_EQ(fl_scrypt(pw, strlen(pw), salt, strlen(salt), log2n, r, p, out, sizeof out), FL_OK);
  TT_ASSERT_MEM_EQ(out, exp, 64);
}

static void rfc7914Vectors(void) {
  verifier("", "", 4, 1, 1,
           "77d6576238657b203b19ca42c18a0497f16b4844e3074ae8dfdffa3fede21442"
           "fcd0069ded0948f8326a753a0fc81f17e8d3e0fb2e0d3628cf35e20c38d18906");
  verifier("password", "NaCl", 10, 8, 16,
           "fdbabe1c9d3472007856e7190d01e9fe7c6ad7cbc8237830e77376634b373162"
           "2eaf30d92e22a3886ff109279d9830dac727afb94a83ee6d8360cbdfa2cc0640");
  verifier("pleaseletmein", "SodiumChloride", 14, 8, 1,
           "7023bdcb3afd7348461c06cd81fd38ebfda8fbba904f8e3ea9b543f6545da1f2"
           "d5432955613f0fcf62d49705242a9af9e61e85dc0d651e40dfcf017b45575887");
}

static void rfc7914VectorLent(void) {
  verifier("pleaseletmein", "SodiumChloride", 20, 8, 1,
           "2101cb9b6a511aaeaddbbe09cf70f881ec568d574a2ffd4dabe5ee9820adaa47"
           "8e56fd8f4ba5d09ffa1c6d927c40f4c337304049e8a952fbcbf45c6fa77a41a4");
}

static void rejectsBadParams(void) {
  uint8_t out[32];
  TT_ASSERT_EQ(fl_scrypt("p", 1, "s", 1, 0, 8, 1, out, sizeof out), FL_EINVAL);
  TT_ASSERT_EQ(fl_scrypt("p", 1, "s", 1, 23, 8, 1, out, sizeof out), FL_EINVAL);
  TT_ASSERT_EQ(fl_scrypt("p", 1, "s", 1, 10, 0, 1, out, sizeof out), FL_EINVAL);
  TT_ASSERT_EQ(fl_scrypt("p", 1, "s", 1, 10, 8, 0, out, sizeof out), FL_EINVAL);
  TT_ASSERT_EQ(fl_scrypt("p", 1, "s", 1, 10, 8, 1, NULL, 32), FL_EINVAL);
  TT_ASSERT_EQ(fl_scrypt("p", 1, "s", 1, 10, 8, 1, out, 0), FL_EINVAL);
  TT_ASSERT_EQ(fl_scrypt("p", 1, "s", 1, 1, 1, 1, out, sizeof out), FL_OK);
}

/* Durée de scrypt au réglage de Portail (2^18, r = 8, p = 1 : 256 Mio), notée dans le registre. */
static void debitLog2n18(void) {
  uint8_t out[32];
  struct timespec a, b;
  clock_gettime(CLOCK_MONOTONIC, &a);
  TT_ASSERT_EQ(fl_scrypt("motdepasse", 10, "sel", 3, 18, 8, 1, out, sizeof out), FL_OK);
  clock_gettime(CLOCK_MONOTONIC, &b);
  fprintf(stderr, "scrypt 2^18 : %.2f s\n", (double)(b.tv_sec - a.tv_sec) + (double)(b.tv_nsec - a.tv_nsec) / 1e9);
}

int main(int argc, char **argv) {
  if (argc > 1 && strcmp(argv[1], "debit") == 0) {
    TT_RUN(debitLog2n18);
    TT_MAIN_END();
  }
  if (argc > 1 && strcmp(argv[1], "lent") == 0) {
    TT_RUN(rfc7914VectorLent);
    TT_MAIN_END();
  }
  TT_RUN(rfc7914Vectors);
  TT_RUN(rejectsBadParams);
  TT_MAIN_END();
}

/* Format age v1 : en-tête (destinataire scrypt), MAC, clés et morceaux. Spécification :
 * https://age-encryption.org/v1 (C2SP). Base64 sans remplissage, canonique ; lignes de corps de 64 colonnes. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <mbedtls/hkdf.h>
#include <mbedtls/md.h>

#include "age/age_internal.h"
#include "crypto/fl_crypto.h"
#include "fluluks/error.h"
#include "fluluks/format.h"
#include "fluluks/secure.h"

static const char INTRO[] = "age-encryption.org/v1\n";
static const char LABEL[] = "age-encryption.org/v1/scrypt";
#define LABEL_LEN 28
#define BODY_MAX 4096

/* --- Base64 standard, sans remplissage ------------------------------------------------------------ */
static const char B64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static int b64_val(uint8_t c) {
  if (c >= 'A' && c <= 'Z') return c - 'A';
  if (c >= 'a' && c <= 'z') return c - 'a' + 26;
  if (c >= '0' && c <= '9') return c - '0' + 52;
  if (c == '+') return 62;
  if (c == '/') return 63;
  return -1;
}

/* Décode `n` caractères ; canonique seulement (bits de bourrage nuls). Octets écrits, ou -1. */
static long b64_decode(const uint8_t *s, size_t n, uint8_t *out, size_t cap) {
  if (n % 4 == 1) return -1;
  size_t olen = n / 4 * 3 + (n % 4 ? n % 4 - 1 : 0);
  if (olen > cap) return -1;
  size_t o = 0;
  uint32_t acc = 0;
  int bits = 0;
  for (size_t i = 0; i < n; i++) {
    int v = b64_val(s[i]);
    if (v < 0) return -1;
    acc = (acc << 6) | (uint32_t)v;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out[o++] = (uint8_t)(acc >> bits);
      acc &= (1u << bits) - 1;
    }
  }
  if (acc != 0) return -1; /* bits restants non nuls : encodage non canonique */
  return (long)o;
}

static size_t b64_encode(const uint8_t *in, size_t n, char *out) {
  size_t o = 0;
  uint32_t acc = 0;
  int bits = 0;
  for (size_t i = 0; i < n; i++) {
    acc = (acc << 8) | in[i];
    bits += 8;
    while (bits >= 6) {
      bits -= 6;
      out[o++] = B64[(acc >> bits) & 63];
    }
  }
  if (bits > 0) out[o++] = B64[(acc << (6 - bits)) & 63];
  out[o] = 0;
  return o;
}

/* --- Analyse ---------------------------------------------------------------------------------------- */
static const uint8_t *fin_ligne(const uint8_t *p, const uint8_t *fin) { return memchr(p, '\n', (size_t)(fin - p)); }

int age_hdr_parse(const uint8_t *buf, size_t n, age_hdr *h) {
  memset(h, 0, sizeof *h);
  size_t il = sizeof INTRO - 1;
  if (n < il || memcmp(buf, INTRO, il) != 0) return FL_ENOTSUP;
  const uint8_t *p = buf + il, *end = buf + n;
  int stanzas = 0;
  /* Premier destinataire : type, arguments (positions dans buf), corps. */
  const uint8_t *arg[4] = {0};
  size_t arglen[4] = {0};
  int nargs = 0;
  uint8_t *body = malloc(BODY_MAX);
  long bodylen = 0;
  int rc = FL_ECORRUPT;
  if (!body) return FL_ENOMEM;
  for (;;) {
    const uint8_t *nl = fin_ligne(p, end);
    if (!nl) goto out;
    size_t l = (size_t)(nl - p);
    if (l >= 3 && memcmp(p, "---", 3) == 0) {
      if (l != 4 + 43 || p[3] != ' ') goto out;
      if (b64_decode(p + 4, 43, h->mac, sizeof h->mac) != 32) goto out;
      h->mac_input_len = (size_t)(p - buf) + 3;
      h->len = (size_t)(nl - buf) + 1;
      break;
    }
    if (l < 4 || memcmp(p, "-> ", 3) != 0) goto out;
    /* Arguments : séparés par une espace, non vides, caractères visibles. */
    int na = 0;
    const uint8_t *a = p + 3;
    while (a <= nl) {
      const uint8_t *e = a;
      while (e < nl && *e != ' ') {
        if (*e < 0x21 || *e > 0x7e) goto out;
        e++;
      }
      if (e == a) goto out;
      if (stanzas == 0 && na < 4) {
        arg[na] = a;
        arglen[na] = (size_t)(e - a);
      }
      na++;
      a = e + 1;
      if (e == nl) break;
    }
    if (stanzas == 0) nargs = na;
    /* Corps : lignes de 64 colonnes, la dernière plus courte (éventuellement vide). */
    p = nl + 1;
    uint8_t tmp[BODY_MAX * 2];
    size_t tl = 0;
    for (;;) {
      const uint8_t *nl2 = fin_ligne(p, end);
      if (!nl2) goto out;
      size_t l2 = (size_t)(nl2 - p);
      if (l2 > 64 || tl + l2 > sizeof tmp) goto out;
      memcpy(tmp + tl, p, l2);
      tl += l2;
      p = nl2 + 1;
      if (l2 < 64) break;
    }
    long bl = b64_decode(tmp, tl, body, BODY_MAX);
    if (bl < 0) goto out;
    if (stanzas == 0) bodylen = bl;
    stanzas++;
  }
  if (stanzas == 0) goto out;
  if (stanzas != 1 || arglen[0] != 6 || memcmp(arg[0], "scrypt", 6) != 0) {
    rc = FL_ENOTSUP;
    goto out;
  }
  if (nargs != 3 || bodylen != 32) goto out;
  if (b64_decode(arg[1], arglen[1], h->salt, sizeof h->salt) != 16) goto out;
  /* Facteur : décimal, sans zéro de tête ni signe, 1 à 99. */
  if (arglen[2] < 1 || arglen[2] > 2 || arg[2][0] == '0') goto out;
  unsigned wf = 0;
  for (size_t i = 0; i < arglen[2]; i++) {
    if (arg[2][i] < '0' || arg[2][i] > '9') goto out;
    wf = wf * 10 + (unsigned)(arg[2][i] - '0');
  }
  h->log2n = (uint8_t)wf;
  memcpy(h->body, body, 32); /* corps du destinataire unique, donc du dernier décodé */
  rc = FL_OK;
out:
  fl_memzero(body, BODY_MAX);
  free(body);
  return rc;
}

int age_pread_exact(const fl_arc_in *in, void *buf, size_t len, uint64_t off) {
  size_t done = 0;
  while (done < len) {
    int64_t k = in->pread(in->ctx, (uint8_t *)buf + done, len - done, off + done);
    if (k < 0) return (int)k;
    if (k == 0) return FL_ECORRUPT;
    done += (size_t)k;
  }
  return FL_OK;
}

int age_hdr_read(const fl_arc_in *in, uint8_t **buf, size_t *n, age_hdr *h) {
  *buf = NULL;
  *n = 0;
  if (!in || !in->pread || in->size < 0) return FL_EINVAL;
  size_t want = in->size < AGE_HDR_MAX ? (size_t)in->size : AGE_HDR_MAX;
  uint8_t *b = malloc(want ? want : 1);
  if (!b) return FL_ENOMEM;
  size_t got = 0;
  while (got < want) {
    int64_t k = in->pread(in->ctx, b + got, want - got, got);
    if (k < 0) {
      free(b);
      return (int)k;
    }
    if (k == 0) break;
    got += (size_t)k;
  }
  int rc = age_hdr_parse(b, got, h);
  if (rc != FL_OK) {
    free(b);
    return rc;
  }
  *buf = b;
  *n = got;
  return FL_OK;
}

/* --- Clés -------------------------------------------------------------------------------------------- */
static const mbedtls_md_info_t *sha256(void) { return mbedtls_md_info_from_type(MBEDTLS_MD_SHA256); }

/* Clé d'enveloppe : scrypt(mot de passe, LABEL ‖ sel, 2^log2n, 8, 1). */
static int wrap_key(const void *pass, size_t passlen, const uint8_t salt[16], uint8_t log2n, uint8_t *key) {
  uint8_t s[LABEL_LEN + 16];
  memcpy(s, LABEL, LABEL_LEN);
  memcpy(s + LABEL_LEN, salt, 16);
  return fl_scrypt(pass, passlen, s, sizeof s, log2n, 8, 1, key, 32);
}

static const uint8_t ZERO_NONCE[12];

/* MAC de l'en-tête : HMAC-SHA256(HKDF(fk, sel vide, « header »), octets). */
static int header_mac(const uint8_t fk[AGE_FILE_KEY], const uint8_t *data, size_t len, uint8_t mac[32]) {
  uint8_t *k = fl_secure_alloc(32);
  if (!k) return FL_ENOMEM;
  int rc = FL_EIO;
  if (mbedtls_hkdf(sha256(), NULL, 0, fk, AGE_FILE_KEY, (const unsigned char *)"header", 6, k, 32) == 0 &&
      mbedtls_md_hmac(sha256(), k, 32, data, len, mac) == 0)
    rc = FL_OK;
  fl_secure_free(k, 32);
  return rc;
}

int age_hdr_build(const uint8_t fk[AGE_FILE_KEY], const void *pass, size_t passlen, uint8_t log2n, uint8_t **out,
                  size_t *len) {
  *out = NULL;
  *len = 0;
  if (log2n < 1 || log2n > FL_AGE_LOG2N_MAX) return FL_EINVAL;
  uint8_t salt[16], body[32];
  int rc = fl_random(salt, sizeof salt);
  if (rc != FL_OK) return rc;
  uint8_t *wk = fl_secure_alloc(32);
  if (!wk) return FL_ENOMEM;
  rc = wrap_key(pass, passlen, salt, log2n, wk);
  if (rc == FL_OK) {
    mbedtls_chachapoly_context c;
    mbedtls_chachapoly_init(&c);
    if (mbedtls_chachapoly_setkey(&c, wk) != 0 ||
        mbedtls_chachapoly_encrypt_and_tag(&c, AGE_FILE_KEY, ZERO_NONCE, NULL, 0, fk, body, body + 16) != 0)
      rc = FL_EIO;
    mbedtls_chachapoly_free(&c);
  }
  fl_secure_free(wk, 32);
  if (rc != FL_OK) return rc;
  char s64[32], b64[48], m64[48];
  b64_encode(salt, 16, s64);
  b64_encode(body, 32, b64);
  size_t cap = 256;
  char *h = malloc(cap);
  if (!h) return FL_ENOMEM;
  int n = snprintf(h, cap, "%s-> scrypt %s %u\n%s\n---", INTRO, s64, (unsigned)log2n, b64);
  uint8_t mac[32];
  rc = header_mac(fk, (const uint8_t *)h, (size_t)n, mac);
  if (rc != FL_OK) {
    free(h);
    return rc;
  }
  b64_encode(mac, 32, m64);
  n += snprintf(h + n, cap - (size_t)n, " %s\n", m64);
  *out = (uint8_t *)h;
  *len = (size_t)n;
  return FL_OK;
}

int age_unwrap(const age_hdr *h, const uint8_t *hdr_bytes, const void *pass, size_t passlen, uint8_t max_log2n,
               uint8_t fk[AGE_FILE_KEY]) {
  if (max_log2n > FL_AGE_LOG2N_MAX) max_log2n = FL_AGE_LOG2N_MAX;
  if (h->log2n > max_log2n) return FL_ENOMEM;
  uint8_t *wk = fl_secure_alloc(32);
  if (!wk) return FL_ENOMEM;
  int rc = wrap_key(pass, passlen, h->salt, h->log2n, wk);
  if (rc == FL_OK) {
    mbedtls_chachapoly_context c;
    mbedtls_chachapoly_init(&c);
    if (mbedtls_chachapoly_setkey(&c, wk) != 0)
      rc = FL_EIO;
    else if (mbedtls_chachapoly_auth_decrypt(&c, AGE_FILE_KEY, ZERO_NONCE, NULL, 0, h->body + 16, h->body, fk) != 0)
      rc = FL_EBADPASS;
    mbedtls_chachapoly_free(&c);
  }
  fl_secure_free(wk, 32);
  if (rc != FL_OK) {
    fl_memzero(fk, AGE_FILE_KEY);
    return rc;
  }
  uint8_t mac[32];
  rc = header_mac(fk, hdr_bytes, h->mac_input_len, mac);
  if (rc == FL_OK) {
    uint8_t diff = 0;
    for (int i = 0; i < 32; i++) diff |= (uint8_t)(mac[i] ^ h->mac[i]);
    if (diff) rc = FL_ECORRUPT;
  }
  if (rc != FL_OK) fl_memzero(fk, AGE_FILE_KEY);
  return rc;
}

int age_payload_key(const uint8_t fk[AGE_FILE_KEY], const uint8_t nonce[AGE_NONCE], uint8_t key[32]) {
  return mbedtls_hkdf(sha256(), nonce, AGE_NONCE, fk, AGE_FILE_KEY, (const unsigned char *)"payload", 7, key, 32) == 0
             ? FL_OK
             : FL_EIO;
}

/* --- Morceaux ------------------------------------------------------------------------------------------ */
static void chunk_nonce(uint64_t idx, bool last, uint8_t n[12]) {
  memset(n, 0, 12);
  for (int i = 0; i < 8; i++) n[10 - i] = (uint8_t)(idx >> (8 * i));
  n[11] = last ? 1 : 0;
}

int age_chunk_seal(mbedtls_chachapoly_context *c, uint64_t idx, bool last, const uint8_t *in, size_t len,
                   uint8_t *out) {
  uint8_t n[12];
  chunk_nonce(idx, last, n);
  return mbedtls_chachapoly_encrypt_and_tag(c, len, n, NULL, 0, in, out, out + len) == 0 ? FL_OK : FL_EIO;
}

int age_chunk_open(mbedtls_chachapoly_context *c, uint64_t idx, bool last, const uint8_t *in, size_t ctlen,
                   uint8_t *out) {
  if (ctlen < AGE_TAG) return FL_ECORRUPT;
  uint8_t n[12];
  chunk_nonce(idx, last, n);
  size_t len = ctlen - AGE_TAG;
  if (mbedtls_chachapoly_auth_decrypt(c, len, n, NULL, 0, in + len, in, out) != 0) {
    fl_memzero(out, len);
    return FL_ECORRUPT;
  }
  return FL_OK;
}

int age_layout_of(int64_t ct, age_layout *l) {
  if (ct < AGE_TAG) return FL_ECORRUPT;
  uint64_t c = (uint64_t)ct;
  l->chunks = (c + AGE_FULL - 1) / AGE_FULL;
  l->last_len = (size_t)(c - (l->chunks - 1) * AGE_FULL);
  if (l->last_len < AGE_TAG) return FL_ECORRUPT;
  if (l->last_len == AGE_TAG && l->chunks > 1) return FL_ECORRUPT; /* dernier morceau vide : fichier vide seul */
  l->plain = (int64_t)(c - AGE_TAG * l->chunks);
  return FL_OK;
}

int fl_age_peek(const fl_arc_in *in, uint8_t *log2n) {
  uint8_t *b;
  size_t n;
  age_hdr h;
  int rc = age_hdr_read(in, &b, &n, &h);
  if (rc == FL_OK) {
    free(b);
    if (log2n) *log2n = h.log2n;
    return 1;
  }
  if (rc == FL_ENOTSUP || rc == FL_ECORRUPT) return 0;
  return rc;
}

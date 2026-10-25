/* Écrivain age v1 en flux : en-tête scrypt, nonce, puis morceaux de 64 Kio. Le dernier morceau plein est
 * gardé jusqu'à savoir s'il est le dernier (drapeau de fin). */
#include <stdlib.h>
#include <string.h>

#include "age/age_internal.h"
#include "fluluks/error.h"
#include "fluluks/format.h"
#include "fluluks/secure.h"

struct fl_agew {
  fl_arc_out out;
  mbedtls_chachapoly_context *c; /* clé de charge posée ; mémoire sécurisée */
  uint8_t *pk;                   /* clé de charge (32), mémoire sécurisée */
  uint8_t *buf;                  /* clair en attente (AGE_CHUNK), mémoire sécurisée */
  uint8_t *ct;                   /* chiffré d'un morceau (AGE_FULL) */
  size_t fill;
  uint64_t idx;
  int err;
};

static void liberer(fl_agew *w) {
  if (!w) return;
  if (w->c) {
    mbedtls_chachapoly_free(w->c);
    fl_secure_free(w->c, sizeof *w->c);
  }
  fl_secure_free(w->pk, 32);
  fl_secure_free(w->buf, AGE_CHUNK);
  free(w->ct);
  free(w);
}

int fl_agew_open(const fl_arc_out *out, const void *pass, size_t passlen, uint8_t log2n, fl_agew **wp) {
  if (!wp) return FL_EINVAL;
  *wp = NULL;
  if (!out || !out->write || (!pass && passlen) || log2n < 1 || log2n > FL_AGE_LOG2N_MAX) return FL_EINVAL;
  fl_agew *w = calloc(1, sizeof *w);
  if (!w) return FL_ENOMEM;
  w->out = *out;
  w->c = fl_secure_alloc(sizeof *w->c);
  w->pk = fl_secure_alloc(32);
  w->buf = fl_secure_alloc(AGE_CHUNK);
  w->ct = malloc(AGE_FULL);
  uint8_t *fk = fl_secure_alloc(AGE_FILE_KEY);
  uint8_t *hdr = NULL;
  size_t hlen = 0;
  uint8_t nonce[AGE_NONCE];
  int rc = (w->c && w->pk && w->buf && w->ct && fk) ? FL_OK : FL_ENOMEM;
  if (rc == FL_OK) rc = fl_random(fk, AGE_FILE_KEY);
  if (rc == FL_OK) rc = fl_random(nonce, sizeof nonce);
  if (rc == FL_OK) rc = age_hdr_build(fk, pass, passlen, log2n, &hdr, &hlen);
  if (rc == FL_OK) rc = age_payload_key(fk, nonce, w->pk);
  fl_secure_free(fk, AGE_FILE_KEY);
  if (rc == FL_OK) {
    mbedtls_chachapoly_init(w->c);
    if (mbedtls_chachapoly_setkey(w->c, w->pk) != 0) rc = FL_EIO;
  }
  if (rc == FL_OK) rc = w->out.write(w->out.ctx, hdr, hlen);
  if (rc == FL_OK) rc = w->out.write(w->out.ctx, nonce, sizeof nonce);
  free(hdr);
  if (rc != FL_OK) {
    liberer(w);
    return rc;
  }
  *wp = w;
  return FL_OK;
}

static int emettre(fl_agew *w, bool last) {
  int rc = age_chunk_seal(w->c, w->idx, last, w->buf, w->fill, w->ct);
  if (rc == FL_OK) rc = w->out.write(w->out.ctx, w->ct, w->fill + AGE_TAG);
  if (rc != FL_OK) {
    w->err = rc;
    return rc;
  }
  w->idx++;
  w->fill = 0;
  return FL_OK;
}

int fl_agew_write(fl_agew *w, const void *buf, size_t len) {
  if (!w || (!buf && len)) return FL_EINVAL;
  if (w->err) return w->err;
  const uint8_t *p = buf;
  while (len) {
    if (w->fill == AGE_CHUNK) {
      int rc = emettre(w, false);
      if (rc != FL_OK) return rc;
    }
    size_t k = AGE_CHUNK - w->fill < len ? AGE_CHUNK - w->fill : len;
    memcpy(w->buf + w->fill, p, k);
    w->fill += k;
    p += k;
    len -= k;
  }
  return FL_OK;
}

int fl_agew_close(fl_agew *w, bool commit) {
  if (!w) return FL_EINVAL;
  int rc = w->err;
  if (commit && rc == FL_OK) rc = emettre(w, true);
  liberer(w);
  return rc;
}

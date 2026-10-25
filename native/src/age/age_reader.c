/* Lecteur age v1 à accès aléatoire : chaque lecture déchiffre et authentifie les morceaux touchés (un
 * morceau en cache). Le dernier morceau est vérifié à l'ouverture : une troncature est refusée d'emblée. */
#include <stdlib.h>
#include <string.h>

#include "age/age_internal.h"
#include "fluluks/error.h"
#include "fluluks/secure.h"

struct fl_ager {
  const fl_arc_in *in;
  uint64_t payload_off; /* premier morceau */
  age_layout lay;
  mbedtls_chachapoly_context *c;
  uint8_t *pk;    /* clé de charge (32), mémoire sécurisée */
  uint8_t *cache; /* clair du morceau `cached` (AGE_CHUNK), mémoire sécurisée */
  uint8_t *ct;
  int64_t cached; /* -1 : aucun */
};

static void liberer(fl_ager *r) {
  if (!r) return;
  if (r->c) {
    mbedtls_chachapoly_free(r->c);
    fl_secure_free(r->c, sizeof *r->c);
  }
  fl_secure_free(r->pk, 32);
  fl_secure_free(r->cache, AGE_CHUNK);
  free(r->ct);
  free(r);
}

/* Charge le morceau idx dans le cache. */
static int charger(fl_ager *r, uint64_t idx) {
  if (r->cached == (int64_t)idx) return FL_OK;
  r->cached = -1;
  bool last = idx == r->lay.chunks - 1;
  size_t ctlen = last ? r->lay.last_len : AGE_FULL;
  int rc = age_pread_exact(r->in, r->ct, ctlen, r->payload_off + idx * AGE_FULL);
  if (rc != FL_OK) return rc;
  rc = age_chunk_open(r->c, idx, last, r->ct, ctlen, r->cache);
  if (rc != FL_OK) return rc;
  r->cached = (int64_t)idx;
  return FL_OK;
}

/* Ouverture commune au lecteur et au changement de mot de passe : copie aussi la clé de fichier si fk_out. */
static int open_fk(const fl_arc_in *in, const void *pass, size_t passlen, uint8_t max_log2n, fl_ager **rp,
                   uint8_t *fk_out) {
  *rp = NULL;
  if (!in || !in->pread || in->size < 0 || (!pass && passlen)) return FL_EINVAL;
  uint8_t *hb;
  size_t hn;
  age_hdr h;
  int rc = age_hdr_read(in, &hb, &hn, &h);
  if (rc != FL_OK) return rc;
  fl_ager *r = calloc(1, sizeof *r);
  uint8_t *fk = fl_secure_alloc(AGE_FILE_KEY);
  if (r) {
    r->in = in;
    r->cached = -1;
    r->c = fl_secure_alloc(sizeof *r->c);
    r->pk = fl_secure_alloc(32);
    r->cache = fl_secure_alloc(AGE_CHUNK);
    r->ct = malloc(AGE_FULL);
  }
  rc = (r && fk && r->c && r->pk && r->cache && r->ct) ? FL_OK : FL_ENOMEM;
  if (rc == FL_OK) rc = age_unwrap(&h, hb, pass, passlen, max_log2n, fk);
  uint8_t nonce[AGE_NONCE];
  if (rc == FL_OK) rc = age_pread_exact(in, nonce, sizeof nonce, h.len);
  if (rc == FL_OK) {
    r->payload_off = h.len + AGE_NONCE;
    rc = age_layout_of(in->size - (int64_t)r->payload_off, &r->lay);
  }
  if (rc == FL_OK) rc = age_payload_key(fk, nonce, r->pk);
  if (rc == FL_OK) {
    mbedtls_chachapoly_init(r->c);
    if (mbedtls_chachapoly_setkey(r->c, r->pk) != 0) rc = FL_EIO;
  }
  if (rc == FL_OK) rc = charger(r, r->lay.chunks - 1); /* troncature et dernier morceau */
  if (rc == FL_OK && fk_out) memcpy(fk_out, fk, AGE_FILE_KEY);
  fl_secure_free(fk, AGE_FILE_KEY);
  free(hb);
  if (rc != FL_OK) {
    liberer(r);
    return rc;
  }
  *rp = r;
  return FL_OK;
}

int fl_ager_open(const fl_arc_in *in, const void *pass, size_t passlen, uint8_t max_log2n, fl_ager **rp) {
  if (!rp) return FL_EINVAL;
  return open_fk(in, pass, passlen, max_log2n, rp, NULL);
}

int64_t fl_ager_size(const fl_ager *r) { return r ? r->lay.plain : FL_EINVAL; }

int64_t fl_ager_pread(fl_ager *r, void *buf, size_t len, uint64_t off) {
  if (!r || (!buf && len)) return FL_EINVAL;
  uint64_t size = (uint64_t)r->lay.plain;
  if (off >= size || len == 0) return 0;
  if (len > size - off) len = (size_t)(size - off);
  size_t done = 0;
  while (done < len) {
    uint64_t pos = off + done, idx = pos / AGE_CHUNK;
    int rc = charger(r, idx);
    if (rc != FL_OK) return rc;
    size_t in_chunk = (size_t)(pos - idx * AGE_CHUNK);
    size_t avail = (idx == r->lay.chunks - 1 ? r->lay.last_len - AGE_TAG : AGE_CHUNK) - in_chunk;
    size_t k = len - done < avail ? len - done : avail;
    memcpy((uint8_t *)buf + done, r->cache + in_chunk, k);
    done += k;
  }
  return (int64_t)done;
}

void fl_ager_close(fl_ager *r) { liberer(r); }

/* Changement de mot de passe : nouvel en-tête pour la même clé de fichier, charge recopiée et vérifiée. */
int fl_age_rewrap(const fl_arc_in *in, const fl_arc_out *out, const void *old, size_t oldlen, const void *nw,
                  size_t nwlen, uint8_t log2n) {
  if (!in || !out || !out->write || (!nw && nwlen) || log2n < 1 || log2n > FL_AGE_LOG2N_MAX) return FL_EINVAL;
  fl_ager *r = NULL;
  uint8_t *fk = fl_secure_alloc(AGE_FILE_KEY);
  if (!fk) return FL_ENOMEM;
  int rc = open_fk(in, old, oldlen, FL_AGE_LOG2N_MAX, &r, fk);
  uint8_t *hdr = NULL;
  size_t hlen = 0;
  if (rc == FL_OK) rc = age_hdr_build(fk, nw, nwlen, log2n, &hdr, &hlen);
  fl_secure_free(fk, AGE_FILE_KEY);
  uint8_t nonce[AGE_NONCE];
  if (rc == FL_OK) rc = age_pread_exact(in, nonce, sizeof nonce, r->payload_off - AGE_NONCE);
  if (rc == FL_OK) rc = out->write(out->ctx, hdr, hlen);
  if (rc == FL_OK) rc = out->write(out->ctx, nonce, sizeof nonce);
  free(hdr);
  /* Morceaux recopiés tels quels, chacun authentifié au passage. */
  for (uint64_t i = 0; rc == FL_OK && i < r->lay.chunks; i++) {
    bool last = i == r->lay.chunks - 1;
    size_t ctlen = last ? r->lay.last_len : AGE_FULL;
    r->cached = -1;
    rc = age_pread_exact(in, r->ct, ctlen, r->payload_off + i * AGE_FULL);
    if (rc == FL_OK) rc = age_chunk_open(r->c, i, last, r->ct, ctlen, r->cache);
    if (rc == FL_OK) rc = out->write(out->ctx, r->ct, ctlen);
  }
  liberer(r);
  return rc;
}

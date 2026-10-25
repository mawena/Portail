/* Emplacements de clé LUKS2 (phase 14) : créer, remplacer, retirer, comme `cryptsetup luksAddKey`,
 * `luksChangeKey` et `luksKillSlot`.
 *
 * Tout est vérifié avant la première écriture : arguments, en-tête (relu ici, celui au seqid le plus grand),
 * phrase `auth` (clé maîtresse vérifiée par son condensé, gardée en mémoire sécurisée, jamais rendue),
 * place dans la zone des emplacements et dans la zone JSON. Puis, chaque écriture vidée : zone de clé neuve
 * (dans un espace libre pour les deux en-têtes), en-tête primaire, en-tête secondaire (seqid + 1, même
 * JSON), enfin effacement de l'ancienne zone. Une coupure laisse donc toujours un en-tête valable dont les
 * emplacements ont leur zone intacte : avant l'en-tête primaire, l'ancien JSON ; après, le nouveau (le
 * seqid plus grand gagne, et l'en-tête secondaire, encore ancien, ne sert que si le primaire est abîmé). */
#define _DEFAULT_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "cJSON.h"
#include "crypto/fl_crypto.h"
#include "fluluks/error.h"
#include "fluluks/format.h"
#include "fluluks/luks.h"
#include "fluluks/secure.h"
#include "format/format_internal.h"
#include "luks/luks2_internal.h"
#include "luks/luks_internal.h"

#define BIN 4096u
#define MAX_SLOT_ID 32
#define STRIPES 4000u
#define ALIGN 4096u
#define SALT 32u
#define AREA_KEY 64u
#define CPUS 4u
#define MAX_ARGON2_KIB 4194304u
#define CIPHER "aes-xts-plain64"

static void wr64(uint8_t *p, uint64_t v) {
  for (int i = 0; i < 8; i++) p[i] = (uint8_t)(v >> (56 - 8 * i));
}

static void b64(const uint8_t *in, size_t n, char *out) {
  static const char t[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  size_t o = 0;
  for (size_t i = 0; i < n; i += 3) {
    uint32_t v = (uint32_t)in[i] << 16 | (i + 1 < n ? (uint32_t)in[i + 1] << 8 : 0) | (i + 2 < n ? in[i + 2] : 0);
    out[o++] = t[v >> 18 & 63];
    out[o++] = t[v >> 12 & 63];
    out[o++] = i + 1 < n ? t[v >> 6 & 63] : '=';
    out[o++] = i + 2 < n ? t[v & 63] : '=';
  }
  out[o] = 0;
}

static uint64_t round_up(uint64_t v, uint64_t a) { return (v + a - 1) / a * a; }

static cJSON *child(const cJSON *o, const char *k) { return cJSON_GetObjectItemCaseSensitive((cJSON *)o, k); }

/* Décimal strict (chaîne JSON). */
static int dec(const cJSON *o, const char *k, uint64_t *out) {
  const cJSON *m = child(o, k);
  if (!cJSON_IsString(m) || !m->valuestring || !*m->valuestring) return FL_ECORRUPT;
  uint64_t v = 0;
  for (const char *s = m->valuestring; *s; s++) {
    if (*s < '0' || *s > '9') return FL_ECORRUPT;
    uint64_t d = (uint64_t)(*s - '0');
    if (v > (UINT64_MAX - d) / 10) return FL_ECORRUPT;
    v = v * 10 + d;
  }
  *out = v;
  return FL_OK;
}

typedef struct {
  luks2 *x;
  l2_hdrs h;
  cJSON *root;  /* JSON de l'en-tête retenu, modifié ici */
  cJSON *other; /* JSON de l'autre en-tête valide, ou NULL : ses zones restent réservées */
  uint64_t hs;  /* taille d'un en-tête */
  uint64_t ks_start, ks_end;
  uint8_t *mk;
  size_t mkl;
  int digest;
} ctx;

static void ctx_free(ctx *c) {
  cJSON_Delete(c->root);
  cJSON_Delete(c->other);
  fl_luks2_hdrs_free(&c->h);
  if (c->x) {
    fl_memzero(c->x, sizeof *c->x);
    free(c->x);
  }
  if (c->mk) fl_secure_free(c->mk, 64);
  memset(c, 0, sizeof *c);
}

/* Relit l'en-tête ; FL_ENOTSUP pour LUKS1 ou une disposition que ce code ne réécrit pas. */
static int begin(fl_bdev *dev, ctx *c) {
  memset(c, 0, sizeof *c);
  c->h.cur = -1;
  bool magic = false;
  int ver = 0;
  int rc = fl_luks_peek(dev, &magic, &ver);
  if (rc != FL_OK) return rc;
  if (magic && ver == 1) return FL_ENOTSUP;
  c->x = calloc(1, sizeof *c->x);
  if (!c->x) return FL_ENOMEM;
  rc = fl_luks2_load(dev, magic && ver == 2, &c->h, c->x);
  if (rc != FL_OK) return rc;
  const l2_img *cur = &c->h.hdr[c->h.cur], *oth = &c->h.hdr[1 - c->h.cur];
  c->hs = cur->size;
  c->root = fl_luks2_cjson_parse((const char *)cur->buf + BIN);
  if (!c->root) return FL_ECORRUPT;
  if (oth->buf) c->other = fl_luks2_cjson_parse((const char *)oth->buf + BIN);
  uint64_t json_size = 0, ks_size = 0;
  const cJSON *cfg = child(c->root, "config");
  if (dec(cfg, "json_size", &json_size) != FL_OK || dec(cfg, "keyslots_size", &ks_size) != FL_OK) return FL_ENOTSUP;
  if (json_size != c->hs - BIN || c->hs % dev->sector_size || !cJSON_IsObject(child(c->root, "keyslots")) ||
      !cJSON_IsObject(child(c->root, "digests")))
    return FL_ENOTSUP;
  c->ks_start = 2 * c->hs;
  if (ks_size > UINT64_MAX - c->ks_start) return FL_ECORRUPT;
  c->ks_end = c->ks_start + ks_size;
  if (c->ks_end > c->x->seg_off) return FL_ENOTSUP; /* zone des emplacements sur les données */
  return FL_OK;
}

static int authenticate(fl_bdev *dev, ctx *c, const void *auth, size_t authlen) {
  c->mk = fl_secure_alloc(64);
  if (!c->mk) return FL_ENOMEM;
  return fl_luks2_recover_mk(dev, c->x, -1, auth, authlen, c->mk, &c->mkl, &c->digest);
}

typedef struct {
  uint64_t off, end;
} span;

/* Zones des emplacements d'un JSON. strict : une zone illisible est une erreur (sinon ignorée). */
static int spans(const cJSON *root, span *sp, int *n, int cap, bool strict) {
  const cJSON *e;
  cJSON_ArrayForEach(e, child(root, "keyslots")) {
    const cJSON *ar = child(e, "area");
    uint64_t off, size;
    if (dec(ar, "offset", &off) != FL_OK || dec(ar, "size", &size) != FL_OK || size > UINT64_MAX - off) {
      if (strict) return FL_ENOTSUP;
      continue;
    }
    if (*n >= cap) return FL_ENOTSUP;
    sp[(*n)++] = (span){off, off + size};
  }
  return FL_OK;
}

/* Premier espace libre de `len` octets, aligné sur 4 Kio, dans la zone des emplacements. */
static int find_free(const ctx *c, uint64_t len, uint64_t *out) {
  span sp[2 * L2_MAX_SLOTS];
  int n = 0;
  int rc = spans(c->root, sp, &n, 2 * L2_MAX_SLOTS, true);
  if (rc == FL_OK && c->other) rc = spans(c->other, sp, &n, 2 * L2_MAX_SLOTS, false);
  if (rc != FL_OK) return rc;
  uint64_t off = round_up(c->ks_start, ALIGN);
  for (bool moved = true; moved;) {
    moved = false;
    if (off > c->ks_end || len > c->ks_end - off) return FL_ENOSPC;
    for (int i = 0; i < n; i++)
      if (sp[i].off < off + len && off < sp[i].end) {
        off = round_up(sp[i].end, ALIGN);
        moved = true;
      }
  }
  *out = off;
  return FL_OK;
}

/* Zone d'un emplacement du JSON retenu ; FL_ENOENT s'il n'existe pas. */
static int slot_area(const ctx *c, const char *id, uint64_t *off, uint64_t *size) {
  const cJSON *ks = child(child(c->root, "keyslots"), id);
  if (!ks) return FL_ENOENT;
  const cJSON *ar = child(ks, "area");
  if (dec(ar, "offset", off) != FL_OK || dec(ar, "size", size) != FL_OK) return FL_ENOTSUP;
  return FL_OK;
}

static void array_remove(cJSON *arr, const char *id) {
  if (!cJSON_IsArray(arr)) return;
  for (int i = cJSON_GetArraySize(arr) - 1; i >= 0; i--) {
    const cJSON *e = cJSON_GetArrayItem(arr, i);
    if (cJSON_IsString(e) && e->valuestring && !strcmp(e->valuestring, id)) cJSON_DeleteItemFromArray(arr, i);
  }
}

static uint64_t id_num(const char *s) { return s ? strtoull(s, NULL, 10) : UINT64_MAX; }

/* Emplacements rangés par numéro : l'ordre d'essai sans emplacement désigné reste 0, 1, 2… */
static void sort_keyslots(cJSON *ks) {
  cJSON *items[L2_MAX_SLOTS + 1];
  int n = 0;
  while (ks->child && n < L2_MAX_SLOTS + 1) items[n++] = cJSON_DetachItemViaPointer(ks, ks->child);
  for (int i = 1; i < n; i++) {
    cJSON *t = items[i];
    int j = i - 1;
    while (j >= 0 && id_num(items[j]->string) > id_num(t->string)) {
      items[j + 1] = items[j];
      j--;
    }
    items[j + 1] = t;
  }
  for (int i = 0; i < n; i++) cJSON_AddItemToArray(ks, items[i]); /* garde la clé (item->string) */
}

/* JSON sérialisé, ou FL_ENOSPC s'il ne tient pas dans la zone JSON (NUL compris). */
static int serialize(const ctx *c, char **out) {
  char *s = cJSON_PrintUnformatted(c->root);
  if (!s) return FL_ENOMEM;
  if (strlen(s) >= c->hs - BIN) {
    cJSON_free(s);
    return FL_ENOSPC;
  }
  *out = s;
  return FL_OK;
}

/* En-tête primaire puis secondaire (à hs), seqid + 1, chacun vidé. */
static int write_hdrs(fl_bdev *dev, const ctx *c, const char *json) {
  const l2_img *cur = &c->h.hdr[c->h.cur];
  uint64_t seq = cur->seqid;
  for (int i = 0; i < 2; i++)
    if (c->h.hdr[i].buf && c->h.hdr[i].seqid > seq) seq = c->h.hdr[i].seqid;
  seq++;
  uint8_t salts[128];
  uint8_t *h = malloc((size_t)c->hs);
  int rc = h ? fl_random(salts, sizeof salts) : FL_ENOMEM;
  size_t len = strlen(json);
  for (int i = 0; rc == FL_OK && i < 2; i++) {
    uint64_t off = i ? c->hs : 0;
    memset(h, 0, (size_t)c->hs);
    memcpy(h, cur->buf, BIN); /* version, taille, étiquette, algorithme de somme, UUID, sous-système */
    memcpy(h, i ? "SKUL\xBA\xBE" : "LUKS\xBA\xBE", 6);
    wr64(h + 16, seq);
    memcpy(h + 104, salts + 64 * i, 64);
    wr64(h + 256, off);
    memset(h + 448, 0, 64);
    memset(h + 512, 0, BIN - 512);
    memcpy(h + BIN, json, len);
    rc = fl_hash("sha256", h, (size_t)c->hs, h + 448);
    if (rc == FL_OK) rc = fl_bdev_write(dev, off / dev->sector_size, (uint32_t)(c->hs / dev->sector_size), h);
    if (rc == FL_OK) rc = fl_bdev_flush(dev);
  }
  free(h);
  return rc;
}

static int wipe(fl_bdev *dev, uint64_t off, uint64_t size) {
  uint32_t ss = dev->sector_size;
  if (off % ss || size % ss) return FL_OK; /* zone non alignée : laissée telle quelle */
  int rc = fl_fmt_zero(dev, off / ss, size / ss);
  return rc == FL_OK ? fl_bdev_flush(dev) : rc;
}

int fl_luks2_slot_set(fl_bdev *dev, int slot, const void *auth, size_t authlen, const void *nw, size_t nwlen,
                      uint32_t kdf_mem_kib, uint32_t kdf_time) {
  if (!dev || slot < 0 || slot >= MAX_SLOT_ID || (!auth && authlen) || !nw || nwlen == 0 || kdf_mem_kib < 8192 ||
      kdf_mem_kib > MAX_ARGON2_KIB || kdf_time < 1 || kdf_time > 1000)
    return FL_EINVAL;
  if (dev->read_only) return FL_EROFS;
  ctx c;
  int rc = begin(dev, &c);
  if (rc == FL_OK) rc = authenticate(dev, &c, auth, authlen);
  char id[12];
  snprintf(id, sizeof id, "%d", slot);
  uint64_t old_off = 0, old_size = 0;
  bool replace = false;
  if (rc == FL_OK) {
    rc = slot_area(&c, id, &old_off, &old_size);
    replace = rc == FL_OK;
    if (rc == FL_ENOENT) rc = FL_OK;
  }
  size_t mkl = c.mkl, aflen = mkl * STRIPES;
  uint64_t alen = round_up(aflen, ALIGN), off = 0;
  if (rc == FL_OK && (aflen % 512 || alen % dev->sector_size)) rc = FL_ENOTSUP;
  if (rc == FL_OK) rc = find_free(&c, alen, &off);

  /* aléa : sel de l'emplacement, bandes AF */
  size_t rlen = SALT + (STRIPES - 1) * mkl;
  uint8_t *r = rc == FL_OK ? fl_secure_alloc(rlen) : NULL;
  uint8_t *k = rc == FL_OK ? fl_secure_alloc(AREA_KEY) : NULL;
  uint8_t *af = rc == FL_OK ? fl_secure_alloc(aflen) : NULL;
  uint8_t *enc = rc == FL_OK ? calloc(1, (size_t)alen) : NULL;
  char *json = NULL;
  fl_sector_cipher *cph = NULL;
  if (rc == FL_OK && (!r || !k || !af || !enc)) rc = FL_ENOMEM;
  if (rc == FL_OK) rc = fl_random(r, rlen);

  /* nouveau JSON, vérifié avant toute écriture */
  if (rc == FL_OK) {
    char salt[64], js[1024];
    b64(r, SALT, salt);
    int n = snprintf(js, sizeof js,
                     "{\"type\":\"luks2\",\"key_size\":%zu,\"af\":{\"type\":\"luks1\",\"stripes\":%u,\"hash\":"
                     "\"sha256\"},\"area\":{\"type\":\"raw\",\"offset\":\"%llu\",\"size\":\"%llu\",\"encryption\":\""
                     CIPHER "\",\"key_size\":%u},\"kdf\":{\"type\":\"argon2id\",\"time\":%u,\"memory\":%u,"
                     "\"cpus\":%u,\"salt\":\"%s\"}}",
                     mkl, STRIPES, (unsigned long long)off, (unsigned long long)alen, AREA_KEY, kdf_time, kdf_mem_kib,
                     CPUS, salt);
    cJSON *item = n > 0 && n < (int)sizeof js ? fl_luks2_cjson_parse(js) : NULL;
    cJSON *keyslots = child(c.root, "keyslots");
    if (!item) rc = FL_ENOMEM;
    if (rc == FL_OK) {
      cJSON_DeleteItemFromObjectCaseSensitive(keyslots, id);
      cJSON_AddItemToObject(keyslots, id, item);
      sort_keyslots(keyslots);
      if (cJSON_GetArraySize(keyslots) > L2_MAX_SLOTS) rc = FL_ENOSPC;
    }
    /* lié au digest qui a vérifié la clé maîtresse, et à lui seul */
    int i = 0;
    cJSON *d;
    cJSON_ArrayForEach(d, child(c.root, "digests")) {
      if (rc != FL_OK) break;
      cJSON *arr = child(d, "keyslots");
      array_remove(arr, id);
      if (i++ == c.digest) {
        if (!cJSON_IsArray(arr)) rc = FL_ECORRUPT;
        else cJSON_AddItemToArray(arr, cJSON_CreateString(id));
      }
    }
    if (rc == FL_OK) rc = serialize(&c, &json);
  }

  /* zone de clé : Argon2id de la nouvelle phrase, bandes AF de la clé maîtresse, chiffrées */
  if (rc == FL_OK) rc = fl_argon2(FL_ARGON2ID, nw, nwlen, r, SALT, kdf_time, kdf_mem_kib, CPUS, k, AREA_KEY);
  if (rc == FL_OK) rc = fl_af_split("sha256", c.mk, mkl, STRIPES, r + SALT, af);
  if (rc == FL_OK) rc = fl_sector_cipher_new(CIPHER, k, AREA_KEY, 512, &cph);
  if (rc == FL_OK) rc = fl_sector_encrypt(cph, 0, af, enc, aflen);
  uint32_t ss = dev->sector_size;
  if (rc == FL_OK) rc = fl_bdev_write(dev, off / ss, (uint32_t)(alen / ss), enc);
  if (rc == FL_OK) rc = fl_bdev_flush(dev);
  if (rc == FL_OK) rc = write_hdrs(dev, &c, json);
  if (rc == FL_OK && replace) rc = wipe(dev, old_off, old_size);

  fl_sector_cipher_free(cph);
  if (r) fl_secure_free(r, rlen);
  if (k) fl_secure_free(k, AREA_KEY);
  if (af) fl_secure_free(af, aflen);
  free(enc);
  cJSON_free(json);
  ctx_free(&c);
  return rc;
}

int fl_luks2_slot_remove(fl_bdev *dev, int slot, const void *auth, size_t authlen) {
  if (!dev || slot < 0 || slot >= MAX_SLOT_ID || (!auth && authlen)) return FL_EINVAL;
  if (dev->read_only) return FL_EROFS;
  ctx c;
  int rc = begin(dev, &c);
  char id[12];
  snprintf(id, sizeof id, "%d", slot);
  uint64_t off = 0, size = 0;
  if (rc == FL_OK) rc = slot_area(&c, id, &off, &size);
  if (rc == FL_OK) {
    /* au moins un autre emplacement utilisable reste lié aux données */
    bool other = false;
    for (int i = 0; i < c.x->nslots; i++) {
      const l2_slot *s = &c.x->slots[i];
      other |= s->id != (uint32_t)slot && s->supported && s->priority != 0 && s->digest >= 0;
    }
    if (!other) rc = FL_EBUSY;
  }
  if (rc == FL_OK) rc = authenticate(dev, &c, auth, authlen);
  char *json = NULL;
  if (rc == FL_OK) {
    cJSON_DeleteItemFromObjectCaseSensitive(child(c.root, "keyslots"), id);
    cJSON *e;
    cJSON_ArrayForEach(e, child(c.root, "digests")) array_remove(child(e, "keyslots"), id);
    cJSON_ArrayForEach(e, child(c.root, "tokens")) array_remove(child(e, "keyslots"), id);
    rc = serialize(&c, &json);
  }
  if (rc == FL_OK) rc = write_hdrs(dev, &c, json);
  if (rc == FL_OK) rc = wipe(dev, off, size);
  cJSON_free(json);
  ctx_free(&c);
  return rc;
}

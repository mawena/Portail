#define _GNU_SOURCE
/* Phase 14, T1 : format age v1 (destinataire scrypt), en flux et à accès aléatoire.
 * Juges : le juge Python indépendant (tools/fixtures/agejuge.py, sur PC) et les vecteurs « scrypt* » du
 * testkit age de C2SP/CCTV (tests/data/age, licence 0BSD / CC0 / Unlicense). */
#include <dirent.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include <mbedtls/base64.h>
#include <mbedtls/hkdf.h>
#include <mbedtls/md.h>

#include "crypto/fl_crypto.h"
#include "fluluks/age.h"
#include "fluluks/error.h"
#include "fluluks/format.h"
#include "fluluks/secure.h"
#include "fsck_util.h"
#include "tt.h"

#define KIB 1024
#define MIB (1024 * 1024)
#define CH 65536
#define LOG2N 10 /* petit facteur : les tests restent rapides ; 18 est le réglage de Portail */

/* --- Tampon en mémoire : sortie et entrée ------------------------------------------------------- */
typedef struct {
  uint8_t *p;
  size_t n, cap;
  int fail_after; /* > 0 : la n-ième écriture échoue (FL_EIO) */
} mem;

static int mem_write(void *ctx, const void *buf, size_t len) {
  mem *m = ctx;
  if (m->fail_after > 0 && --m->fail_after == 0) return FL_EIO;
  if (m->n + len > m->cap) {
    size_t c = m->cap ? m->cap * 2 : 4096;
    while (c < m->n + len) c *= 2;
    uint8_t *q = realloc(m->p, c);
    if (!q) return FL_ENOMEM;
    m->p = q;
    m->cap = c;
  }
  if (len) memcpy(m->p + m->n, buf, len);
  m->n += len;
  return FL_OK;
}

static int64_t mem_pread(void *ctx, void *buf, size_t len, uint64_t off) {
  mem *m = ctx;
  if (off >= m->n) return 0;
  size_t k = m->n - (size_t)off < len ? m->n - (size_t)off : len;
  memcpy(buf, m->p + off, k);
  return (int64_t)k;
}

static fl_arc_out mem_out(mem *m) { return (fl_arc_out){.ctx = m, .write = mem_write}; }
static fl_arc_in mem_in(mem *m) { return (fl_arc_in){.ctx = m, .size = (int64_t)m->n, .pread = mem_pread}; }
static void mem_free(mem *m) {
  free(m->p);
  memset(m, 0, sizeof *m);
}

static void remplir(uint8_t *p, size_t n, unsigned graine) {
  srand(graine);
  for (size_t i = 0; i < n; i++) p[i] = (uint8_t)rand();
}

/* Chiffre `data` par morceaux d'écriture irréguliers. */
static int chiffrer(const void *data, size_t len, const char *pw, uint8_t log2n, mem *out) {
  fl_arc_out o = mem_out(out);
  fl_agew *w = NULL;
  int rc = fl_agew_open(&o, pw, strlen(pw), log2n, &w);
  if (rc != FL_OK) return rc;
  size_t done = 0, pas = 1;
  while (done < len) {
    size_t k = len - done < pas ? len - done : pas;
    rc = fl_agew_write(w, (const uint8_t *)data + done, k);
    if (rc != FL_OK) {
      fl_agew_close(w, false);
      return rc;
    }
    done += k;
    pas = pas * 7 + 13; /* 1, 20, 153, 1084… puis de gros blocs */
    if (pas > 3 * CH) pas = 3 * CH + 1;
  }
  return fl_agew_close(w, true);
}

/* Déchiffre tout ; *out alloué (taille dans *n). */
static int dechiffrer(mem *ct, const char *pw, uint8_t max_log2n, uint8_t **out, size_t *n) {
  fl_arc_in in = mem_in(ct);
  fl_ager *r = NULL;
  *out = NULL;
  *n = 0;
  int rc = fl_ager_open(&in, pw, strlen(pw), max_log2n, &r);
  if (rc != FL_OK) return rc;
  int64_t size = fl_ager_size(r);
  uint8_t *buf = malloc(size ? (size_t)size : 1);
  uint64_t off = 0;
  for (;;) {
    int64_t k = fl_ager_pread(r, buf + off, 40000, off);
    if (k < 0) {
      free(buf);
      fl_ager_close(r);
      return (int)k;
    }
    if (k == 0) break;
    off += (uint64_t)k;
  }
  fl_ager_close(r);
  if ((int64_t)off != size) {
    free(buf);
    return -999;
  }
  *out = buf;
  *n = (size_t)off;
  return FL_OK;
}

/* Position de la charge utile (nonce compris) : fin de la ligne « --- … ». */
static size_t fin_entete(const mem *m) {
  for (size_t i = 0; i + 4 < m->n; i++) {
    if ((i == 0 || m->p[i - 1] == '\n') && memcmp(m->p + i, "--- ", 4) == 0) {
      const uint8_t *nl = memchr(m->p + i, '\n', m->n - i);
      return nl ? (size_t)(nl - m->p) + 1 : 0;
    }
  }
  return 0;
}

/* --- Tests ----------------------------------------------------------------------------------------- */
static void roundTripSizes(void) {
  const size_t tailles[] = {0, 1, CH - 1, CH, CH + 1, 3 * CH, 5 * MIB};
  for (size_t t = 0; t < sizeof tailles / sizeof *tailles; t++) {
    size_t len = tailles[t];
    uint8_t *data = malloc(len ? len : 1);
    remplir(data, len, (unsigned)t + 1);
    mem ct = {0};
    TT_ASSERT_EQ(chiffrer(data, len, "correct horse", LOG2N, &ct), FL_OK);
    size_t chunks = len == 0 ? 1 : (len + CH - 1) / CH;
    size_t h = fin_entete(&ct);
    TT_ASSERT(h > 0);
    TT_ASSERT_EQ(ct.n, h + 16 + len + 16 * chunks);
    uint8_t *pt;
    size_t n;
    TT_ASSERT_EQ(dechiffrer(&ct, "correct horse", 20, &pt, &n), FL_OK);
    TT_ASSERT_EQ(n, len);
    TT_ASSERT(len == 0 || memcmp(pt, data, len) == 0);
    free(pt);
    free(data);
    mem_free(&ct);
  }
}

static const char *tmp(const char *nom) {
  static char buf[4200];
  char td[4096];
  if (fu_tmpdir(td, sizeof td) != 0) return "/nonexistent";
  snprintf(buf, sizeof buf, "%s/%s", td, nom);
  return buf;
}

static int ecrire_fichier(const char *chemin, const void *p, size_t n) {
  FILE *f = fopen(chemin, "wb");
  if (!f) return -1;
  size_t k = n ? fwrite(p, 1, n, f) : 0;
  fclose(f);
  return k == n ? 0 : -1;
}

static int lire_fichier(const char *chemin, mem *m) {
  memset(m, 0, sizeof *m);
  FILE *f = fopen(chemin, "rb");
  if (!f) return -1;
  uint8_t buf[65536];
  size_t k;
  while ((k = fread(buf, 1, sizeof buf, f)) > 0) mem_write(m, buf, k);
  fclose(f);
  return 0;
}

static int juge(const char *cmd, const char *a, const char *b, const char *pw, const char *log2n, const char *opt) {
#ifdef __ANDROID__
  (void)cmd, (void)a, (void)b, (void)pw, (void)log2n, (void)opt;
  return -77;
#else
  char script[4200];
  snprintf(script, sizeof script, "%s/fixtures/agejuge.py", FL_TOOLS_DIR);
  char *argv[] = {"python3", "-I", script, (char *)cmd, (char *)a, (char *)b, (char *)pw, (char *)log2n,
                  (char *)opt, NULL};
  if (!log2n) argv[7] = NULL;
  if (!opt) argv[8] = NULL;
  char out[4096];
  int rc = fu_run(argv, out, sizeof out);
  if (rc != 0 && rc != 2 && rc != 3) fprintf(stderr, "agejuge : %s\n", out);
  return rc;
#endif
}

static void ageMatchesPythonJudge(void) {
#ifdef __ANDROID__
  fprintf(stderr, "ageMatchesPythonJudge : ignoré sur Android (pas de Python)\n");
  return;
#endif
  const size_t tailles[] = {0, CH, 200000};
  for (size_t t = 0; t < 3; t++) {
    size_t len = tailles[t];
    uint8_t *data = malloc(len + 1);
    remplir(data, len, 77 + (unsigned)t);
    /* moteur -> juge */
    mem ct = {0};
    TT_ASSERT_EQ(chiffrer(data, len, "mot de passe é", LOG2N, &ct), FL_OK);
    TT_ASSERT_EQ(ecrire_fichier(tmp("age-moteur.age"), ct.p, ct.n), 0);
    char sortie[4200];
    snprintf(sortie, sizeof sortie, "%s", tmp("age-moteur.out"));
    TT_ASSERT_EQ(juge("decrypt", tmp("age-moteur.age"), sortie, "mot de passe é", NULL, NULL), 0);
    mem lu;
    TT_ASSERT_EQ(lire_fichier(sortie, &lu), 0);
    TT_ASSERT_EQ(lu.n, len);
    TT_ASSERT(len == 0 || memcmp(lu.p, data, len) == 0);
    mem_free(&lu);
    mem_free(&ct);
    /* juge -> moteur */
    TT_ASSERT_EQ(ecrire_fichier(tmp("age-clair.bin"), data, len), 0);
    char chiffre[4200];
    snprintf(chiffre, sizeof chiffre, "%s", tmp("age-juge.age"));
    TT_ASSERT_EQ(juge("encrypt", tmp("age-clair.bin"), chiffre, "mot de passe é", "11", NULL), 0);
    mem cj;
    TT_ASSERT_EQ(lire_fichier(chiffre, &cj), 0);
    uint8_t *pt;
    size_t n;
    TT_ASSERT_EQ(dechiffrer(&cj, "mot de passe é", 20, &pt, &n), FL_OK);
    TT_ASSERT_EQ(n, len);
    TT_ASSERT(len == 0 || memcmp(pt, data, len) == 0);
    free(pt);
    mem_free(&cj);
    free(data);
  }
}

/* Dossier des vecteurs : $FL_FIXTURES/age (téléphone) ou les sources (PC). */
static const char *dossier_vecteurs(void) {
  static char buf[4200];
  const char *fx = getenv("FL_FIXTURES");
  if (fx) {
    snprintf(buf, sizeof buf, "%s/age", fx);
    struct stat st;
    if (stat(buf, &st) == 0 && S_ISDIR(st.st_mode)) return buf;
  }
  return FL_AGE_DATA;
}

/* Lit un vecteur : en-têtes « clé: valeur » puis ligne vide puis le fichier age. */
typedef struct {
  char expect[64], payload[80], pass[128], armored[8], compressed[16];
  mem age;
} vecteur;

static int lire_vecteur(const char *chemin, vecteur *v) {
  memset(v, 0, sizeof *v);
  mem m;
  if (lire_fichier(chemin, &m) != 0) return -1;
  size_t i = 0;
  while (i < m.n) {
    const uint8_t *nl = memchr(m.p + i, '\n', m.n - i);
    if (!nl) break;
    size_t l = (size_t)(nl - (m.p + i));
    if (l == 0) {
      i++;
      break;
    }
    char ligne[512];
    snprintf(ligne, sizeof ligne, "%.*s", (int)l, (const char *)m.p + i);
    char *sep = strstr(ligne, ": ");
    if (sep) {
      *sep = 0;
      const char *val = sep + 2;
      if (!strcmp(ligne, "expect")) snprintf(v->expect, sizeof v->expect, "%s", val);
      if (!strcmp(ligne, "payload")) snprintf(v->payload, sizeof v->payload, "%s", val);
      if (!strcmp(ligne, "passphrase") && !v->pass[0]) snprintf(v->pass, sizeof v->pass, "%s", val);
      if (!strcmp(ligne, "armored")) snprintf(v->armored, sizeof v->armored, "%s", val);
      if (!strcmp(ligne, "compressed")) snprintf(v->compressed, sizeof v->compressed, "%s", val);
    }
    i += l + 1;
  }
  mem_write(&v->age, m.p + i, m.n - i);
  mem_free(&m);
  return 0;
}

static void cctvScryptVectors(void) {
  const char *dir = dossier_vecteurs();
  DIR *d = opendir(dir);
  TT_ASSERT(d != NULL);
  int vus = 0;
  struct dirent *e;
  while ((e = readdir(d)) != NULL) {
    if (strncmp(e->d_name, "scrypt", 6) != 0 && strncmp(e->d_name, "armor_scrypt", 12) != 0) continue;
    char chemin[4400];
    snprintf(chemin, sizeof chemin, "%s/%s", dir, e->d_name);
    vecteur v;
    if (lire_vecteur(chemin, &v) != 0 || v.compressed[0]) {
      fprintf(stderr, "vecteur illisible : %s\n", e->d_name);
      tt_failures++;
      mem_free(&v.age);
      continue;
    }
    uint8_t *pt = NULL;
    size_t n = 0;
    int rc = dechiffrer(&v.age, v.pass, 20, &pt, &n);
    int ok;
    if (!strcmp(v.armored, "yes")) {
      ok = rc == FL_ENOTSUP;
    } else if (!strcmp(v.expect, "success")) {
      uint8_t h[32];
      char hex[65];
      fl_hash("sha256", pt ? pt : (uint8_t *)"", n, h);
      for (int k = 0; k < 32; k++) snprintf(hex + 2 * k, 3, "%02x", h[k]);
      ok = rc == FL_OK && !strcmp(hex, v.payload);
    } else if (!strcmp(v.expect, "no match")) {
      /* « Scrypt » en majuscules n'est pas un destinataire scrypt : non pris en charge. */
      ok = rc == FL_EBADPASS || (rc == FL_ENOTSUP && !strcmp(e->d_name, "scrypt_uppercase"));
    } else if (!strcmp(v.expect, "header failure")) {
      if (!strcmp(e->d_name, "scrypt_work_factor_23"))
        ok = rc == FL_ENOMEM;
      else if (!strcmp(e->d_name, "scrypt_and_x25519") || !strcmp(e->d_name, "scrypt_double"))
        ok = rc == FL_ENOTSUP;
      else
        ok = rc == FL_ECORRUPT;
    } else {
      ok = rc == FL_ECORRUPT;
    }
    if (!ok) {
      fprintf(stderr, "vecteur %s : attendu « %s », rc = %d\n", e->d_name, v.expect, rc);
      tt_failures++;
    }
    vus++;
    free(pt);
    mem_free(&v.age);
  }
  closedir(d);
  TT_ASSERT_EQ(vus, 26);
}

static void wrongPasswordIsBadPass(void) {
  mem ct = {0};
  TT_ASSERT_EQ(chiffrer("secret", 6, "bon mot de passe", LOG2N, &ct), FL_OK);
  uint8_t *pt;
  size_t n;
  TT_ASSERT_EQ(dechiffrer(&ct, "mauvais mot de passe", 20, &pt, &n), FL_EBADPASS);
  TT_ASSERT_EQ(dechiffrer(&ct, "", 20, &pt, &n), FL_EBADPASS);
  mem_free(&ct);
}

static void truncatedStreamRejected(void) {
  size_t len = 3 * CH;
  uint8_t *data = malloc(len);
  remplir(data, len, 5);
  mem ct = {0};
  TT_ASSERT_EQ(chiffrer(data, len, "pw-tronque", LOG2N, &ct), FL_OK);
  size_t h = fin_entete(&ct) + 16;
  const size_t coupes[] = {h + 2 * (CH + 16), h + (CH + 16), h + CH, h + 10, h, h - 5};
  for (size_t i = 0; i < sizeof coupes / sizeof *coupes; i++) {
    mem c = {0};
    mem_write(&c, ct.p, coupes[i]);
    uint8_t *pt;
    size_t n;
    int rc = dechiffrer(&c, "pw-tronque", 20, &pt, &n);
    if (rc != FL_ECORRUPT) fprintf(stderr, "coupe %zu : rc = %d\n", i, rc);
    TT_ASSERT_EQ(rc, FL_ECORRUPT);
    mem_free(&c);
  }
  mem_free(&ct);
  free(data);
}

static void swappedChunksRejected(void) {
  size_t len = 3 * CH + 100;
  uint8_t *data = malloc(len);
  remplir(data, len, 6);
  mem ct = {0};
  TT_ASSERT_EQ(chiffrer(data, len, "pw-permute", LOG2N, &ct), FL_OK);
  size_t h = fin_entete(&ct) + 16, full = CH + 16;
  uint8_t *tmpc = malloc(full);
  memcpy(tmpc, ct.p + h, full);
  memmove(ct.p + h, ct.p + h + full, full);
  memcpy(ct.p + h + full, tmpc, full);
  free(tmpc);
  fl_arc_in in = mem_in(&ct);
  fl_ager *r = NULL;
  TT_ASSERT_EQ(fl_ager_open(&in, "pw-permute", 10, 20, &r), FL_OK);
  uint8_t buf[100];
  TT_ASSERT_EQ(fl_ager_pread(r, buf, sizeof buf, 0), FL_ECORRUPT);
  TT_ASSERT_EQ(fl_ager_pread(r, buf, sizeof buf, CH + 5), FL_ECORRUPT);
  TT_ASSERT_EQ(fl_ager_pread(r, buf, sizeof buf, 2 * CH), sizeof buf); /* morceau 2 à sa place */
  TT_ASSERT_MEM_EQ(buf, data + 2 * CH, sizeof buf);
  fl_ager_close(r);
  mem_free(&ct);
  free(data);
}

static void flippedByteRejected(void) {
  size_t len = 2 * CH + 7;
  uint8_t *data = malloc(len);
  remplir(data, len, 8);
  mem ct = {0};
  TT_ASSERT_EQ(chiffrer(data, len, "pw-octet", LOG2N, &ct), FL_OK);
  size_t h = fin_entete(&ct);
  /* Positions : version, sel, facteur, corps, MAC, nonce, morceau 0, dernier morceau. */
  const char *ent = (const char *)ct.p;
  size_t p_ver = 3, p_sel = (size_t)(strstr(ent, "scrypt ") - ent) + 9;
  size_t p_corps = (size_t)(strchr(strstr(ent, "-> "), '\n') - ent) + 5;
  size_t p_mac = h - 10, p_nonce = h + 3, p_m0 = h + 16 + 100, p_der = ct.n - 3;
  const size_t pos[] = {p_ver, p_sel, p_corps, p_mac, p_nonce, p_m0, p_der};
  for (size_t i = 0; i < sizeof pos / sizeof *pos; i++) {
    mem c = {0};
    mem_write(&c, ct.p, ct.n);
    c.p[pos[i]] ^= (i == 0 || i == 1 || i == 2 || i == 3) ? 0x01 : 0x80;
    fl_arc_in in = mem_in(&c);
    fl_ager *r = NULL;
    int rc = fl_ager_open(&in, "pw-octet", 8, 20, &r);
    if (pos[i] == p_m0) {
      TT_ASSERT_EQ(rc, FL_OK); /* le morceau 0 n'est vérifié qu'à la lecture */
      uint8_t buf[16];
      TT_ASSERT_EQ(fl_ager_pread(r, buf, sizeof buf, 0), FL_ECORRUPT);
      fl_ager_close(r);
    } else {
      if (rc == FL_OK) fl_ager_close(r);
      if (rc >= 0) fprintf(stderr, "octet %zu (position %zu) non détecté\n", i, pos[i]);
      TT_ASSERT(rc < 0);
      if (pos[i] == p_mac || pos[i] == p_nonce || pos[i] == p_der) TT_ASSERT_EQ(rc, FL_ECORRUPT);
    }
    mem_free(&c);
  }
  mem_free(&ct);
  free(data);
}

static void emptyLastChunkOnlyForEmptyFile(void) {
#ifdef __ANDROID__
  fprintf(stderr, "emptyLastChunkOnlyForEmptyFile : ignoré sur Android (pas de Python)\n");
  return;
#endif
  uint8_t *data = malloc(CH);
  remplir(data, CH, 9);
  TT_ASSERT_EQ(ecrire_fichier(tmp("age-vide-clair.bin"), data, CH), 0);
  char chiffre[4200];
  snprintf(chiffre, sizeof chiffre, "%s", tmp("age-vide.age"));
  TT_ASSERT_EQ(juge("encrypt", tmp("age-vide-clair.bin"), chiffre, "pw-vide", "10", "--empty-last"), 0);
  mem c;
  TT_ASSERT_EQ(lire_fichier(chiffre, &c), 0);
  uint8_t *pt;
  size_t n;
  TT_ASSERT_EQ(dechiffrer(&c, "pw-vide", 20, &pt, &n), FL_ECORRUPT);
  mem_free(&c);
  /* Fichier vide : un seul morceau vide, accepté. */
  mem ct = {0};
  TT_ASSERT_EQ(chiffrer("", 0, "pw-vide", LOG2N, &ct), FL_OK);
  TT_ASSERT_EQ(dechiffrer(&ct, "pw-vide", 20, &pt, &n), FL_OK);
  TT_ASSERT_EQ(n, 0);
  free(pt);
  mem_free(&ct);
  free(data);
}

static void preadRandomAccess(void) {
  size_t len = MIB + 12345;
  uint8_t *data = malloc(len);
  remplir(data, len, 10);
  mem ct = {0};
  TT_ASSERT_EQ(chiffrer(data, len, "pw-alea", LOG2N, &ct), FL_OK);
  fl_arc_in in = mem_in(&ct);
  fl_ager *r = NULL;
  TT_ASSERT_EQ(fl_ager_open(&in, "pw-alea", 7, 20, &r), FL_OK);
  TT_ASSERT_EQ(fl_ager_size(r), (int64_t)len);
  uint8_t *buf = malloc(3 * CH);
  srand(11);
  for (int i = 0; i < 300; i++) {
    uint64_t off = (uint64_t)rand() % (len + 100);
    size_t n = (size_t)rand() % (3 * CH);
    int64_t k = fl_ager_pread(r, buf, n, off);
    size_t attendu = off >= len ? 0 : (len - off < n ? len - off : n);
    if (k != (int64_t)attendu) fprintf(stderr, "pread(%zu, %llu) = %lld\n", n, (unsigned long long)off, (long long)k);
    TT_ASSERT_EQ(k, (int64_t)attendu);
    TT_ASSERT(attendu == 0 || memcmp(buf, data + off, attendu) == 0);
  }
  TT_ASSERT_EQ(fl_ager_pread(r, buf, 10, len), 0);
  TT_ASSERT_EQ(fl_ager_pread(r, buf, 0, 5), 0);
  free(buf);
  fl_ager_close(r);
  mem_free(&ct);
  free(data);
}

static void workFactorAboveMaxRefused(void) {
  mem ct = {0};
  TT_ASSERT_EQ(chiffrer("x", 1, "pw-facteur", 12, &ct), FL_OK);
  uint8_t log2n = 0;
  fl_arc_in in = mem_in(&ct);
  TT_ASSERT_EQ(fl_age_peek(&in, &log2n), 1);
  TT_ASSERT_EQ(log2n, 12);
  uint8_t *pt;
  size_t n;
  TT_ASSERT_EQ(dechiffrer(&ct, "pw-facteur", 11, &pt, &n), FL_ENOMEM);
  TT_ASSERT_EQ(dechiffrer(&ct, "pw-facteur", 12, &pt, &n), FL_OK);
  free(pt);
  mem_free(&ct);
  /* Écriture : facteur hors bornes refusé. */
  mem o = {0};
  fl_arc_out out = mem_out(&o);
  fl_agew *w = NULL;
  TT_ASSERT_EQ(fl_agew_open(&out, "p", 1, 0, &w), FL_EINVAL);
  TT_ASSERT_EQ(fl_agew_open(&out, "p", 1, 23, &w), FL_EINVAL);
  TT_ASSERT_EQ(o.n, 0);
  mem_free(&o);
}

static void otherRecipientsRefused(void) {
  /* X25519 seul : refusé avant toute vérification (pas de clé de fichier sans identité). */
  const char *x =
      "age-encryption.org/v1\n"
      "-> X25519 TEiF0ypqr+bpvcqXNyCVJpL7OuwPdVwPL7KQEbFDOCc\n"
      "EmECAEcKN+n/Vs9SbWiV+Hu0r+E8R77DdWYyd83nw7A\n"
      "--- Vn+54jqiiUCE+WZcEVY3f1sqHjlu/z1LCQ/T7Xm7qIA\n"
      "0123456789abcdef0123456789abcdef0123456789abcdef";
  mem c = {0};
  mem_write(&c, x, strlen(x));
  uint8_t *pt;
  size_t n;
  TT_ASSERT_EQ(dechiffrer(&c, "pw", 20, &pt, &n), FL_ENOTSUP);
  fl_arc_in in = mem_in(&c);
  uint8_t log2n = 0;
  TT_ASSERT_EQ(fl_age_peek(&in, &log2n), 0);
  mem_free(&c);
  /* Pas un fichier age du tout. */
  mem z = {0};
  mem_write(&z, "PK\x03\x04 pas age", 12);
  TT_ASSERT_EQ(dechiffrer(&z, "pw", 20, &pt, &n), FL_ENOTSUP);
  in = mem_in(&z);
  TT_ASSERT_EQ(fl_age_peek(&in, &log2n), 0);
  mem_free(&z);
}

static void rewrapKeepsPayload(void) {
  size_t len = 200000;
  uint8_t *data = malloc(len);
  remplir(data, len, 12);
  mem ct = {0};
  TT_ASSERT_EQ(chiffrer(data, len, "ancien", LOG2N, &ct), FL_OK);
  fl_arc_in in = mem_in(&ct);
  /* Mauvais ancien mot de passe : rien n'est écrit. */
  mem nw = {0};
  fl_arc_out out = mem_out(&nw);
  TT_ASSERT_EQ(fl_age_rewrap(&in, &out, "faux", 4, "nouveau", 7, LOG2N), FL_EBADPASS);
  TT_ASSERT_EQ(nw.n, 0);
  TT_ASSERT_EQ(fl_age_rewrap(&in, &out, "ancien", 6, "nouveau", 7, 11), FL_OK);
  size_t h1 = fin_entete(&ct), h2 = fin_entete(&nw);
  TT_ASSERT_EQ(ct.n - h1, nw.n - h2);
  TT_ASSERT_MEM_EQ(ct.p + h1, nw.p + h2, ct.n - h1);
  uint8_t *pt;
  size_t n;
  TT_ASSERT_EQ(dechiffrer(&nw, "ancien", 20, &pt, &n), FL_EBADPASS);
  TT_ASSERT_EQ(dechiffrer(&nw, "nouveau", 20, &pt, &n), FL_OK);
  TT_ASSERT_EQ(n, len);
  TT_ASSERT_MEM_EQ(pt, data, len);
  free(pt);
  /* Charge abîmée : la recopie vérifiée échoue. */
  mem_free(&nw);
  ct.p[h1 + 16 + 50] ^= 1;
  in = mem_in(&ct);
  out = mem_out(&nw);
  TT_ASSERT_EQ(fl_age_rewrap(&in, &out, "ancien", 6, "nouveau", 7, LOG2N), FL_ECORRUPT);
  mem_free(&nw);
  mem_free(&ct);
  free(data);
}

/* --- Effacement des secrets : crochet sur fl_secure_free -------------------------------------------- */
typedef struct {
  uint8_t vus[64][64];
  size_t tailles[64];
  int n;
} libere;

static void crochet(void *arg, const void *p, size_t n) {
  libere *l = arg;
  if (l->n < 64 && n <= 64) {
    memcpy(l->vus[l->n], p, n);
    l->tailles[l->n++] = n;
  }
}

static int vu(const libere *l, const uint8_t *s, size_t n) {
  for (int i = 0; i < l->n; i++)
    if (l->tailles[i] == n && memcmp(l->vus[i], s, n) == 0) return 1;
  return 0;
}

static int b64d(const char *s, size_t len, uint8_t *out, size_t cap, size_t *olen) {
  char tmpb[128];
  if (len + 4 > sizeof tmpb) return -1;
  memcpy(tmpb, s, len);
  while (len % 4) tmpb[len++] = '=';
  return mbedtls_base64_decode(out, cap, olen, (const unsigned char *)tmpb, len);
}

static void secretsWipedAfterClose(void) {
  vecteur v;
  char chemin[4400];
  snprintf(chemin, sizeof chemin, "%s/scrypt", dossier_vecteurs());
  TT_ASSERT_EQ(lire_vecteur(chemin, &v), 0);
  /* Secrets attendus : clé de fichier (vecteur), clé d'enveloppe (scrypt), clé de charge (HKDF). */
  uint8_t fk[16] = {0x59, 0x45, 0x4c, 0x4c, 0x4f, 0x57, 0x20, 0x53, 0x55, 0x42, 0x4d, 0x41, 0x52, 0x49, 0x4e, 0x45};
  const char *ent = (const char *)v.age.p;
  const char *s = strstr(ent, "-> scrypt ") + 10;
  const char *sp = strchr(s, ' ');
  uint8_t sel[16 + 28];
  memcpy(sel, "age-encryption.org/v1/scrypt", 28);
  size_t sl = 0;
  TT_ASSERT_EQ(b64d(s, (size_t)(sp - s), sel + 28, 16, &sl), 0);
  TT_ASSERT_EQ(sl, 16);
  int log2n = atoi(sp + 1);
  uint8_t wrap[32];
  TT_ASSERT_EQ(fl_scrypt(v.pass, strlen(v.pass), sel, sizeof sel, (uint8_t)log2n, 8, 1, wrap, 32), FL_OK);
  size_t h = fin_entete(&v.age);
  uint8_t pk[32];
  TT_ASSERT_EQ(mbedtls_hkdf(mbedtls_md_info_from_type(MBEDTLS_MD_SHA256), v.age.p + h, 16, fk, 16,
                            (const unsigned char *)"payload", 7, pk, 32),
               0);
  libere *l = calloc(1, sizeof *l);
  fl_secure_debug_set_free_hook(crochet, l);
  uint8_t *pt;
  size_t n;
  int rc = dechiffrer(&v.age, v.pass, 20, &pt, &n);
  fl_secure_debug_set_free_hook(NULL, NULL);
  TT_ASSERT_EQ(rc, FL_OK);
  free(pt);
  TT_ASSERT(vu(l, fk, 16));
  TT_ASSERT(vu(l, wrap, 32));
  TT_ASSERT(vu(l, pk, 32));
  /* Écrivain : clé de fichier (16), clé d'enveloppe et clé de charge (32) passent aussi par fl_secure_free. */
  memset(l, 0, sizeof *l);
  fl_secure_debug_set_free_hook(crochet, l);
  mem ct = {0};
  rc = chiffrer("abc", 3, "pw", LOG2N, &ct);
  fl_secure_debug_set_free_hook(NULL, NULL);
  TT_ASSERT_EQ(rc, FL_OK);
  int n16 = 0, n32 = 0;
  for (int i = 0; i < l->n; i++) {
    n16 += l->tailles[i] == 16;
    n32 += l->tailles[i] == 32;
  }
  TT_ASSERT(n16 >= 1);
  TT_ASSERT(n32 >= 2);
  free(l);
  mem_free(&ct);
  mem_free(&v.age);
}

static void writerAbortWritesNothingMore(void) {
  mem o = {0};
  fl_arc_out out = mem_out(&o);
  fl_agew *w = NULL;
  TT_ASSERT_EQ(fl_agew_open(&out, "pw", 2, LOG2N, &w), FL_OK);
  size_t avant = o.n;
  TT_ASSERT_EQ(fl_agew_write(w, "abc", 3), FL_OK);
  TT_ASSERT_EQ(fl_agew_close(w, false), FL_OK);
  TT_ASSERT_EQ(o.n, avant);
  /* Erreur de la sortie : rendue telle quelle. */
  mem_free(&o);
  o.fail_after = 3;
  out = mem_out(&o);
  TT_ASSERT_EQ(fl_agew_open(&out, "pw", 2, LOG2N, &w), FL_OK);
  uint8_t *big = calloc(1, 4 * CH);
  int rc = fl_agew_write(w, big, 4 * CH);
  if (rc == FL_OK) rc = fl_agew_close(w, true);
  else fl_agew_close(w, false);
  TT_ASSERT_EQ(rc, FL_EIO);
  free(big);
  mem_free(&o);
}

int main(void) {
  TT_RUN(roundTripSizes);
  TT_RUN(ageMatchesPythonJudge);
  TT_RUN(cctvScryptVectors);
  TT_RUN(wrongPasswordIsBadPass);
  TT_RUN(truncatedStreamRejected);
  TT_RUN(swappedChunksRejected);
  TT_RUN(flippedByteRejected);
  TT_RUN(emptyLastChunkOnlyForEmptyFile);
  TT_RUN(preadRandomAccess);
  TT_RUN(workFactorAboveMaxRefused);
  TT_RUN(otherRecipientsRefused);
  TT_RUN(rewrapKeepsPayload);
  TT_RUN(secretsWipedAfterClose);
  TT_RUN(writerAbortWritesNothingMore);
  TT_MAIN_END();
}

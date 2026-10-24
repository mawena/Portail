#define _GNU_SOURCE
/* Phase 14, T2 : ZIP chiffré AES-256 (écriture et lecture), archives ZIP protégées par mot de passe (AES ou
 * ancien chiffrement), ZIP dans un flux age. Juges : tools/fixtures/zipaesjuge.py, tools/fixtures/agejuge.py et
 * `zipfile` de Python (sur PC). */
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "crypto/fl_crypto.h"
#include "fluluks/archive.h"
#include "fluluks/error.h"
#include "fluluks/secure.h"
#include "fsck_util.h"
#include "tt.h"

#define MIB (1024 * 1024)

static int ecrire_fd(void *ctx, const void *buf, size_t len) {
  int fd = *(int *)ctx;
  size_t done = 0;
  while (done < len) {
    ssize_t n = write(fd, (const char *)buf + done, len - done);
    if (n <= 0) return FL_EIO;
    done += (size_t)n;
  }
  return FL_OK;
}

static int64_t lire_fd(void *ctx, void *buf, size_t len, uint64_t off) {
  ssize_t n = pread(*(int *)ctx, buf, len, (off_t)off);
  return n < 0 ? FL_EIO : n;
}

static const char *tmp_(const char *nom, char *buf, size_t cap) {
  char td[4096];
  if (fu_tmpdir(td, sizeof td) != 0) return "/nonexistent";
  snprintf(buf, cap, "%s/%s", td, nom);
  return buf;
}
#define TMP(nom) tmp_(nom, (char[4200]){0}, 4200)

static const char *archives(const char *nom) {
  static char buf[4200];
  const char *d = getenv("FL_ARC_FIXTURES");
  snprintf(buf, sizeof buf, "%s/%s", d ? d : ".", nom);
  return buf;
}

/* Contenu déterministe d'un fichier : octet i = (i * mul + i / 977) mod 256. */
static void motif(uint8_t *p, size_t n, size_t base, int mul) {
  for (size_t i = 0; i < n; i++) p[i] = (uint8_t)((base + i) * (size_t)mul + (base + i) / 977);
}

static int ajouter(fl_arc_writer *w, const char *nom, size_t n, int mul) {
  int rc = fl_arcw_add(w, nom, FL_ARC_FILE, (int64_t)n, 1714564800, false);
  static uint8_t buf[65536];
  for (size_t done = 0; rc == FL_OK && done < n;) {
    size_t k = n - done < sizeof buf ? n - done : sizeof buf;
    motif(buf, k, done, mul);
    rc = fl_arcw_write(w, buf, k);
    done += k;
  }
  return rc;
}

static void sha_hex(const uint8_t *p, size_t n, char hex[65]) {
  uint8_t h[32];
  fl_hash("sha256", p ? p : (const uint8_t *)"", n, h);
  for (int k = 0; k < 32; k++) snprintf(hex + 2 * k, 3, "%02x", h[k]);
}

/* Relit toute l'archive : une ligne « nom|taille|sha256 » ou « nom|dossier » par entrée, dans `out`.
 * Rend FL_OK ou la première erreur. */
static int relire(fl_arc_reader *r, char *out, size_t cap) {
  out[0] = 0;
  size_t o = 0;
  fl_arc_entry e;
  int rc;
  static uint8_t data[6 * MIB];
  while ((rc = fl_arc_next(r, &e)) == 1) {
    if (e.type == FL_ARC_DIR) {
      o += (size_t)snprintf(out + o, cap - o, "%s|dossier\n", e.name);
      continue;
    }
    size_t n = 0;
    for (;;) {
      int64_t k = fl_arc_read(r, data + n, sizeof data - n);
      if (k < 0) return (int)k;
      if (k == 0) break;
      n += (size_t)k;
    }
    char hex[65];
    sha_hex(data, n, hex);
    o += (size_t)snprintf(out + o, cap - o, "%s|%zu|%s\n", e.name, n, hex);
  }
  return rc < 0 ? rc : FL_OK;
}

__attribute__((unused)) static int juge(char *out, size_t cap, const char *script, const char *a, const char *b, const char *c,
                const char *d, const char *e) {
#ifdef __ANDROID__
  (void)out, (void)cap, (void)script, (void)a, (void)b, (void)c, (void)d, (void)e;
  return -77;
#else
  char chemin[4200];
  snprintf(chemin, sizeof chemin, "%s/fixtures/%s", FL_TOOLS_DIR, script);
  char *argv[] = {"python3", "-I", chemin, (char *)a, (char *)b, (char *)c, (char *)d, (char *)e, NULL};
  return fu_run(argv, out, cap);
#endif
}

typedef struct {
  int fd;
  fl_arc_in in;
} entree;

static int ouvrir(entree *s, const char *chemin) {
  s->fd = open(chemin, O_RDONLY);
  if (s->fd < 0) return -1;
  struct stat st;
  fstat(s->fd, &st);
  s->in = (fl_arc_in){.ctx = &s->fd, .size = st.st_size, .pread = lire_fd};
  return 0;
}

/* Écrit le ZIP AES de référence : vide.txt (0), été/un.bin (1 Mio), gros.bin (5 Mio), dossier-vide/. */
static int ecrire_zip_aes(const char *chemin, const char *pw) {
  int fd = open(chemin, O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (fd < 0) return -1;
  fl_arc_out out = {.ctx = &fd, .write = ecrire_fd};
  fl_arc_writer *w = NULL;
  int rc = fl_arcw_open2(&out, pw, strlen(pw), &w);
  if (rc == FL_OK) rc = ajouter(w, "vide.txt", 0, 3);
  if (rc == FL_OK) rc = ajouter(w, "été/un.bin", MIB, 5);
  if (rc == FL_OK) rc = ajouter(w, "gros.bin", 5 * MIB, 7);
  if (rc == FL_OK) rc = fl_arcw_add(w, "dossier-vide", FL_ARC_DIR, 0, 1714564800, false);
  if (w) {
    int c = fl_arcw_close(w, rc == FL_OK);
    if (rc == FL_OK) rc = c;
  }
  close(fd);
  return rc;
}

static void zipAesJudgedByPython(void) {
  const char *zip = TMP("crypt-aes.zip");
  TT_ASSERT_EQ(ecrire_zip_aes(zip, "mot de passe fort"), FL_OK);
  /* Lignes attendues (dans l'ordre d'écriture). */
  char attendu[2048];
  uint8_t *b = malloc(5 * MIB);
  char h0[65], h1[65], h2[65];
  sha_hex(NULL, 0, h0);
  motif(b, MIB, 0, 5);
  sha_hex(b, MIB, h1);
  motif(b, 5 * MIB, 0, 7);
  sha_hex(b, 5 * MIB, h2);
  free(b);
  snprintf(attendu, sizeof attendu, "vide.txt|0|%s\nété/un.bin|%d|%s\ngros.bin|%d|%s\ndossier-vide/|dossier\n", h0,
           MIB, h1, 5 * MIB, h2);
#ifndef __ANDROID__
  char out[8192];
  TT_ASSERT_EQ(juge(out, sizeof out, "zipaesjuge.py", "read", zip, "mot de passe fort", NULL, NULL), 0);
  TT_ASSERT(strncmp(out, attendu, strlen(attendu)) == 0);
  /* Les deux fichiers non vides sont chiffrés ; libarchive écrit un fichier vide sans chiffrement (aucun octet à
   * protéger ; dans un ZIP AES, les noms restent lisibles de toute façon). */
  TT_ASSERT(strstr(out, "aes 2") != NULL);
#endif
  /* Relu aussi par le moteur, avec le mot de passe. */
  entree s;
  TT_ASSERT_EQ(ouvrir(&s, zip), 0);
  fl_arc_reader *r = NULL;
  TT_ASSERT_EQ(fl_arc_open2(&s.in, "mot de passe fort", 17, &r), FL_OK);
  char lu[8192];
  TT_ASSERT_EQ(relire(r, lu, sizeof lu), FL_OK);
  fl_arc_close(r);
  close(s.fd);
  /* Noms rendus tels quels par le moteur : « dossier-vide/ » garde sa barre finale, comme pour le juge. */
  TT_ASSERT_STR_EQ(lu, attendu);
}

/* Arbre de référence pour les ZIP écrits par le juge. */
__attribute__((unused)) static int arbre_juge(const char *dir) {
  char p[4400];
  mkdir(dir, 0755);
  snprintf(p, sizeof p, "%s/sous", dir);
  mkdir(p, 0755);
  uint8_t *b = malloc(300000);
  motif(b, 300000, 0, 11);
  snprintf(p, sizeof p, "%s/sous/données.bin", dir);
  FILE *f = fopen(p, "wb");
  if (!f) return -1;
  fwrite(b, 1, 300000, f);
  fclose(f);
  snprintf(p, sizeof p, "%s/a.txt", dir);
  f = fopen(p, "wb");
  if (!f) return -1;
  fputs("bonjour\n", f);
  fclose(f);
  free(b);
  return 0;
}

static void lire_zip_juge(const char *opt, const char *nom) {
#ifdef __ANDROID__
  (void)opt, (void)nom;
  fprintf(stderr, "ignoré sur Android (pas de Python)\n");
  return;
#else
  const char *dir = TMP("crypt-arbre");
  TT_ASSERT_EQ(arbre_juge(dir), 0);
  char zip[4200];
  tmp_(nom, zip, sizeof zip);
  char out[8192];
  TT_ASSERT_EQ(juge(out, sizeof out, "zipaesjuge.py", "write", dir, zip, "Sésame 42", opt), 0);
  char attendu[8192];
  TT_ASSERT_EQ(juge(attendu, sizeof attendu, "zipaesjuge.py", "read", zip, "Sésame 42", NULL, NULL), 0);
  entree s;
  TT_ASSERT_EQ(ouvrir(&s, zip), 0);
  fl_arc_reader *r = NULL;
  TT_ASSERT_EQ(fl_arc_open2(&s.in, "Sésame 42", strlen("Sésame 42"), &r), FL_OK);
  char lu[8192];
  TT_ASSERT_EQ(relire(r, lu, sizeof lu), FL_OK);
  fl_arc_close(r);
  close(s.fd);
  /* Le juge écrit « sous/ » ; le moteur rend « sous ». Comparer fichier par fichier. */
  TT_ASSERT(strstr(lu, "a.txt|8|") != NULL);
  char *l = strstr(attendu, "sous/données.bin|");
  TT_ASSERT(l != NULL);
  char ligne[200];
  snprintf(ligne, sizeof ligne, "%.*s", (int)(strchr(l, '\n') - l), l);
  TT_ASSERT(strstr(lu, ligne) != NULL);
#endif
}

static void judgeZipAesReadByEngine(void) { lire_zip_juge(NULL, "crypt-juge-aes.zip"); }

static void zipCryptoReadWithPassword(void) {
  lire_zip_juge("--zipcrypto", "crypt-juge-zc.zip");
  /* ZIP « ZipCrypto » d'Info-ZIP (zip -P secret), jeu de la phase 9. */
  entree s;
  TT_ASSERT_EQ(ouvrir(&s, archives("chiffre.zip")), 0);
  fl_arc_reader *r = NULL;
  TT_ASSERT_EQ(fl_arc_open2(&s.in, "secret", 6, &r), FL_OK);
  char lu[1024];
  TT_ASSERT_EQ(relire(r, lu, sizeof lu), FL_OK);
  TT_ASSERT(strncmp(lu, "été.txt|8|", strlen("été.txt|8|")) == 0);
  fl_arc_close(r);
  close(s.fd);
}

static void lecture_refusee(const char *zip, const char *pw, size_t pwlen, int attendu) {
  entree s;
  TT_ASSERT_EQ(ouvrir(&s, zip), 0);
  fl_arc_reader *r = NULL;
  TT_ASSERT_EQ(fl_arc_open2(&s.in, pw, pwlen, &r), FL_OK);
  fl_arc_entry e;
  int fichiers = 0;
  while (fl_arc_next(r, &e) == 1) {
    if (e.type != FL_ARC_FILE || e.size == 0) continue;
    fichiers++;
    TT_ASSERT(e.encrypted);
    uint8_t buf[4096];
    memset(buf, 0xAA, sizeof buf);
    int64_t k = fl_arc_read(r, buf, sizeof buf);
    if (k != attendu) fprintf(stderr, "%s : fl_arc_read = %lld\n", e.name, (long long)k);
    TT_ASSERT_EQ(k, attendu);
    for (size_t i = 0; i < sizeof buf; i++) TT_ASSERT_EQ(buf[i], 0xAA);
  }
  TT_ASSERT(fichiers > 0);
  fl_arc_close(r);
  close(s.fd);
}

static void zipAesWrongPasswordRefused(void) {
  const char *zip = TMP("crypt-aes.zip");
  TT_ASSERT_EQ(ecrire_zip_aes(zip, "mot de passe fort"), FL_OK);
  lecture_refusee(zip, "mot de passe faux", 17, FL_EBADPASS);
  lecture_refusee(archives("chiffre.zip"), "pas secret", 10, FL_EBADPASS);
}

static void noPasswordStillSaysEncrypted(void) {
  const char *zip = TMP("crypt-aes.zip");
  TT_ASSERT_EQ(ecrire_zip_aes(zip, "mot de passe fort"), FL_OK);
  lecture_refusee(zip, NULL, 0, FL_ENOTSUP);
  /* fl_arc_open (phase 9) : comportement inchangé. */
  entree s;
  TT_ASSERT_EQ(ouvrir(&s, archives("chiffre.zip")), 0);
  fl_arc_reader *r = NULL;
  TT_ASSERT_EQ(fl_arc_open(&s.in, &r), FL_OK);
  fl_arc_entry e;
  TT_ASSERT_EQ(fl_arc_next(r, &e), 1);
  TT_ASSERT(e.encrypted);
  uint8_t buf[16];
  TT_ASSERT_EQ(fl_arc_read(r, buf, sizeof buf), FL_ENOTSUP);
  fl_arc_close(r);
  close(s.fd);
  /* Mot de passe avec un octet nul : refusé. */
  TT_ASSERT_EQ(ouvrir(&s, archives("chiffre.zip")), 0);
  TT_ASSERT_EQ(fl_arc_open2(&s.in, "se\0cret", 7, &r), FL_EINVAL);
  close(s.fd);
}

static void zipInsideAgeRoundTrip(void) {
  const char *chemin = TMP("crypt-dossier.zip.age");
  int fd = open(chemin, O_WRONLY | O_CREAT | O_TRUNC, 0644);
  TT_ASSERT(fd >= 0);
  fl_arc_out out = {.ctx = &fd, .write = ecrire_fd};
  fl_arc_writer *w = NULL;
  TT_ASSERT_EQ(fl_arcw_open_age(&out, "phrase de passe", 15, 10, &w), FL_OK);
  char nom[64];
  int rc = FL_OK;
  for (int i = 0; i < 200 && rc == FL_OK; i++) {
    snprintf(nom, sizeof nom, "dossier/%02d/fichier-%03d.txt", i / 20, i);
    rc = ajouter(w, nom, (size_t)(i * 37 % 5000), i + 1);
  }
  TT_ASSERT_EQ(rc, FL_OK);
  TT_ASSERT_EQ(fl_arcw_close(w, true), FL_OK);
  close(fd);
#ifndef __ANDROID__
  char zip[4200], out2[8192];
  tmp_("crypt-dossier.zip", zip, sizeof zip);
  TT_ASSERT_EQ(juge(out2, sizeof out2, "agejuge.py", "decrypt", chemin, zip, "phrase de passe", NULL), 0);
  const char *py =
      "import sys, zipfile\n"
      "z = zipfile.ZipFile(sys.argv[1])\n"
      "assert z.testzip() is None\n"
      "print(len([i for i in z.infolist() if not i.is_dir()]))\n";
  char *argv[] = {"python3", "-I", "-c", (char *)py, zip, NULL};
  TT_ASSERT_EQ(fu_run(argv, out2, sizeof out2), 0);
  TT_ASSERT_EQ(atoi(out2), 200);
#endif
  entree s;
  TT_ASSERT_EQ(ouvrir(&s, chemin), 0);
  fl_arc_reader *r = NULL;
  TT_ASSERT_EQ(fl_arc_open_age(&s.in, "faux", 4, 20, &r), FL_EBADPASS);
  TT_ASSERT_EQ(fl_arc_open_age(&s.in, "phrase de passe", 15, 20, &r), FL_OK);
  fl_arc_entry e;
  int n = 0;
  uint8_t buf[8192], att[8192];
  while (fl_arc_next(r, &e) == 1) {
    if (e.type != FL_ARC_FILE) continue;
    int i = atoi(strrchr(e.name, '-') + 1);
    size_t len = (size_t)(i * 37 % 5000);
    TT_ASSERT_EQ(e.size, (int64_t)len);
    size_t got = 0;
    int64_t k;
    while ((k = fl_arc_read(r, buf + got, sizeof buf - got)) > 0) got += (size_t)k;
    TT_ASSERT_EQ(k, 0);
    TT_ASSERT_EQ(got, len);
    motif(att, len, 0, i + 1);
    TT_ASSERT_MEM_EQ(buf, att, len);
    n++;
  }
  TT_ASSERT_EQ(n, 200);
  fl_arc_close(r);
  close(s.fd);
}

static void sevenZipEncryptedStillRefused(void) {
  const char *noms[] = {"test_read_format_7zip_encryption.7z", "test_read_format_rar_encryption_data.rar"};
  for (int i = 0; i < 2; i++) {
    entree s;
    TT_ASSERT_EQ(ouvrir(&s, archives(noms[i])), 0);
    fl_arc_reader *r = NULL;
    int rc = fl_arc_open2(&s.in, "password", 8, &r);
    if (rc == FL_OK) {
      fl_arc_entry e;
      int k = fl_arc_next(r, &e);
      if (k == 1) {
        uint8_t buf[64];
        TT_ASSERT(e.encrypted);
        TT_ASSERT_EQ(fl_arc_read(r, buf, sizeof buf), FL_ENOTSUP);
      } else {
        TT_ASSERT(k < 0);
      }
      fl_arc_close(r);
    } else {
      TT_ASSERT(rc < 0);
    }
    close(s.fd);
  }
}

/* La copie terminée par NUL faite pour libarchive passe par fl_secure_free (effacée). Celles de libarchive
 * (strdup) sont effacées par archive_read_free / archive_write_free (memset relu dans le code d'amont ;
 * fl_libarchive compilé avec -fno-builtin-memset pour que l'optimiseur ne puisse pas l'ôter). */
typedef struct {
  int vus;
} crochet_etat;
static const char *g_pw;
static void crochet(void *arg, const void *p, size_t n) {
  crochet_etat *c = arg;
  size_t l = strlen(g_pw);
  if (n == l + 1 && memcmp(p, g_pw, l + 1) == 0) c->vus++;
}

static void passphraseCopyWiped(void) {
  crochet_etat c = {0};
  g_pw = "mot de passe fort";
  fl_secure_debug_set_free_hook(crochet, &c);
  int rc = ecrire_zip_aes(TMP("crypt-aes.zip"), g_pw);
  fl_secure_debug_set_free_hook(NULL, NULL);
  TT_ASSERT_EQ(rc, FL_OK);
  TT_ASSERT_EQ(c.vus, 1);
  c.vus = 0;
  entree s;
  TT_ASSERT_EQ(ouvrir(&s, TMP("crypt-aes.zip")), 0);
  fl_arc_reader *r = NULL;
  fl_secure_debug_set_free_hook(crochet, &c);
  rc = fl_arc_open2(&s.in, g_pw, strlen(g_pw), &r);
  if (rc == FL_OK) fl_arc_close(r);
  fl_secure_debug_set_free_hook(NULL, NULL);
  close(s.fd);
  TT_ASSERT_EQ(rc, FL_OK);
  TT_ASSERT_EQ(c.vus, 1);
}

int main(void) {
  TT_RUN(zipAesJudgedByPython);
  TT_RUN(judgeZipAesReadByEngine);
  TT_RUN(zipCryptoReadWithPassword);
  TT_RUN(zipAesWrongPasswordRefused);
  TT_RUN(noPasswordStillSaysEncrypted);
  TT_RUN(zipInsideAgeRoundTrip);
  TT_RUN(sevenZipEncryptedStillRefused);
  TT_RUN(passphraseCopyWiped);
  TT_MAIN_END();
}

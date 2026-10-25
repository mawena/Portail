#define _GNU_SOURCE
/* Phase 14, T3 : emplacements de clé LUKS2 (changer, ajouter, retirer), sûrs en cas de coupure à chaque
 * écriture, jugés par cryptsetup (sans root) sur le PC. */
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include "fault_bdev.h"
#include "fluluks/blockdev.h"
#include "fluluks/error.h"
#include "fluluks/format.h"
#include "fluluks/luks.h"
#include "fsck_util.h"
#include "tt.h"

#define MIB (1024ull * 1024ull)
#define MEM 8192 /* Kio : Argon2 rapide pour les tests */
#define P0 "mot de passe initial"
#define P1 "nouveau mot de passe"
#define REC "ABCD-EFGH-JKMN-PQRS-TVWX-YZ01"
#define TETE (16 * MIB) /* en-têtes et zone des emplacements */
#define HDR 16384u
#define ZONE0 32768u    /* zone de l'emplacement 0 */
#define ZONE_LEN 258048u

static const uint8_t BIO[32] = {1,  2,  3,  4,  5,  6,  7,  8,  9,  10, 11, 12, 13, 14, 15, 16,
                                17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 0};

static char g_base[4096]; /* coffre de référence : P0 dans l'emplacement 0, motif au début des données */
static uint8_t g_motif[64 * 1024];

static int chemin(char *path, size_t cap, const char *nom) {
  char td[4096];
  if (fu_tmpdir(td, sizeof td) != 0) return -1;
  snprintf(path, cap, "%s/%s", td, nom);
  return 0;
}

static int copier(const char *src, const char *dst) {
  FILE *a = fopen(src, "rb"), *b = fopen(dst, "wb");
  int ok = a && b;
  static unsigned char buf[1u << 20];
  size_t n;
  while (ok && (n = fread(buf, 1, sizeof buf, a)) > 0) ok = fwrite(buf, 1, n, b) == n;
  if (a) fclose(a);
  if (b && fclose(b) != 0) ok = 0;
  return ok ? 0 : -1;
}

static void preparer_base(void) {
  TT_ASSERT_EQ(chemin(g_base, sizeof g_base, "slots-base.luks"), 0);
  int fd = open(g_base, O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
  TT_ASSERT(fd >= 0);
  TT_ASSERT_EQ(ftruncate(fd, (off_t)(40 * MIB)), 0);
  close(fd);
  fl_bdev *d = NULL, *dec = NULL;
  TT_ASSERT_EQ(fl_file_bdev_open(g_base, 512, false, &d), FL_OK);
  TT_ASSERT_EQ(fl_luks2_format(d, P0, strlen(P0), MEM, &dec), FL_OK);
  for (size_t i = 0; i < sizeof g_motif; i++) g_motif[i] = (uint8_t)(i * 13 + 5);
  TT_ASSERT_EQ(fl_bdev_write(dec, 0, sizeof g_motif / 512, g_motif), FL_OK);
  TT_ASSERT_EQ(fl_bdev_flush(dec), FL_OK);
  fl_bdev_close(dec);
  fl_bdev_close(d);
}

/* Copie de la base, ouverte en écriture. */
static fl_bdev *copie(char *path, size_t cap, const char *nom) {
  fl_bdev *d = NULL;
  if (chemin(path, cap, nom) != 0 || copier(g_base, path) != 0) return NULL;
  if (fl_file_bdev_open(path, 512, false, &d) != FL_OK) return NULL;
  return d;
}

/* Ouvre avec `pass` par l'emplacement `slot` (−1 : tous) ; FL_OK si les données sont intactes. */
static int ouvre(fl_bdev *d, int slot, const void *pass, size_t len) {
  fl_luks *l = NULL;
  fl_bdev *dec = NULL;
  int rc = fl_luks_open(d, &l);
  if (rc == FL_OK) rc = fl_luks_unlock_slot(l, slot, pass, len, &dec);
  static uint8_t lu[sizeof g_motif];
  if (rc == FL_OK) rc = fl_bdev_read(dec, 0, sizeof lu / 512, lu);
  if (rc == FL_OK && memcmp(lu, g_motif, sizeof lu) != 0) rc = FL_ECORRUPT;
  fl_bdev_close(dec);
  fl_luks_close(l);
  return rc;
}

static int ouvre_s(fl_bdev *d, int slot, const char *pass) { return ouvre(d, slot, pass, strlen(pass)); }

static int masque(fl_bdev *d, uint32_t *m) { return fl_luks_slots(d, m); }

static int lire_zone(const char *img, uint64_t off, size_t len, uint8_t *out) {
  FILE *f = fopen(img, "rb");
  if (!f) return -1;
  int ok = fseeko(f, (off_t)off, SEEK_SET) == 0 && fread(out, 1, len, f) == len;
  fclose(f);
  return ok ? 0 : -1;
}

static bool nulle(const uint8_t *p, size_t n) {
  for (size_t i = 0; i < n; i++)
    if (p[i]) return false;
  return true;
}

static void changeSlot0(void) {
  char img[4096];
  fl_bdev *d = copie(img, sizeof img, "slots-change.luks");
  TT_ASSERT(d != NULL);
  TT_ASSERT_EQ(fl_luks2_slot_set(d, 0, P0, strlen(P0), P1, strlen(P1), MEM, 1), FL_OK);
  TT_ASSERT_EQ(ouvre_s(d, -1, P1), FL_OK);
  TT_ASSERT_EQ(ouvre_s(d, -1, P0), FL_EBADPASS);
  TT_ASSERT_EQ(ouvre_s(d, 0, P1), FL_OK);
  uint32_t m = 0;
  TT_ASSERT_EQ(masque(d, &m), FL_OK);
  TT_ASSERT_EQ(m, 0x1);
  fl_bdev_close(d);
  /* l'ancienne zone de l'emplacement 0 est effacée */
  static uint8_t z[ZONE_LEN];
  TT_ASSERT_EQ(lire_zone(img, ZONE0, ZONE_LEN, z), 0);
  TT_ASSERT(nulle(z, ZONE_LEN));
  unlink(img);
}

static void addRecoveryAndBiometricSlots(void) {
  char img[4096];
  fl_bdev *d = copie(img, sizeof img, "slots-ajout.luks");
  TT_ASSERT(d != NULL);
  TT_ASSERT_EQ(fl_luks2_slot_set(d, 1, P0, strlen(P0), REC, strlen(REC), MEM, 1), FL_OK);
  /* l'authentification passe par n'importe quel emplacement : ici la clé de secours */
  TT_ASSERT_EQ(fl_luks2_slot_set(d, 2, REC, strlen(REC), BIO, sizeof BIO, MEM, 1), FL_OK);
  uint32_t m = 0;
  TT_ASSERT_EQ(masque(d, &m), FL_OK);
  TT_ASSERT_EQ(m, 0x7);
  TT_ASSERT_EQ(ouvre_s(d, 0, P0), FL_OK);
  TT_ASSERT_EQ(ouvre_s(d, 1, REC), FL_OK);
  TT_ASSERT_EQ(ouvre(d, 2, BIO, sizeof BIO), FL_OK);
  TT_ASSERT_EQ(ouvre(d, 0, BIO, sizeof BIO), FL_EBADPASS);
  TT_ASSERT_EQ(ouvre_s(d, 2, REC), FL_EBADPASS);
  TT_ASSERT_EQ(ouvre(d, -1, BIO, sizeof BIO), FL_OK);
  TT_ASSERT_EQ(ouvre_s(d, 5, P0), FL_ENOENT); /* emplacement absent */
  /* refus avant toute écriture */
  TT_ASSERT_EQ(fl_luks2_slot_set(d, 32, P0, strlen(P0), P1, strlen(P1), MEM, 1), FL_EINVAL);
  TT_ASSERT_EQ(fl_luks2_slot_set(d, -1, P0, strlen(P0), P1, strlen(P1), MEM, 1), FL_EINVAL);
  TT_ASSERT_EQ(fl_luks2_slot_set(d, 3, P0, strlen(P0), P1, 0, MEM, 1), FL_EINVAL);
  TT_ASSERT_EQ(fl_luks2_slot_set(d, 3, P0, strlen(P0), P1, strlen(P1), 1024, 1), FL_EINVAL);
  TT_ASSERT_EQ(fl_luks2_slot_set(d, 3, P0, strlen(P0), P1, strlen(P1), MEM, 0), FL_EINVAL);
  fl_bdev_close(d);
  unlink(img);
}

static void removeSlot(void) {
  char img[4096];
  fl_bdev *d = copie(img, sizeof img, "slots-retrait.luks");
  TT_ASSERT(d != NULL);
  TT_ASSERT_EQ(fl_luks2_slot_set(d, 1, P0, strlen(P0), REC, strlen(REC), MEM, 1), FL_OK);
  static uint8_t z[ZONE_LEN];
  TT_ASSERT_EQ(lire_zone(img, ZONE0 + ZONE_LEN, ZONE_LEN, z), 0);
  TT_ASSERT(!nulle(z, ZONE_LEN)); /* zone de l'emplacement 1 : juste après celle du 0 */
  TT_ASSERT_EQ(fl_luks2_slot_remove(d, 1, "faux", 4), FL_EBADPASS);
  TT_ASSERT_EQ(fl_luks2_slot_remove(d, 4, P0, strlen(P0)), FL_ENOENT);
  TT_ASSERT_EQ(fl_luks2_slot_remove(d, 1, REC, strlen(REC)), FL_OK); /* par lui-même */
  uint32_t m = 0;
  TT_ASSERT_EQ(masque(d, &m), FL_OK);
  TT_ASSERT_EQ(m, 0x1);
  TT_ASSERT_EQ(ouvre_s(d, -1, REC), FL_EBADPASS);
  TT_ASSERT_EQ(ouvre_s(d, -1, P0), FL_OK);
  fl_bdev_close(d);
  TT_ASSERT_EQ(lire_zone(img, ZONE0 + ZONE_LEN, ZONE_LEN, z), 0);
  TT_ASSERT(nulle(z, ZONE_LEN));
  unlink(img);
}

static void lastSlotNeverRemoved(void) {
  char img[4096];
  fl_bdev *d = copie(img, sizeof img, "slots-dernier.luks");
  TT_ASSERT(d != NULL);
  TT_ASSERT_EQ(fl_luks2_slot_remove(d, 0, P0, strlen(P0)), FL_EBUSY);
  TT_ASSERT_EQ(ouvre_s(d, -1, P0), FL_OK);
  fl_bdev_close(d);
  unlink(img);
}

static int lire_tete(const char *img, uint8_t *out) { return lire_zone(img, 0, TETE, out); }

static void wrongAuthChangesNothing(void) {
  char img[4096];
  fl_bdev *d = copie(img, sizeof img, "slots-faux.luks");
  TT_ASSERT(d != NULL);
  TT_ASSERT_EQ(fl_luks2_slot_set(d, 1, P0, strlen(P0), REC, strlen(REC), MEM, 1), FL_OK);
  static uint8_t avant[TETE], apres[TETE];
  TT_ASSERT_EQ(lire_tete(img, avant), 0);
  TT_ASSERT_EQ(fl_luks2_slot_set(d, 0, "faux", 4, P1, strlen(P1), MEM, 1), FL_EBADPASS);
  TT_ASSERT_EQ(fl_luks2_slot_set(d, 2, "faux", 4, P1, strlen(P1), MEM, 1), FL_EBADPASS);
  TT_ASSERT_EQ(fl_luks2_slot_remove(d, 1, "faux", 4), FL_EBADPASS);
  TT_ASSERT_EQ(lire_tete(img, apres), 0);
  TT_ASSERT_MEM_EQ(avant, apres, TETE);
  fl_bdev_close(d);
  unlink(img);
}

/* Coupure (écriture refusée, plus rien d'écrit ensuite) à chaque écriture possible d'un changement ou
 * d'un retrait : ensuite l'ancien ou le nouveau mot de passe ouvre, jamais aucun. */
static void coupures(const char *quoi, int (*op)(fl_bdev *d), const char *ancien, const char *nouveau) {
  char img[4096];
  fl_bdev *d = copie(img, sizeof img, "slots-coupure.luks");
  TT_ASSERT(d != NULL);
  fl_bdev *f = NULL;
  TT_ASSERT_EQ(fl_fault_bdev_new(d, UINT64_MAX, FL_EIO, &f), FL_OK);
  TT_ASSERT_EQ(op(f), FL_OK);
  uint64_t n = fl_fault_bdev_writes(f);
  fl_bdev_close(f);
  fl_bdev_close(d);
  TT_ASSERT(n >= 3); /* zone, en-tête primaire, en-tête secondaire */
  fprintf(stderr, "  %s : %llu écritures\n", quoi, (unsigned long long)n);
  for (uint64_t k = 0; k < n; k++) {
    d = copie(img, sizeof img, "slots-coupure.luks");
    TT_ASSERT(d != NULL);
    TT_ASSERT_EQ(fl_fault_bdev_new(d, k, FL_EIO, &f), FL_OK);
    int rc = op(f);
    fl_bdev_close(f);
    TT_ASSERT(rc != FL_OK);
    int a = ouvre_s(d, -1, ancien), b = ouvre_s(d, -1, nouveau);
    if (a != FL_OK && b != FL_OK) {
      fprintf(stderr, "coupure après %llu écritures : aucun mot de passe n'ouvre (%d, %d)\n",
              (unsigned long long)k, a, b);
      TT_ASSERT(0);
    }
    fl_bdev_close(d);
  }
  unlink(img);
}

static int op_change(fl_bdev *d) { return fl_luks2_slot_set(d, 0, P0, strlen(P0), P1, strlen(P1), MEM, 1); }

/* Retrait de l'emplacement 0, la clé de secours restant : après coupure, P0 ou la clé de secours. */
static int op_retrait(fl_bdev *d) {
  uint32_t m = 0;
  int rc = fl_luks_slots(d, &m);
  if (rc == FL_OK && !(m & 2)) rc = fl_luks2_slot_set(d, 1, P0, strlen(P0), REC, strlen(REC), MEM, 1);
  return rc == FL_OK ? fl_luks2_slot_remove(d, 0, REC, strlen(REC)) : rc;
}

static void slotChangeSurvivesCutAtEveryWrite(void) {
  coupures("changement", op_change, P0, P1);
  /* base avec la clé de secours, pour le retrait */
  char sauve[4096], img[4096];
  snprintf(sauve, sizeof sauve, "%s", g_base);
  fl_bdev *d = copie(img, sizeof img, "slots-base-secours.luks");
  TT_ASSERT(d != NULL);
  TT_ASSERT_EQ(fl_luks2_slot_set(d, 1, P0, strlen(P0), REC, strlen(REC), MEM, 1), FL_OK);
  fl_bdev_close(d);
  snprintf(g_base, sizeof g_base, "%s", img);
  coupures("retrait", op_retrait, P0, REC);
  snprintf(g_base, sizeof g_base, "%s", sauve);
  unlink(img);
}

/* Abîme un octet de la zone JSON de l'en-tête à `off` (somme fausse). */
static int abimer(const char *img, uint64_t off) {
  FILE *f = fopen(img, "r+b");
  if (!f) return -1;
  uint8_t c = 0;
  int ok = fseeko(f, (off_t)(off + 4096 + 3), SEEK_SET) == 0 && fread(&c, 1, 1, f) == 1;
  c ^= 0x40;
  ok = ok && fseeko(f, (off_t)(off + 4096 + 3), SEEK_SET) == 0 && fwrite(&c, 1, 1, f) == 1;
  return fclose(f) == 0 && ok ? 0 : -1;
}

static int ecrire_zone(const char *img, uint64_t off, const uint8_t *p, size_t len) {
  FILE *f = fopen(img, "r+b");
  if (!f) return -1;
  int ok = fseeko(f, (off_t)off, SEEK_SET) == 0 && fwrite(p, 1, len, f) == len;
  return fclose(f) == 0 && ok ? 0 : -1;
}

static void newerSecondaryWins(void) {
  char img[4096];
  static uint8_t ancien_primaire[HDR];
  fl_bdev *d = copie(img, sizeof img, "slots-secondaire.luks");
  TT_ASSERT(d != NULL);
  TT_ASSERT_EQ(lire_zone(img, 0, HDR, ancien_primaire), 0); /* seqid 1, P0 */
  TT_ASSERT_EQ(fl_luks2_slot_set(d, 0, P0, strlen(P0), P1, strlen(P1), MEM, 1), FL_OK);
  fl_bdev_close(d);

  /* primaire abîmé : la secondaire (P1) est prise, en lecture comme en écriture ; le primaire est refait */
  TT_ASSERT_EQ(abimer(img, 0), 0);
  TT_ASSERT_EQ(fl_file_bdev_open(img, 512, false, &d), FL_OK);
  TT_ASSERT_EQ(ouvre_s(d, -1, P1), FL_OK);
  TT_ASSERT_EQ(fl_luks2_slot_set(d, 1, P1, strlen(P1), REC, strlen(REC), MEM, 1), FL_OK);
  fl_bdev_close(d);
  static uint8_t h[HDR];
  TT_ASSERT_EQ(lire_zone(img, 0, HDR, h), 0);
  TT_ASSERT_MEM_EQ(h, "LUKS\xBA\xBE", 6);
  TT_ASSERT_EQ(fl_file_bdev_open(img, 512, false, &d), FL_OK);
  TT_ASSERT_EQ(ouvre_s(d, 1, REC), FL_OK);

  /* primaire valide mais plus ancien (seqid 1, P0) : la secondaire, plus récente, gagne */
  fl_bdev_close(d);
  TT_ASSERT_EQ(ecrire_zone(img, 0, ancien_primaire, HDR), 0);
  TT_ASSERT_EQ(fl_file_bdev_open(img, 512, false, &d), FL_OK);
  TT_ASSERT_EQ(ouvre_s(d, -1, P0), FL_EBADPASS);
  TT_ASSERT_EQ(ouvre_s(d, -1, P1), FL_OK);
  TT_ASSERT_EQ(fl_luks2_slot_set(d, 0, P1, strlen(P1), P0, strlen(P0), MEM, 1), FL_OK);
  TT_ASSERT_EQ(ouvre_s(d, 0, P0), FL_OK);
  TT_ASSERT_EQ(ouvre_s(d, 1, REC), FL_OK); /* l'emplacement 1 de la secondaire n'est pas perdu */
  fl_bdev_close(d);
  unlink(img);
}

static int cle(char *path, size_t cap, const void *p, size_t len) {
  if (chemin(path, cap, "slots-cle.bin") != 0) return -1;
  FILE *f = fopen(path, "wb");
  if (!f) return -1;
  size_t n = fwrite(p, 1, len, f);
  return fclose(f) == 0 && n == len ? 0 : -1;
}

static int cs_test(const char *img, int slot, const void *p, size_t len) {
  char k[4096], out[4096], s[8];
  if (cle(k, sizeof k, p, len) != 0) return -1;
  snprintf(s, sizeof s, "%d", slot);
  char *argv[] = {"env",        "LC_ALL=C", "cryptsetup", "open",      "--test-passphrase", "--key-slot",
                  s,            "--key-file", k,          (char *)img, NULL};
  int rc = fu_run(argv, out, sizeof out);
  unlink(k);
  return rc;
}

static bool cryptsetup_present(void) {
  char out[256];
  char *v[] = {"cryptsetup", "--version", NULL};
  return fu_run(v, out, sizeof out) == 0;
}

static void cryptsetupAcceptsChangedHeader(void) {
  if (!cryptsetup_present()) {
    fprintf(stderr, "  cryptsetup absent : test sauté\n");
    return;
  }
  char img[4096], out[1 << 15];
  fl_bdev *d = copie(img, sizeof img, "slots-cryptsetup.luks");
  TT_ASSERT(d != NULL);
  TT_ASSERT_EQ(fl_luks2_slot_set(d, 0, P0, strlen(P0), P1, strlen(P1), MEM, 1), FL_OK);
  TT_ASSERT_EQ(fl_luks2_slot_set(d, 1, P1, strlen(P1), REC, strlen(REC), MEM, 1), FL_OK);
  TT_ASSERT_EQ(fl_luks2_slot_set(d, 2, P1, strlen(P1), BIO, sizeof BIO, 65536, 1), FL_OK);
  fl_bdev_close(d);
  char *dump[] = {"env", "LC_ALL=C", "cryptsetup", "luksDump", img, NULL};
  TT_ASSERT_EQ(fu_run(dump, out, sizeof out), 0);
  const char *attendus[] = {"  0: luks2", "  1: luks2", "  2: luks2", "Memory:     65536", "Time cost:  1"};
  for (size_t i = 0; i < sizeof attendus / sizeof attendus[0]; i++) {
    if (!strstr(out, attendus[i])) {
      fprintf(stderr, "absent : %s\n%s\n", attendus[i], out);
      TT_ASSERT(0);
    }
  }
  TT_ASSERT_EQ(cs_test(img, 0, P1, strlen(P1)), 0);
  TT_ASSERT_EQ(cs_test(img, 1, REC, strlen(REC)), 0);
  TT_ASSERT_EQ(cs_test(img, 2, BIO, sizeof BIO), 0);
  TT_ASSERT(cs_test(img, 0, P0, strlen(P0)) != 0);
  TT_ASSERT(cs_test(img, 1, P1, strlen(P1)) != 0);

  TT_ASSERT_EQ(fl_file_bdev_open(img, 512, false, &d), FL_OK);
  TT_ASSERT_EQ(fl_luks2_slot_remove(d, 1, P1, strlen(P1)), FL_OK);
  fl_bdev_close(d);
  TT_ASSERT_EQ(fu_run(dump, out, sizeof out), 0);
  TT_ASSERT(strstr(out, "  1: luks2") == NULL);
  TT_ASSERT_EQ(cs_test(img, 2, BIO, sizeof BIO), 0);
  unlink(img);
}

/* L'emplacement demandé est seul essayé : une seule lecture de zone d'emplacement (celle du 2), alors
 * que tous les essayer lit d'abord les zones des emplacements 0 et 1. */
static void unlockSlotSkipsOthers(void) {
  char img[4096];
  fl_bdev *d = copie(img, sizeof img, "slots-seul.luks");
  TT_ASSERT(d != NULL);
  TT_ASSERT_EQ(fl_luks2_slot_set(d, 1, P0, strlen(P0), REC, strlen(REC), MEM, 1), FL_OK);
  TT_ASSERT_EQ(fl_luks2_slot_set(d, 2, P0, strlen(P0), BIO, sizeof BIO, MEM, 1), FL_OK);
  fl_bdev *f = NULL;
  TT_ASSERT_EQ(fl_fault_bdev_new(d, UINT64_MAX, FL_EIO, &f), FL_OK);
  fl_luks *l = NULL;
  fl_bdev *dec = NULL;
  TT_ASSERT_EQ(fl_luks_open(f, &l), FL_OK);
  uint64_t r0 = fl_fault_bdev_reads(f);
  TT_ASSERT_EQ(fl_luks_unlock_slot(l, 2, BIO, sizeof BIO, &dec), FL_OK);
  TT_ASSERT_EQ(fl_fault_bdev_reads(f) - r0, 1);
  fl_bdev_close(dec);
  r0 = fl_fault_bdev_reads(f);
  TT_ASSERT_EQ(fl_luks_unlock_slot(l, -1, BIO, sizeof BIO, &dec), FL_OK);
  TT_ASSERT_EQ(fl_fault_bdev_reads(f) - r0, 3);
  fl_bdev_close(dec);
  TT_ASSERT_EQ(fl_luks_unlock_slot(l, 7, BIO, sizeof BIO, &dec), FL_ENOENT);
  TT_ASSERT(dec == NULL);
  fl_luks_close(l);
  fl_bdev_close(f);
  fl_bdev_close(d);
  unlink(img);
}

static void luks1Refused(void) {
  char img[4096];
  TT_ASSERT_EQ(chemin(img, sizeof img, "slots-luks1.img"), 0);
  TT_ASSERT_EQ(copier(tt_fixture("whole-luks1-xts.img"), img), 0);
  char pass[256];
  FILE *pf = fopen(tt_fixture("pass.txt"), "rb");
  TT_ASSERT(pf != NULL);
  size_t n = fread(pass, 1, sizeof pass, pf);
  fclose(pf);
  fl_bdev *d = NULL;
  TT_ASSERT_EQ(fl_file_bdev_open(img, 512, false, &d), FL_OK);
  uint32_t m = 0;
  TT_ASSERT_EQ(fl_luks_slots(d, &m), FL_OK);
  TT_ASSERT(m & 1);
  static uint8_t avant[2 * 1024 * 1024], apres[2 * 1024 * 1024];
  TT_ASSERT_EQ(lire_zone(img, 0, sizeof avant, avant), 0);
  TT_ASSERT_EQ(fl_luks2_slot_set(d, 1, pass, n, P1, strlen(P1), MEM, 1), FL_ENOTSUP);
  TT_ASSERT_EQ(fl_luks2_slot_remove(d, 0, pass, n), FL_ENOTSUP);
  TT_ASSERT_EQ(lire_zone(img, 0, sizeof apres, apres), 0);
  TT_ASSERT_MEM_EQ(avant, apres, sizeof avant);
  /* LUKS1 : un emplacement précis s'ouvre aussi */
  fl_luks *l = NULL;
  fl_bdev *dec = NULL;
  TT_ASSERT_EQ(fl_luks_open(d, &l), FL_OK);
  TT_ASSERT_EQ(fl_luks_unlock_slot(l, 0, pass, n, &dec), FL_OK);
  fl_bdev_close(dec);
  TT_ASSERT_EQ(fl_luks_unlock_slot(l, 6, pass, n, &dec), FL_ENOENT);
  fl_luks_close(l);
  fl_bdev_close(d);
  /* ni LUKS1 ni LUKS2 */
  TT_ASSERT_EQ(fl_file_bdev_open(tt_fixture("ext4-plain.img"), 512, true, &d), FL_OK);
  TT_ASSERT_EQ(fl_luks_slots(d, &m), FL_ENOTSUP);
  fl_bdev_close(d);
  unlink(img);
}

/* Les emplacements s'ajoutent jusqu'à ce que la zone JSON (12 Kio) ou la zone des emplacements soit
 * pleine : alors FL_ENOSPC, sans rien abîmer. Les trois emplacements de Portail tiennent largement. */
static void jsonStaysUnder12KiB(void) {
  char img[4096], out[1 << 16];
  fl_bdev *d = copie(img, sizeof img, "slots-plein.luks");
  TT_ASSERT(d != NULL);
  int ajoutes = 0, rc = FL_OK;
  char s[32];
  for (int slot = 1; slot < 32; slot++) {
    snprintf(s, sizeof s, "secret %d", slot);
    rc = fl_luks2_slot_set(d, slot, P0, strlen(P0), s, strlen(s), MEM, 1);
    if (rc != FL_OK) break;
    ajoutes++;
  }
  fprintf(stderr, "  %d emplacements ajoutés\n", ajoutes);
  TT_ASSERT(rc == FL_OK || rc == FL_ENOSPC);
  TT_ASSERT(ajoutes >= 3);
  static uint8_t h[HDR];
  for (int i = 0; i < 2; i++) {
    TT_ASSERT_EQ(lire_zone(img, (uint64_t)i * HDR, HDR, h), 0);
    TT_ASSERT(memchr(h + 4096, 0, HDR - 4096) != NULL);
    TT_ASSERT(strlen((const char *)h + 4096) < HDR - 4096);
  }
  TT_ASSERT_EQ(ouvre_s(d, 0, P0), FL_OK);
  snprintf(s, sizeof s, "secret %d", ajoutes);
  TT_ASSERT_EQ(ouvre_s(d, ajoutes, s), FL_OK);
  fl_bdev_close(d);
  if (cryptsetup_present()) {
    char *dump[] = {"env", "LC_ALL=C", "cryptsetup", "luksDump", img, NULL};
    TT_ASSERT_EQ(fu_run(dump, out, sizeof out), 0);
  }
  unlink(img);
}

int main(void) {
  TT_RUN(preparer_base);
  if (tt_failures) TT_MAIN_END();
  TT_RUN(changeSlot0);
  TT_RUN(addRecoveryAndBiometricSlots);
  TT_RUN(removeSlot);
  TT_RUN(lastSlotNeverRemoved);
  TT_RUN(wrongAuthChangesNothing);
  TT_RUN(slotChangeSurvivesCutAtEveryWrite);
  TT_RUN(newerSecondaryWins);
  TT_RUN(cryptsetupAcceptsChangedHeader);
  TT_RUN(unlockSlotSkipsOthers);
  TT_RUN(luks1Refused);
  TT_RUN(jsonStaysUnder12KiB);
  unlink(g_base);
  TT_MAIN_END();
}

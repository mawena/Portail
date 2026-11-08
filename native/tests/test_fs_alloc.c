#define _GNU_SOURCE
/* Place allouée, inode et liens physiques de fl_stat (phase 16, T2), pour l'analyseur de stockage. Juges
 * indépendants du moteur : debugfs (manifeste ext4-du.alloc, écrit par make_fixtures.sh), fatjuge.py alloc et
 * ntfsjuge.py alloc, au format « chemin<TAB>octets alloués<TAB>inode<TAB>liens ». Les cas FAT32, exFAT et NTFS
 * (juges Python, images écrites par le moteur) et huge_file (debugfs) sont réservés au PC. */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "fluluks/blockdev.h"
#include "fluluks/error.h"
#include "fluluks/fs.h"
#include "fluluks/probe.h"
#include "fsck_util.h"
#include "tt.h"

#define GIO ((uint64_t)1 << 30)
#define SORTIE_JUGE (256 * 1024)

/* --- manifestes ------------------------------------------------------------------------------- */

typedef struct {
  char *chemin;
  uint64_t alloc, ino;
  uint32_t liens;
} ligne;

typedef struct {
  ligne *v;
  size_t n;
} manifeste;

/* Découpe le texte (modifié sur place, gardé par l'appelant) en lignes « chemin\talloc\tino\tliens ». 0 si ok. */
static int lire_lignes(char *texte, manifeste *m) {
  m->v = NULL;
  m->n = 0;
  size_t cap = 0;
  for (char *l = texte, *suite; l && *l; l = suite) {
    suite = strchr(l, '\n');
    if (suite) *suite++ = 0;
    char *t1 = strchr(l, '\t'), *t2 = t1 ? strchr(t1 + 1, '\t') : NULL, *t3 = t2 ? strchr(t2 + 1, '\t') : NULL;
    if (!t3) return -1;
    *t1 = 0;
    if (m->n == cap) {
      cap = cap ? cap * 2 : 64;
      ligne *nv = realloc(m->v, cap * sizeof *nv);
      if (!nv) return -1;
      m->v = nv;
    }
    m->v[m->n++] = (ligne){l, strtoull(t1 + 1, NULL, 10), strtoull(t2 + 1, NULL, 10),
                           (uint32_t)strtoul(t3 + 1, NULL, 10)};
  }
  return m->n ? 0 : -1;
}

static char *lire_fichier(const char *chemin) {
  FILE *f = fopen(chemin, "rb");
  if (!f) return NULL;
  char *buf = malloc(1 << 20);
  size_t n = buf ? fread(buf, 1, (1 << 20) - 1, f) : 0;
  fclose(f);
  if (buf) buf[n] = 0;
  return buf;
}

static const ligne *chercher(const manifeste *m, const char *chemin) {
  for (size_t i = 0; i < m->n; i++)
    if (!strcmp(m->v[i].chemin, chemin)) return &m->v[i];
  return NULL;
}

/* --- volumes ---------------------------------------------------------------------------------- */

typedef struct {
  char copie[4096]; /* "" : fixture montée en lecture seule, sans copie */
  fl_bdev *dev;
  fl_fs *fs;
} vol;

static int monter(const char *img, bool rw, vol *v) {
  fl_probe_result pr;
  if (fl_file_bdev_open(img, 512, !rw, &v->dev) != FL_OK) return FL_EIO;
  if (fl_probe(v->dev, &pr) != FL_OK) return FL_EIO;
  return fl_fs_mount(v->dev, pr.content, rw, &v->fs);
}

static int ouvrir_fixture(const char *nom, vol *v) {
  memset(v, 0, sizeof *v);
  return monter(tt_fixture(nom), false, v);
}

/* Copie de la fixture, montée en écriture. */
static int ouvrir_copie(const char *nom, vol *v) {
  memset(v, 0, sizeof *v);
  if (fu_copy_image(tt_fixture(nom), v->copie, sizeof v->copie) != 0) return FL_EIO;
  return monter(v->copie, true, v);
}

static void demonter(vol *v) {
  if (v->fs) fl_fs_unmount(v->fs);
  v->fs = NULL;
  fl_bdev_close(v->dev);
  v->dev = NULL;
}

/* Démonte la copie écrite et la remonte en lecture seule : ce qui est lu vient du disque. */
static int remonter(vol *v) {
  int rc = fl_fs_unmount(v->fs);
  v->fs = NULL;
  fl_bdev_close(v->dev);
  v->dev = NULL;
  return rc != FL_OK ? rc : monter(v->copie, false, v);
}

static void liberer(vol *v) {
  demonter(v);
  if (v->copie[0]) unlink(v->copie);
  v->copie[0] = 0;
}

static int ecrire(fl_fs *fs, const char *chemin, size_t n) {
  fl_file *f;
  int rc = fl_fs_open(fs, chemin, FL_O_RDWR | FL_O_CREAT | FL_O_TRUNC, &f);
  if (rc != FL_OK) return rc;
  char *buf = malloc(n ? n : 1);
  if (!buf) {
    fl_file_close(f);
    return FL_ENOMEM;
  }
  memset(buf, 'x', n);
  int64_t w = n ? fl_file_pwrite(f, buf, n, 0) : 0;
  free(buf);
  rc = fl_file_close(f);
  return w < 0 ? (int)w : rc;
}

/* --- comparaison ------------------------------------------------------------------------------- */

typedef struct {
  const manifeste *m;
  const char *dossier;
  const char *ignore; /* chemin dont la place n'est pas comparée (dossier FAT de plusieurs clusters), ou NULL */
  int ecarts, vus;
} cmp_ctx;

static int ecart(const char *ou, const char *chemin, const fl_stat *st, const ligne *l) {
  fprintf(stderr, "%s %s : alloc %llu ino %llu liens %u, attendu %llu %llu %u\n", ou, chemin,
          (unsigned long long)st->alloc, (unsigned long long)st->ino, st->nlink, (unsigned long long)l->alloc,
          (unsigned long long)l->ino, l->liens);
  return 1;
}

static bool pareil(const fl_stat *st, const ligne *l, const char *ignore) {
  bool place = (ignore && !strcmp(l->chemin, ignore)) || st->alloc == l->alloc;
  return place && st->ino == l->ino && st->nlink == l->liens;
}

static int cmp_cb(void *ctx, const fl_dirent *e) {
  cmp_ctx *c = ctx;
  char chemin[4096];
  snprintf(chemin, sizeof chemin, "%s/%s", strcmp(c->dossier, "/") ? c->dossier : "", e->name);
  const ligne *l = chercher(c->m, chemin);
  if (!l) return 0; /* lost+found, absent du manifeste ext4 */
  c->vus++;
  if (!pareil(&e->st, l, c->ignore)) c->ecarts += ecart("readdir", chemin, &e->st, l);
  return 0;
}

/* Chaque entrée du manifeste par fl_fs_stat, puis par la liste de son dossier parent : nombre d'écarts. */
static int comparer(fl_fs *fs, const manifeste *m, const char *ignore) {
  int ecarts = 0, vus = 0;
  for (size_t i = 0; i < m->n; i++) {
    fl_stat st;
    int rc = fl_fs_stat(fs, m->v[i].chemin, &st);
    if (rc != FL_OK) {
      fprintf(stderr, "stat %s = %d\n", m->v[i].chemin, rc);
      ecarts++;
      continue;
    }
    if (!pareil(&st, &m->v[i], ignore)) ecarts += ecart("stat", m->v[i].chemin, &st, &m->v[i]);
    if (st.type != FL_FT_DIR) continue;
    cmp_ctx c = {m, m->v[i].chemin, ignore, 0, 0};
    rc = fl_fs_readdir(fs, m->v[i].chemin, cmp_cb, &c);
    if (rc != FL_OK) fprintf(stderr, "readdir %s = %d\n", m->v[i].chemin, rc);
    ecarts += c.ecarts + (rc != FL_OK);
    vus += c.vus;
  }
  if (vus + 1 != (int)m->n) {
    fprintf(stderr, "%d entrées vues par readdir pour %zu dans le manifeste\n", vus, m->n);
    ecarts++;
  }
  return ecarts;
}

/* Sortie de « <juge> alloc <img> » dans *texte (à libérer), découpée dans m. 0 si ok. */
static int juger(bool ntfs, const char *img, char **texte, manifeste *m) {
  *texte = malloc(SORTIE_JUGE);
  if (!*texte) return -1;
  int rc = ntfs ? fu_ntfsjuge(*texte, SORTIE_JUGE, "alloc", img, NULL)
                : fu_fatjuge(*texte, SORTIE_JUGE, "alloc", img, NULL);
  if (rc != 0) {
    fprintf(stderr, "juge %s = %d\n%s\n", img, rc, *texte);
    return -1;
  }
  return lire_lignes(*texte, m);
}

static uint64_t alloc_de(fl_fs *fs, const char *chemin) {
  fl_stat st;
  return fl_fs_stat(fs, chemin, &st) == FL_OK ? st.alloc : UINT64_MAX;
}

/* --- ext4 --------------------------------------------------------------------------------------- */

static void test_ext4AllocMatchesDebugfs(void) {
  char *texte = lire_fichier(tt_fixture("ext4-du.alloc"));
  TT_ASSERT(texte != NULL);
  manifeste m;
  int lu = lire_lignes(texte, &m);
  vol v;
  int rc = lu == 0 ? ouvrir_fixture("ext4-du.img", &v) : FL_EIO;
  int ecarts = rc == FL_OK ? comparer(v.fs, &m, NULL) : -1;
  if (rc == FL_OK) demonter(&v);
  size_t n = m.n;
  free(m.v);
  free(texte);
  TT_ASSERT_EQ(lu, 0);
  TT_ASSERT_EQ(rc, FL_OK);
  TT_ASSERT_EQ(n, 350); /* racine, 7 fichiers, gros-dossier et ses 300 fichiers, 40 niveaux et fond.txt */
  TT_ASSERT_EQ(ecarts, 0);
}

static void test_ext4SparseFileAllocSmall(void) {
  vol v;
  TT_ASSERT_EQ(ouvrir_fixture("ext4-du.img", &v), FL_OK);
  fl_stat st;
  int rc = fl_fs_stat(v.fs, "/creux.bin", &st);
  demonter(&v);
  TT_ASSERT_EQ(rc, FL_OK);
  TT_ASSERT_EQ(st.size, GIO);
  TT_ASSERT(st.alloc > 0 && st.alloc <= 16384);
}

static void test_ext4HardLinksShareIno(void) {
  vol v;
  TT_ASSERT_EQ(ouvrir_fixture("ext4-du.img", &v), FL_OK);
  fl_stat a, b, u;
  int rc = fl_fs_stat(v.fs, "/lien-a.bin", &a);
  if (rc == FL_OK) rc = fl_fs_stat(v.fs, "/lien-b.bin", &b);
  if (rc == FL_OK) rc = fl_fs_stat(v.fs, "/un-octet.bin", &u);
  demonter(&v);
  TT_ASSERT_EQ(rc, FL_OK);
  TT_ASSERT(a.ino != 0);
  TT_ASSERT_EQ(a.ino, b.ino);
  TT_ASSERT_EQ(a.nlink, 2);
  TT_ASSERT_EQ(b.nlink, 2);
  TT_ASSERT_EQ(a.alloc, b.alloc);
  TT_ASSERT_EQ(u.nlink, 1);
  TT_ASSERT(u.ino != a.ino);
}

/* Inode marqué HUGE_FILE (fonction huge_file du superbloc) : i_blocks compte des blocs de 4 Kio, plus des
 * secteurs de 512 octets. Le drapeau d'extents (0x80000) est gardé. */
static void test_ext4HugeFileFlagCountsBlocks(void) {
  if (!fu_tools_available()) {
    fprintf(stderr, "debugfs absent (Android) : sauté\n");
    return;
  }
  char copie[4096], out[4096];
  TT_ASSERT_EQ(fu_copy_image(tt_fixture("ext4-du.img"), copie, sizeof copie), 0);
  char *argv[] = {"debugfs", "-w", "-R", "sif /dix-mille.bin flags 0xC0000", copie, NULL};
  int rc = fu_run(argv, out, sizeof out);
  vol v;
  memset(&v, 0, sizeof v);
  int mrc = rc == 0 ? monter(copie, false, &v) : FL_EIO;
  uint64_t alloc = mrc == FL_OK ? alloc_de(v.fs, "/dix-mille.bin") : 0;
  if (mrc == FL_OK) demonter(&v);
  unlink(copie);
  TT_ASSERT_EQ(rc, 0);
  TT_ASSERT_EQ(mrc, FL_OK);
  TT_ASSERT_EQ(alloc, 12288 / 512 * 4096); /* i_blocks = 24 */
}

/* --- FAT32 et exFAT ------------------------------------------------------------------------------ */

/* Arbre écrit par le moteur sur une copie de `fixture`, puis jugé : chaque fichier à sa taille arrondie au
 * cluster (`cl` octets), un cluster par dossier. /G (300 entrées à nom long) occupe plusieurs clusters selon
 * le juge : le moteur n'en compte qu'un (décision 6 du plan). */
static void fat_cas(const char *fixture, uint64_t cl) {
  if (!fu_fat_tools_available()) {
    fprintf(stderr, "outils FAT absents (Android) : sauté\n");
    return;
  }
  vol v;
  int rc = ouvrir_copie(fixture, &v);
  if (rc == FL_OK) rc = ecrire(v.fs, "/un-octet.bin", 1);
  if (rc == FL_OK) rc = ecrire(v.fs, "/dix-mille.bin", 10000);
  if (rc == FL_OK) rc = ecrire(v.fs, "/vide.bin", 0);
  if (rc == FL_OK) rc = fl_fs_mkdir(v.fs, "/D");
  if (rc == FL_OK) rc = ecrire(v.fs, "/D/dedans.txt", 5000);
  if (rc == FL_OK) rc = fl_fs_mkdir(v.fs, "/G");
  for (int i = 0; rc == FL_OK && i < 300; i++) {
    char p[64];
    snprintf(p, sizeof p, "/G/un nom de fichier assez long %03d.txt", i);
    rc = ecrire(v.fs, p, 1);
  }
  if (rc == FL_OK) rc = remonter(&v);
  char *texte = NULL;
  manifeste m = {NULL, 0};
  int j = rc == FL_OK ? juger(false, v.copie, &texte, &m) : -1;
  int ecarts = j == 0 ? comparer(v.fs, &m, "/G") : -1;
  uint64_t a1 = 0, a10k = 0, a0 = 0, ad = 0, ag = 0, ar = 0, juge_g = 0;
  if (rc == FL_OK) {
    a1 = alloc_de(v.fs, "/un-octet.bin");
    a10k = alloc_de(v.fs, "/dix-mille.bin");
    a0 = alloc_de(v.fs, "/vide.bin");
    ad = alloc_de(v.fs, "/D");
    ag = alloc_de(v.fs, "/G");
    ar = alloc_de(v.fs, "/");
  }
  const ligne *lg = j == 0 ? chercher(&m, "/G") : NULL;
  if (lg) juge_g = lg->alloc;
  liberer(&v);
  free(m.v);
  free(texte);
  TT_ASSERT_EQ(rc, FL_OK);
  TT_ASSERT_EQ(j, 0);
  TT_ASSERT_EQ(ecarts, 0);
  TT_ASSERT_EQ(a1, cl);
  TT_ASSERT_EQ(a10k, (10000 + cl - 1) / cl * cl);
  TT_ASSERT_EQ(a0, 0);
  TT_ASSERT_EQ(ad, cl);
  TT_ASSERT_EQ(ar, cl);
  TT_ASSERT_EQ(ag, cl);
  TT_ASSERT(juge_g > cl); /* 300 noms longs : 38 Kio d'entrées en FAT32, 47 Kio en exFAT */
}

static void test_fatAllocClusterRounded(void) { fat_cas("fat32-vide.img", 4096); }   /* mkfs.vfat -F 32 -s 8 */
static void test_exfatAllocClusterRounded(void) { fat_cas("exfat-32k.img", 32768); } /* mkfs.exfat -c 32K */

/* Racine fixe de FAT12/16 : hors des clusters. */
static void test_fat16RootAllocZero(void) {
  vol v;
  TT_ASSERT_EQ(ouvrir_fixture("fat16-arbre.img", &v), FL_OK);
  fl_stat st;
  int rc = fl_fs_stat(v.fs, "/", &st);
  demonter(&v);
  TT_ASSERT_EQ(rc, FL_OK);
  TT_ASSERT_EQ(st.alloc, 0);
  TT_ASSERT_EQ(st.ino, 0);
  TT_ASSERT_EQ(st.nlink, 1);
}

/* --- NTFS ----------------------------------------------------------------------------------------- */

static void test_ntfsAllocMatchesJudge(void) {
  if (!fu_ntfs_tools_available()) {
    fprintf(stderr, "outils NTFS absents (Android) : sauté\n");
    return;
  }
  vol v;
  int rc = ouvrir_copie("ntfs-vide.img", &v); /* clusters de 4 Kio */
  if (rc == FL_OK) rc = ecrire(v.fs, "/petit.txt", 100);
  if (rc == FL_OK) rc = ecrire(v.fs, "/dix-mille.bin", 10000);
  if (rc == FL_OK) rc = ecrire(v.fs, "/vide.bin", 0);
  if (rc == FL_OK) rc = fl_fs_mkdir(v.fs, "/petit-dossier");
  if (rc == FL_OK) rc = fl_fs_mkdir(v.fs, "/gros-dossier");
  for (int i = 0; rc == FL_OK && i < 300; i++) {
    char p[64];
    snprintf(p, sizeof p, "/gros-dossier/f-%03d", i);
    rc = ecrire(v.fs, p, 1);
  }
  if (rc == FL_OK) rc = remonter(&v);
  char *texte = NULL;
  manifeste m = {NULL, 0};
  int j = rc == FL_OK ? juger(true, v.copie, &texte, &m) : -1;
  int ecarts = j == 0 ? comparer(v.fs, &m, NULL) : -1;
  uint64_t petit = 0, dixk = 0, pd = 0, gd = 0;
  fl_stat st = {0};
  if (rc == FL_OK) {
    petit = alloc_de(v.fs, "/petit.txt");
    dixk = alloc_de(v.fs, "/dix-mille.bin");
    pd = alloc_de(v.fs, "/petit-dossier");
    gd = alloc_de(v.fs, "/gros-dossier");
    (void)fl_fs_stat(v.fs, "/dix-mille.bin", &st);
  }
  liberer(&v);
  free(m.v);
  free(texte);
  TT_ASSERT_EQ(rc, FL_OK);
  TT_ASSERT_EQ(j, 0);
  TT_ASSERT_EQ(ecarts, 0);
  TT_ASSERT_EQ(petit, 0);    /* résident */
  TT_ASSERT_EQ(dixk, 12288);
  TT_ASSERT_EQ(pd, 0);       /* index résident */
  TT_ASSERT(gd >= 4096 && gd % 4096 == 0);
  TT_ASSERT(st.ino >= 16);   /* premier enregistrement des fichiers de l'utilisateur */
  TT_ASSERT_EQ(st.nlink, 1);
}

int main(void) {
  TT_RUN(test_ext4AllocMatchesDebugfs);
  TT_RUN(test_ext4SparseFileAllocSmall);
  TT_RUN(test_ext4HardLinksShareIno);
  TT_RUN(test_ext4HugeFileFlagCountsBlocks);
  TT_RUN(test_fatAllocClusterRounded);
  TT_RUN(test_exfatAllocClusterRounded);
  TT_RUN(test_fat16RootAllocZero);
  TT_RUN(test_ntfsAllocMatchesJudge);
  TT_MAIN_END();
}

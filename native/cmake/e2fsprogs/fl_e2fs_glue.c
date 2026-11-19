/* État partagé entre e2fsprogs et le moteur (src/partops/e2fs.c), sans dépendance de e2fsprogs vers le
 * moteur : celui-ci remplit ces variables avant chaque appel, sous son verrou, sur le fil qui appelle
 * e2fsck ou resize2fs. */
#define FL_E2FS_GLUE_IMPL
#include "fl_e2fs_glue.h"

#include <setjmp.h>
#include <fcntl.h>
#include <stdint.h>
#include <sys/stat.h>
#include <string.h>

#include "e2fsck.h"
#include "blkid/blkid.h"
#include "support/plausible.h"
#include "support/prof_err.h"
#include "fl_e2fs_state.h"

extern e2fsck_t e2fsck_global_ctx; /* unix.c */
errcode_t fl_e2fs_get_device_size2(const char *file, int blocksize, blk64_t *retblocks);

io_manager fl_e2fs_io_manager;
FILE *fl_e2fs_report;
jmp_buf *fl_e2fs_jump;
int fl_e2fs_exit_code;

FILE *fl_e2fs_stdout(void) { return fl_e2fs_report ? fl_e2fs_report : stderr; }

int fl_e2fs_puts(const char *s) {
  FILE *f = fl_e2fs_stdout();
  if (fputs(s, f) == EOF) return EOF;
  return fputc('\n', f);
}

/* --- systèmes de fichiers ouverts par e2fsck ------------------------------------------------------
 * main garde le sien dans une variable locale (ouvert avec EXT2_FLAG_NOFREE_ON_ERROR) : sans ce suivi, un
 * exit() au milieu le perdrait. */
#define FL_E2FS_SLOTS 8
static ext2_filsys g_open[FL_E2FS_SLOTS];

static void untrack(ext2_filsys fs) {
  for (int i = 0; fs && i < FL_E2FS_SLOTS; i++)
    if (g_open[i] == fs) g_open[i] = NULL;
}

errcode_t fl_e2fs_open2(const char *name, const char *io_options, int flags, int superblock,
                        unsigned int block_size, io_manager manager, ext2_filsys *ret_fs) {
  errcode_t e = ext2fs_open2(name, io_options, flags, superblock, block_size, manager, ret_fs);
  if (*ret_fs) {
    for (int i = 0; i < FL_E2FS_SLOTS; i++)
      if (!g_open[i]) {
        g_open[i] = *ret_fs;
        break;
      }
  }
  return e;
}

errcode_t fl_e2fs_close_free(ext2_filsys *fs) {
  untrack(*fs);
  return ext2fs_close_free(fs);
}

void fl_e2fs_free(ext2_filsys fs) {
  untrack(fs);
  ext2fs_free(fs);
}

/* exit() d'e2fsck (fatal_error, usage…) : le contexte d'e2fsck est libéré, puis retour à l'appelant.
 * Hors d'un appel du moteur, il n'y a nulle part où revenir : abort(), qui ne doit jamais arriver. */
void fl_e2fs_exit(int code) {
  if (!fl_e2fs_jump) abort();
  fl_e2fs_exit_code = code;
  e2fsck_t ctx = e2fsck_global_ctx;
  e2fsck_global_ctx = NULL;
  if (ctx) {
    if (ctx->fs) fl_e2fs_close_free(&ctx->fs);
    free(ctx->journal_name);
    ctx->journal_name = NULL;
    e2fsck_free_context(ctx);
  }
  for (int i = 0; i < FL_E2FS_SLOTS; i++) {
    if (g_open[i]) ext2fs_free(g_open[i]); /* lecture seule : rien à écrire */
    g_open[i] = NULL;
  }
  remove_error_table(&et_ext2_error_table);
  remove_error_table(&et_prof_error_table);
  longjmp(*fl_e2fs_jump, 1);
}

void fl_e2fs_reset_globals(void) {
  e2fsck_global_ctx = NULL;
  memset(g_open, 0, sizeof g_open);
}

/* Taille du volume pour e2fsck et resize2fs (ext2fs_get_device_size2 renommée dans leurs fichiers) : le
 * nom « fl-volume » n'est pas un fichier, sa taille vient du moteur. */
uint64_t fl_e2fs_dev_bytes;

errcode_t fl_e2fs_get_device_size2(const char *file, int blocksize, blk64_t *retblocks) {
  if (file && strcmp(file, FL_E2FS_DEVNAME) == 0) {
    if (blocksize <= 0) return EXT2_ET_INVALID_ARGUMENT;
    *retblocks = fl_e2fs_dev_bytes / (uint64_t)blocksize;
    return 0;
  }
  return ext2fs_get_device_size2(file, blocksize, retblocks);
}

/* --- remplaçants de ce qui n'est pas compilé ------------------------------------------------------
 * unix_io.c (accès aux fichiers, remplacé par src/fs/e2fs_io.c) : seules ces deux aides servent encore
 * (getsize.c, getsectsize.c, pour des noms qui ne sont pas notre volume). */
int ext2fs_open_file(const char *pathname, int flags, mode_t mode) {
  return mode ? open(pathname, flags, mode) : open(pathname, flags);
}

int ext2fs_fstat(int fd, ext2fs_struct_stat *buf) { return fstat(fd, buf); }

/* sigcatcher.c : aucun gestionnaire de signal posé dans le processus de l'application. */
void sigcatcher_setup(void) {}

/* libblkid : e2fsck ne s'en sert que pour traduire un nom (LABEL=…, UUID=…) en périphérique et trouver
 * un journal externe ; notre volume a un nom simple et un journal externe n'est pas pris en charge. */
int blkid_get_cache(blkid_cache *cache, const char *filename) {
  (void)filename;
  *cache = NULL;
  return 0;
}

void blkid_put_cache(blkid_cache cache) { (void)cache; }

char *blkid_devno_to_devname(dev_t devno) {
  (void)devno;
  return NULL;
}

char *blkid_get_tag_value(blkid_cache cache, const char *tagname, const char *devname) {
  (void)cache;
  (void)tagname;
  (void)devname;
  return NULL;
}

char *blkid_get_devname(blkid_cache cache, const char *token, const char *value) {
  (void)cache;
  if (!token || value || strchr(token, '=')) return NULL;
  return strdup(token);
}

/* check_plausibility d'e2fsck (superbloc illisible) : cherche un fichier du nom du volume et finit par
 * exit(1) s'il n'existe pas. Notre volume existe toujours : rien à dire, e2fsck s'arrête sur son code 8. */
int fl_e2fs_check_plausibility(const char *device, int flags, int *ret_is_dev) {
  if (device && strcmp(device, FL_E2FS_DEVNAME) == 0) {
    if (ret_is_dev) *ret_is_dev = 1;
    return 1;
  }
  return check_plausibility(device, flags, ret_is_dev);
}

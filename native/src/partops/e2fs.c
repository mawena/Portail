/* ext4 par e2fsprogs (phase 18) : vérification en lecture seule (e2fsck -fn), taille minimale et
 * redimensionnement (resize2fs), étiquette. e2fsprogs a un état global : un seul appel à la fois, sur un
 * fil à pile de 8 Mio ; exit() d'e2fsck revient ici par longjmp (cmake/e2fsprogs/fl_e2fs_glue.c). */

#define _GNU_SOURCE

#include <errno.h>
#include <getopt.h>
#include <pthread.h>
#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ext2fs/ext2_fs.h"
#include "ext2fs/ext2fs.h"
#include "fl_e2fs_state.h"
#include "fluluks/error.h"
#include "fluluks/partops.h"
#include "fs/e2fs_io.h"
#include "partops/tool_run.h"
#include "resize2fs.h"

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;

/* --- appel sous le verrou ---------------------------------------------------------------------- */

/* Lie le volume, la sortie et l'accès au disque, puis lance fn(arg) sur un fil à pile de 8 Mio. */
static int run_locked(fl_bdev *vol, fl_capture *out, int (*fn)(void *), void *arg) {
  if (!vol) return FL_EINVAL;
  pthread_mutex_lock(&g_lock);
  fl_capture scratch = {0};
  FILE *f = fl_capture_open(out ? out : &scratch);
  if (!f) {
    pthread_mutex_unlock(&g_lock);
    return FL_ENOMEM;
  }
  fl_e2fs_report = f;
  fl_e2fs_io_manager = fl_e2fs_bdev_manager();
  fl_e2fs_dev_bytes = fl_bdev_size_bytes(vol);
  fl_e2fs_io_bind(vol);

  int rc = fl_run_big_stack(fn, arg);

  fl_e2fs_io_bind(NULL);
  fl_e2fs_report = NULL;
  fclose(f);
  pthread_mutex_unlock(&g_lock);
  return rc;
}

/* Code d'erreur d'e2fsprogs → FL_E… ; une erreur du disque l'emporte (débranché, délai). */
static int map_err(errcode_t e) {
  int io = fl_e2fs_io_error();
  if (io != FL_OK) return io;
  if (e == 0) return FL_OK;
  switch (e) {
    case ENOMEM:
    case EXT2_ET_NO_MEMORY: return FL_ENOMEM;
    case EROFS: return FL_EROFS;
    case EXT2_ET_UNSUPP_FEATURE:
    case EXT2_ET_RO_UNSUPP_FEATURE: return FL_ENOTSUP;
    case EXT2_ET_SHORT_READ:
    case EXT2_ET_SHORT_WRITE: return FL_EIO;
    default: return FL_ECORRUPT;
  }
}

static errcode_t open_fs(int flags, ext2_filsys *fs) {
  errcode_t e = ext2fs_open2(FL_E2FS_DEVNAME, NULL, flags | EXT2_FLAG_64BITS, 0, 0, fl_e2fs_bdev_manager(), fs);
  if (e == 0) (*fs)->default_bitmap_type = EXT2FS_BMAP64_RBTREE;
  return e;
}

/* Conditions de resize2fs avant d'agir (main.c d'amont), sauf la date du dernier e2fsck : notre
 * vérification est en lecture seule et ne la met pas à jour ; elle est exigée juste avant (T6). */
static bool needs_fsck(struct ext2_super_block *sb) {
  return (sb->s_state & EXT2_ERROR_FS) || !(sb->s_state & EXT2_VALID_FS) ||
         ext2fs_free_blocks_count(sb) > ext2fs_blocks_count(sb) ||
         sb->s_free_inodes_count > sb->s_inodes_count || sb->s_last_orphan != 0 ||
         ext2fs_has_feature_journal_needs_recovery(sb);
}

/* --- e2fsck -fn --------------------------------------------------------------------------------- */

typedef struct {
  int code;
  bool sb_ok;
  int rc;
} check_job;

static int do_check(void *p) {
  check_job *c = p;
  jmp_buf jb;
  volatile int code = 8;
  fl_e2fs_jump = &jb;
  if (setjmp(jb) == 0) {
    char a0[] = "e2fsck", a1[] = "-fn", a2[] = FL_E2FS_DEVNAME;
    char *argv[] = {a0, a1, a2, NULL};
#ifdef __GLIBC__
    optind = 0; /* remise à zéro complète de getopt */
#else
    optind = 1;
    optreset = 1;
#endif
    fl_e2fs_reset_globals();
    code = fl_e2fsck_main(3, argv);
  } else {
    /* arrêt par exit() hors des codes d'une vérification faite : vérification impossible */
    code = fl_e2fs_exit_code;
    if (code != 0 && code != 4) code |= 8;
  }
  fl_e2fs_jump = NULL;
  c->code = code;
  c->rc = fl_e2fs_io_error();
  if (c->rc == FL_OK && code < 8) {
    ext2_filsys fs = NULL;
    if (open_fs(0, &fs) == 0) {
      c->sb_ok = !needs_fsck(fs->super);
      ext2fs_close_free(&fs);
    }
  }
  return FL_OK;
}

int fl_e2fs_check(fl_bdev *vol, fl_check_report *out) {
  if (!out) return FL_EINVAL;
  memset(out, 0, sizeof *out);
  fl_capture cap = {out->report, sizeof out->report, 0};
  check_job c = {0};
  int rc = run_locked(vol, &cap, do_check, &c);
  if (rc != FL_OK) return rc;
  out->exit_code = c.code;
  out->clean = c.code == 0 && c.sb_ok;
  if (c.rc != FL_OK) return c.rc;
  if (c.code == 0 && !c.sb_ok) {
    size_t n = strlen(out->report);
    snprintf(out->report + n, sizeof out->report - n, "%s",
             "\nLe journal doit être rejoué ou le système de fichiers est marqué en erreur : "
             "vérifiez-le sous Linux (e2fsck -f).\n");
  }
  return c.code >= 8 ? FL_ECORRUPT : FL_OK;
}

/* --- resize2fs ---------------------------------------------------------------------------------- */

typedef struct {
  uint64_t new_bytes; /* 0 : taille minimale seulement */
  uint64_t min_bytes;
  fl_progress_fn cb;
  void *arg;
  int last_pct;
} resize_job;

static resize_job *g_rj; /* sous le verrou */

static errcode_t resize_progress(ext2_resize_t rfs, int pass, unsigned long cur, unsigned long max) {
  (void)rfs;
  resize_job *r = g_rj;
  if (!r || !r->cb || pass < 1) return 0;
  int part = max ? (int)((unsigned long long)cur * 100 / max) : 100;
  int pct = ((pass - 1) * 100 + part) / 5;
  if (pct > 99) pct = 99;
  if (pct > r->last_pct) {
    r->last_pct = pct;
    r->cb(pct, r->arg);
  }
  return 0;
}

static int do_resize(void *p) {
  resize_job *r = p;
  jmp_buf jb;
  ext2_filsys volatile fs = NULL;
  volatile int rc = FL_OK;
  fl_e2fs_jump = &jb;
  if (setjmp(jb) != 0) {
    /* exit() appelé par resize2fs (manque de mémoire dans ses tables) */
    rc = map_err(EXT2_ET_NO_MEMORY);
    goto out;
  }
  ext2_filsys f = NULL;
  errcode_t e = open_fs(r->new_bytes ? EXT2_FLAG_RW : 0, &f);
  if (e) {
    rc = map_err(e);
    goto out;
  }
  fs = f;
  if (needs_fsck(f->super)) {
    rc = FL_ECORRUPT;
    goto out;
  }
  if (f->super->s_feature_compat & ~EXT2_LIB_FEATURE_COMPAT_SUPP) {
    rc = FL_ENOTSUP;
    goto out;
  }
  unsigned bs = EXT2_BLOCK_SIZE(f->super);
  blk64_t min = calculate_minimum_resize_size(f, 0);
  r->min_bytes = (uint64_t)min * bs;
  if (!r->new_bytes) goto out;

  blk64_t ns = r->new_bytes / bs, cur = ext2fs_blocks_count(f->super);
  if (ns > fl_e2fs_dev_bytes / bs || ns < min) {
    rc = FL_EINVAL;
    goto out;
  }
  if (!ext2fs_has_feature_64bit(f->super)) {
    if (ns == (1ULL << 32))
      ns--;
    else if (ns > (1ULL << 32)) {
      rc = FL_EFBIG;
      goto out;
    }
  }
  if (ext2fs_has_feature_bigalloc(f->super)) ns &= ~((blk64_t)(1ULL << f->cluster_ratio_bits) - 1);
  if (!ext2fs_has_feature_meta_bg(f->super)) {
    dgrp_t groups = ext2fs_div64_ceil(ns - f->super->s_first_data_block, EXT2_BLOCKS_PER_GROUP(f->super));
    unsigned long desc = ext2fs_div_ceil(groups, EXT2_DESC_PER_BLOCK(f->super));
    if (desc + f->super->s_first_data_block > EXT2_BLOCKS_PER_GROUP(f->super)) {
      rc = FL_EINVAL;
      goto out;
    }
  }
  if (ns < min) {
    rc = FL_EINVAL;
    goto out;
  }
  if (ns < cur && ext2fs_has_feature_stable_inodes(f->super)) {
    rc = FL_ENOTSUP;
    goto out;
  }
  if (ns == cur) goto out;
  g_rj = r;
  e = resize_fs(f, &ns, 0, resize_progress);
  g_rj = NULL;
  if (e == 0) {
    fs = NULL; /* fermé et libéré par resize_fs */
    if (r->cb) r->cb(100, r->arg);
  } else {
    rc = map_err(e);
    if (rc == FL_ECORRUPT) rc = FL_EIO;
  }
out:
  g_rj = NULL;
  fl_e2fs_jump = NULL;
  if (fs) {
    ext2_filsys f2 = fs;
    errcode_t ce = ext2fs_close_free(&f2);
    if (rc == FL_OK && ce) rc = map_err(ce);
  }
  remove_error_table(&et_ext2_error_table);
  return rc;
}

int fl_e2fs_min_size(fl_bdev *vol, uint64_t *bytes) {
  if (!bytes) return FL_EINVAL;
  resize_job r = {0};
  int rc = run_locked(vol, NULL, do_resize, &r);
  if (rc == FL_OK) *bytes = r.min_bytes;
  return rc;
}

int fl_e2fs_resize(fl_bdev *vol, uint64_t new_bytes, fl_progress_fn cb, void *arg) {
  if (!new_bytes) return FL_EINVAL;
  resize_job r = {.new_bytes = new_bytes, .cb = cb, .arg = arg, .last_pct = -1};
  return run_locked(vol, NULL, do_resize, &r);
}

/* --- étiquette ---------------------------------------------------------------------------------- */

typedef struct {
  const char *label;
} label_job;

static int do_label(void *p) {
  label_job *l = p;
  ext2_filsys fs = NULL;
  errcode_t e = open_fs(EXT2_FLAG_RW, &fs);
  if (e) return map_err(e);
  if (needs_fsck(fs->super)) {
    ext2fs_free(fs);
    return FL_ECORRUPT;
  }
  /* comme tune2fs -L : superbloc et ses copies, pas les descripteurs de groupes */
  fs->flags |= EXT2_FLAG_SUPER_ONLY;
  memset(fs->super->s_volume_name, 0, sizeof fs->super->s_volume_name);
  memcpy(fs->super->s_volume_name, l->label, strlen(l->label));
  ext2fs_mark_super_dirty(fs);
  return map_err(ext2fs_close_free(&fs));
}

int fl_e2fs_set_label(fl_bdev *vol, const char *label) {
  if (!vol || !label || strlen(label) > EXT2_LABEL_LEN) return FL_EINVAL;
  label_job l = {label};
  return run_locked(vol, NULL, do_label, &l);
}

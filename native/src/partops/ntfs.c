/* NTFS par ntfs-3g (phase 18) : vérification en lecture seule (ntfsfix -n, puis la vérification de cohérence
 * de ntfsresize --info), taille minimale et redimensionnement (ntfsresize), étiquette (ntfs_volume_rename,
 * comme ntfslabel). Sous le verrou commun des systèmes de fichiers, sur un fil à pile de 8 Mio. */

#define _GNU_SOURCE

#include <errno.h>
#include <pthread.h>
#include <setjmp.h>
#include <stdlib.h>
#include <string.h>

#include "fluluks/error.h"
#include "fluluks/partops.h"
#include "format/format_internal.h"
#include "fs/fs_internal.h"
#include "fs/ntfs_dev.h"
#include "ntfs-3g/volume.h"
#include "ntfs-3g/unistr.h"
#include "partops/ntfs_tool.h"
#include "partops/tool_run.h"

#define g_lock (*fl_fs_glue_lock())

enum { JOB_CHECK, JOB_INFO, JOB_RESIZE };

typedef struct {
  int kind;
  fl_bdev *vol;
  FILE *out;
  long long new_bytes;
  fl_progress_fn cb;
  void *arg;
  /* résultats */
  long long min_bytes;
  bool dirty, mounted;
  int code_fix, code_resize;
  int io;
} nt_job;

/* Un outil, exit() rattrapé : son code (0 : réussite). */
static int call_tool(nt_job *j, int which) {
  jmp_buf jb;
  volatile int code = 1;
  fl_ntt_jump = &jb;
  if (setjmp(jb) == 0) {
    if (which == JOB_CHECK)
      code = fl_ntt_fixcheck(&j->dirty, &j->mounted);
    else
      code = fl_ntt_resize((long long)fl_bdev_size_bytes(j->vol), which == JOB_RESIZE ? j->new_bytes : 0,
                           &j->min_bytes, (fl_ntt_progress)j->cb, j->arg);
  } else {
    code = fl_ntt_exit_code;
  }
  fl_ntt_jump = NULL;
  fl_ntt_resize_cleanup();
  return code;
}

static int do_job(void *p) {
  nt_job *j = p;
  fl_ntt_begin(j->vol, j->kind == JOB_RESIZE, j->out);
  if (j->kind == JOB_CHECK) {
    j->code_fix = call_tool(j, JOB_CHECK);
    if (j->mounted && fl_ntt_io_error() == FL_OK) {
      fprintf(j->out, "\n");
      j->code_resize = call_tool(j, JOB_INFO);
    } else {
      j->code_resize = 1;
    }
  } else if (j->kind == JOB_INFO) {
    j->code_resize = call_tool(j, JOB_INFO);
  } else {
    j->code_resize = call_tool(j, JOB_INFO);
    if (j->code_resize == 0 && fl_ntt_io_error() == FL_OK) {
      if (j->new_bytes < j->min_bytes) {
        j->code_resize = -1; /* sous le minimum : refusé avant toute écriture */
      } else {
        fl_ntt_end();
        fl_ntt_begin(j->vol, true, j->out);
        j->code_resize = call_tool(j, JOB_RESIZE);
      }
    }
  }
  j->io = fl_ntt_end();
  return FL_OK;
}

static int run(nt_job *j, fl_capture *cap) {
  if (!j->vol) return FL_EINVAL;
  fl_capture scratch = {0};
  pthread_mutex_lock(&g_lock);
  j->out = fl_capture_open(cap ? cap : &scratch);
  int rc = FL_ENOMEM;
  if (j->out) {
    rc = fl_run_big_stack(do_job, j);
    fclose(j->out);
    j->out = NULL;
  }
  pthread_mutex_unlock(&g_lock);
  return rc;
}

int fl_ntfs_check(fl_bdev *vol, fl_check_report *out) {
  if (!out) return FL_EINVAL;
  memset(out, 0, sizeof *out);
  fl_capture cap = {out->report, sizeof out->report, 0};
  nt_job j = {.kind = JOB_CHECK, .vol = vol};
  int rc = run(&j, &cap);
  if (rc != FL_OK) return rc;
  if (j.io != FL_OK) return j.io;
  out->exit_code = j.code_fix || j.code_resize ? 1 : 0;
  out->clean = out->exit_code == 0 && !j.dirty;
  return j.mounted ? FL_OK : FL_ECORRUPT;
}

int fl_ntfs_min_size(fl_bdev *vol, uint64_t *bytes) {
  if (!bytes) return FL_EINVAL;
  nt_job j = {.kind = JOB_INFO, .vol = vol};
  int rc = run(&j, NULL);
  if (rc != FL_OK) return rc;
  if (j.io != FL_OK) return j.io;
  if (j.code_resize != 0 || j.min_bytes <= 0) return FL_ECORRUPT;
  *bytes = (uint64_t)j.min_bytes;
  return FL_OK;
}

int fl_ntfs_resize(fl_bdev *vol, uint64_t new_bytes, fl_progress_fn cb, void *arg) {
  if (!vol || !new_bytes || new_bytes > fl_bdev_size_bytes(vol)) return FL_EINVAL;
  nt_job j = {.kind = JOB_RESIZE, .vol = vol, .new_bytes = (long long)new_bytes, .cb = cb, .arg = arg};
  int rc = run(&j, NULL);
  if (rc != FL_OK) return rc;
  if (j.io != FL_OK) return j.io;
  if (j.code_resize == -1) return FL_EINVAL;
  if (j.code_resize != 0) return j.min_bytes ? FL_EIO : FL_ECORRUPT;
  return FL_OK;
}

int fl_ntfs_set_label(fl_bdev *vol, const char *label) {
  if (!vol || !label || fl_fmt_check_label(FL_FMT_NTFS, label) != FL_OK) return FL_EINVAL;
  ntfschar *u = NULL;
  int n = ntfs_mbstoucs(label, &u);
  if (n < 0) return FL_EINVAL;
  pthread_mutex_lock(&g_lock);
  ntfs_dev *dd = NULL;
  int rc = ntfs_dev_new(vol, true, &dd);
  if (rc == FL_OK) {
    ntfs_volume *v = ntfs_device_mount(ntfs_dev_device(dd), NTFS_MNT_NONE);
    if (!v) {
      int e = errno;
      rc = ntfs_dev_error(dd);
      if (rc == FL_OK) rc = e == ENOMEM ? FL_ENOMEM : FL_ECORRUPT;
      ntfs_dev_free(dd, true);
    } else {
      int r = ntfs_volume_rename(v, u, n);
      int e = errno;
      int u_rc = ntfs_umount(v, FALSE);
      rc = ntfs_dev_error(dd);
      if (rc == FL_OK && (r || u_rc)) rc = e == ENOMEM ? FL_ENOMEM : FL_EIO;
      ntfs_dev_free(dd, false);
    }
  }
  pthread_mutex_unlock(&g_lock);
  free(u);
  return rc;
}

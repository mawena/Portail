/* Voir ntfs_tool.h : volumes et périphériques ouverts par ntfsresize et ntfsfix, suivis pour être tous
 * rendus à la fin de l'appel, même après un exit() au milieu. */

#define _GNU_SOURCE /* struct stat complet pour les en-têtes de libntfs-3g */

#include "partops/ntfs_tool.h"

#include <errno.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>

#include "fluluks/error.h"
#include "fs/ntfs_dev.h"
#include "ntfs-3g/logging.h"

#define SLOTS 8

typedef struct {
  ntfs_dev *dd;
  struct ntfs_device *dev; /* NULL : libéré (ntfs_umount ou ntfs_device_free) */
  ntfs_volume *vol;        /* volume monté sur dev, s'il y en a un */
} slot;

static fl_bdev *g_bd;
static bool g_writable;
static FILE *g_out;
static slot g_slots[SLOTS];
static int g_err;

jmp_buf *fl_ntt_jump;
int fl_ntt_exit_code;
struct ntfs_device_operations fl_ntt_dummy_ops; /* jamais utilisé : remplace ntfs_device_default_io_ops */

FILE *fl_ntt_out(void) { return g_out ? g_out : stderr; }

void fl_ntt_exit(int code) {
  if (!fl_ntt_jump) abort();
  fl_ntt_exit_code = code;
  longjmp(*fl_ntt_jump, 1);
}

static int log_to_report(const char *function, const char *file, int line, u32 level, void *data,
                         const char *format, va_list args) {
  (void)function;
  (void)file;
  (void)line;
  (void)data;
  if (level & (NTFS_LOG_LEVEL_DEBUG | NTFS_LOG_LEVEL_TRACE | NTFS_LOG_LEVEL_ENTER | NTFS_LOG_LEVEL_LEAVE))
    return 0;
  int n = vfprintf(fl_ntt_out(), format, args);
  if (level & NTFS_LOG_LEVEL_PERROR) fprintf(fl_ntt_out(), " : %s\n", strerror(errno));
  return n;
}

void fl_ntt_begin(fl_bdev *bd, bool writable, FILE *out) {
  g_bd = bd;
  g_writable = writable;
  g_out = out;
  g_err = FL_OK;
  memset(g_slots, 0, sizeof g_slots);
  ntfs_log_set_handler(log_to_report);
}

static void note_err(slot *s) {
  if (s->dd && g_err == FL_OK) g_err = ntfs_dev_error(s->dd);
}

int fl_ntt_io_error(void) {
  for (int i = 0; i < SLOTS; i++) note_err(&g_slots[i]);
  return g_err;
}

int fl_ntt_end(void) {
  for (int i = 0; i < SLOTS; i++) {
    slot *s = &g_slots[i];
    if (!s->dd) continue;
    if (s->vol) {
      ntfs_umount(s->vol, TRUE);
      s->vol = NULL;
      s->dev = NULL;
    }
    note_err(s);
    ntfs_dev_free(s->dd, s->dev != NULL);
    memset(s, 0, sizeof *s);
  }
  ntfs_log_set_handler(ntfs_log_handler_null);
  g_bd = NULL;
  g_out = NULL;
  return g_err;
}

static slot *by_dev(struct ntfs_device *dev) {
  for (int i = 0; dev && i < SLOTS; i++)
    if (g_slots[i].dd && g_slots[i].dev == dev) return &g_slots[i];
  return NULL;
}

struct ntfs_device *fl_ntt_device_alloc(const char *name, int state, struct ntfs_device_operations *dops,
                                        void *priv_data) {
  (void)name;
  (void)state;
  (void)dops;
  (void)priv_data;
  for (int i = 0; i < SLOTS; i++) {
    slot *s = &g_slots[i];
    if (s->dd) continue;
    if (!g_bd || ntfs_dev_new(g_bd, g_writable, &s->dd) != FL_OK) {
      s->dd = NULL;
      errno = ENOMEM;
      return NULL;
    }
    s->dev = ntfs_dev_device(s->dd);
    return s->dev;
  }
  errno = EMFILE;
  return NULL;
}

int fl_ntt_device_free(struct ntfs_device *dev) {
  slot *s = by_dev(dev);
  if (!s) return ntfs_device_free(dev);
  if (s->vol) {
    errno = EBUSY;
    return -1;
  }
  note_err(s);
  ntfs_dev_free(s->dd, true);
  memset(s, 0, sizeof *s);
  return 0;
}

ntfs_volume *fl_ntt_volume_startup(struct ntfs_device *dev, ntfs_mount_flags flags) {
  if (!g_writable) flags |= NTFS_MNT_RDONLY;
  ntfs_volume *v = ntfs_volume_startup(dev, flags);
  slot *s = by_dev(dev);
  if (v && s) s->vol = v;
  return v;
}

ntfs_volume *fl_ntt_mount(const char *name, ntfs_mount_flags flags) {
  if (!g_writable) flags |= NTFS_MNT_RDONLY;
  struct ntfs_device *dev = fl_ntt_device_alloc(name, 0, NULL, NULL);
  if (!dev) return NULL;
  ntfs_volume *v = ntfs_device_mount(dev, flags);
  slot *s = by_dev(dev);
  if (!v) {
    int e = errno;
    fl_ntt_device_free(dev);
    errno = e;
    return NULL;
  }
  s->vol = v;
  return v;
}

int fl_ntt_umount(ntfs_volume *vol, const BOOL force) {
  slot *s = vol ? by_dev(vol->dev) : NULL;
  if (!s) return ntfs_umount(vol, force);
  int r = ntfs_umount(vol, force); /* libère aussi le struct ntfs_device */
  note_err(s);
  ntfs_dev_free(s->dd, false);
  memset(s, 0, sizeof *s);
  return r;
}

int fl_ntt_check_if_mounted(const char *file, unsigned long *mnt_flags) {
  (void)file;
  *mnt_flags = 0; /* le moteur refuse en amont tout disque dont un volume est ouvert */
  return 0;
}

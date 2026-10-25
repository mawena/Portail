/* Moteur à poignées du pont JNI (voir handles.h). Sans jni.h : compilé aussi dans les tests PC.
 *
 * Protocole de la table (un seul mutex g_mu, une seule condition g_cv) :
 *   - acquire : entrée valide, du bon type et pas « en fermeture » → refs++ ; l'opération longue
 *     se fait ensuite HORS du mutex ; release : refs-- (et réveil si une fermeture attend).
 *   - fermeture : closing = vrai (plus aucun acquire ne réussit), attente de refs == 0, destruction
 *     de l'objet HORS du mutex, puis libération de l'entrée (génération + 1) et réveil.
 *   - une entrée en fermeture garde son type et son parent jusqu'à la fin de la destruction : un
 *     parent qui ferme ses enfants attend aussi ceux qu'un autre fil est en train de fermer.
 * Les enfants (volumes d'un disque, fichiers d'un volume, archives, flux age et disques de coffre d'un fichier) sont
 * créés pendant que l'opération tient une référence sur le parent : une fois les références du parent retombées à 0,
 * plus aucun enfant ne peut apparaître. */
#define _POSIX_C_SOURCE 200809L
#include "handles.h"

#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "fluluks/age.h"
#include "fluluks/archive.h"
#include "fluluks/blockdev.h"
#include "fluluks/cache.h"
#include "cJSON.h"
#include "fluluks/error.h"
#include "fluluks/format.h"
#include "fluluks/fs.h"
#include "fluluks/luks.h"
#include "fluluks/partition.h"
#include "fluluks/probe.h"
#include "fluluks/secure.h"
#include "fluluks/usb.h"

#define CACHE_BLOCK 65536u
#define CACHE_BLOCKS 256u

enum { T_FREE = 0, T_DISK = 1, T_VOL = 2, T_FILE = 3, T_ARC = 4, T_AGEW = 5, T_AGER = 6, T_LAST = T_AGER };

/* Type du parent d'une entrée qui en a un : un disque n'a de parent que s'il est un coffre posé sur un fichier. */
static int parent_type(int type) {
  switch (type) {
    case T_VOL: return T_DISK;
    case T_FILE: return T_VOL;
    default: return T_FILE; /* T_ARC, T_AGEW, T_AGER, T_DISK de coffre */
  }
}

/* Copie de la phrase de passe en mémoire sécurisée, le temps d'un appel (pass_drop sur tous les chemins). */
static int pass_take(const void *pass, size_t n, uint8_t **out) {
  *out = NULL;
  if (!pass || !n) return pass || !n ? FL_OK : FL_EINVAL;
  *out = fl_secure_alloc(n);
  if (!*out) return FL_ENOMEM;
  memcpy(*out, pass, n);
  return FL_OK;
}

static void pass_drop(uint8_t *p, size_t n) {
  if (p) fl_secure_free(p, n);
}

typedef struct {
  uint32_t gen; /* >= 1 dès la première utilisation */
  uint8_t type;
  bool closing;
  uint32_t refs;
  int64_t parent; /* poignée du parent (0 pour un disque) */
  void *obj;
} slot;

static slot g_tab[FJ_MAX];
static unsigned g_next; /* allocation tournante : une entrée libérée n'est pas réutilisée tout de suite */
static unsigned g_used;
static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_cv = PTHREAD_COND_INITIALIZER;

/* Détruit l'objet ; rend le code de la fermeture (synchronisation, démontage). */
typedef int (*destroy_fn)(void *obj, int64_t h);

static int64_t mkhandle(unsigned idx) { return (int64_t)(((uint64_t)g_tab[idx].gen << 16) | idx); }

/* Sous g_mu. NULL si la poignée est invalide, périmée ou d'un autre type. */
static slot *lookup(int64_t h, int type) {
  if (h <= 0) return NULL;
  uint64_t u = (uint64_t)h, idx = u & 0xFFFFu, gen = u >> 16;
  if (idx >= FJ_MAX || gen == 0 || gen > UINT32_MAX) return NULL;
  slot *s = &g_tab[idx];
  if (s->type != type || s->gen != (uint32_t)gen) return NULL;
  return s;
}

/* Enregistre un objet. Un enfant (volume, fichier) n'est jamais enregistré sous un parent en cours de
 * fermeture : FL_EBUSY (transitoire, la fermeture du parent va aboutir) ; parent disparu : FL_EINVAL.
 * L'appelant libère l'objet quand le résultat est < 0. */
static int64_t tab_put(int type, int64_t parent, void *obj) {
  pthread_mutex_lock(&g_mu);
  if (parent != 0) {
    slot *ps = lookup(parent, parent_type(type));
    if (!ps) {
      pthread_mutex_unlock(&g_mu);
      return FL_EINVAL;
    }
    if (ps->closing) {
      pthread_mutex_unlock(&g_mu);
      return FL_EBUSY;
    }
  }
  for (unsigned k = 0; k < FJ_MAX; k++) {
    unsigned i = (g_next + k) % FJ_MAX;
    slot *s = &g_tab[i];
    if (s->type != T_FREE) continue;
    if (s->gen == 0) s->gen = 1;
    s->type = (uint8_t)type;
    s->closing = false;
    s->refs = 0;
    s->parent = parent;
    s->obj = obj;
    g_next = (i + 1) % FJ_MAX;
    g_used++;
    int64_t h = mkhandle(i);
    pthread_mutex_unlock(&g_mu);
    return h;
  }
  pthread_mutex_unlock(&g_mu);
  return FL_ENOMEM;
}

static void *tab_acquire(int64_t h, int type) {
  pthread_mutex_lock(&g_mu);
  slot *s = lookup(h, type);
  void *obj = NULL;
  if (s && !s->closing) {
    s->refs++;
    obj = s->obj;
  }
  pthread_mutex_unlock(&g_mu);
  return obj;
}

static void tab_release(int64_t h, int type) {
  pthread_mutex_lock(&g_mu);
  slot *s = lookup(h, type); /* toujours valide : une fermeture attend refs == 0 */
  if (s && s->refs) {
    s->refs--;
    if (!s->refs && s->closing) pthread_cond_broadcast(&g_cv);
  }
  pthread_mutex_unlock(&g_mu);
}

/* Sous g_mu, s déjà marqué closing : attend les opérations en cours, détruit l'objet hors du mutex,
 * libère l'entrée. Rend la main avec g_mu tenu, et le code du destructeur. */
static int finish_close_locked(slot *s, int64_t h, destroy_fn fn) {
  while (s->refs) pthread_cond_wait(&g_cv, &g_mu);
  void *obj = s->obj;
  pthread_mutex_unlock(&g_mu);
  int rc = fn(obj, h);
  pthread_mutex_lock(&g_mu);
  s->type = T_FREE;
  s->closing = false;
  s->parent = 0;
  s->obj = NULL;
  s->gen = s->gen == UINT32_MAX ? 1 : s->gen + 1;
  g_used--;
  pthread_cond_broadcast(&g_cv);
  return rc;
}

/* Ferme une entrée (FL_EINVAL si invalide ou déjà en fermeture). */
static int tab_close(int64_t h, int type, destroy_fn fn) {
  pthread_mutex_lock(&g_mu);
  slot *s = lookup(h, type);
  if (!s || s->closing) {
    pthread_mutex_unlock(&g_mu);
    return FL_EINVAL;
  }
  s->closing = true;
  int rc = finish_close_locked(s, h, fn);
  pthread_mutex_unlock(&g_mu);
  return rc;
}

/* Sous g_mu : nombre d'enfants de `parent` du type donné qui ne sont pas en fermeture. */
static unsigned live_children(int64_t parent, int type) {
  unsigned n = 0;
  for (unsigned i = 0; i < FJ_MAX; i++)
    if (g_tab[i].type == type && g_tab[i].parent == parent && !g_tab[i].closing) n++;
  return n;
}

/* Ferme tous les enfants de `parent`, et attend ceux qu'un autre fil est en train de fermer. */
static void close_children(int64_t parent, int type, destroy_fn fn) {
  pthread_mutex_lock(&g_mu);
  for (;;) {
    bool others = false;
    unsigned found = FJ_MAX;
    for (unsigned i = 0; i < FJ_MAX; i++) {
      if (g_tab[i].type != type || g_tab[i].parent != parent) continue;
      if (g_tab[i].closing) {
        others = true;
        continue;
      }
      found = i;
      break;
    }
    if (found < FJ_MAX) {
      slot *s = &g_tab[found];
      s->closing = true;
      finish_close_locked(s, mkhandle(found), fn);
      continue;
    }
    if (!others) break;
    pthread_cond_wait(&g_cv, &g_mu);
  }
  pthread_mutex_unlock(&g_mu);
}

int fj_debug_slot(int64_t h, unsigned *refs, bool *closing) {
  int rc = FL_EINVAL;
  pthread_mutex_lock(&g_mu);
  for (int t = T_DISK; t <= T_LAST && rc != FL_OK; t++) {
    slot *s = lookup(h, t);
    if (!s) continue;
    if (refs) *refs = s->refs;
    if (closing) *closing = s->closing;
    rc = FL_OK;
  }
  pthread_mutex_unlock(&g_mu);
  return rc;
}

unsigned fj_debug_used(void) {
  pthread_mutex_lock(&g_mu);
  unsigned n = g_used;
  pthread_mutex_unlock(&g_mu);
  return n;
}

/* ---- objets ---- */

typedef struct {
  fl_usb_transport *usb; /* NULL pour une image */
  fl_bdev *base;         /* fichier image ou usb_bdev */
  fl_bdev counted;       /* base, vidages comptés (fj_debug_flushes) */
  _Atomic uint64_t flushes;
  fl_bdev *dev;          /* cache au-dessus de counted : seul utilisé */
  bool formatting;       /* fj_format en cours (sous g_mu) : fj_mount refusé */
  unsigned mounting;     /* fj_mount en cours (sous g_mu) : fj_format refusé */
} jdisk;

static int counted_read(fl_bdev *d, uint64_t lba, uint32_t count, void *buf) {
  return fl_bdev_read(((jdisk *)d->priv)->base, lba, count, buf);
}
static int counted_write(fl_bdev *d, uint64_t lba, uint32_t count, const void *buf) {
  return fl_bdev_write(((jdisk *)d->priv)->base, lba, count, buf);
}
static int counted_flush(fl_bdev *d) {
  jdisk *j = d->priv;
  atomic_fetch_add(&j->flushes, 1);
  return fl_bdev_flush(j->base);
}
static void counted_destroy(fl_bdev *d) { (void)d; /* intégré à jdisk */ }
static const fl_bdev_ops counted_ops = {counted_read, counted_write, counted_flush, counted_destroy};

typedef struct {
  fl_bdev *slice, *plain; /* plain : déchiffré (NULL si en clair) */
  fl_luks *luks;
  fl_fs *fs;
  fl_content kind; /* système de fichiers monté (clé "fs" de fj_statfs) */
} jvol;

static int file_destroy(void *obj, int64_t h); /* ferme d'abord les archives du fichier */

/* Ordre de la phase 1 : fs, déchiffré, luks, tranche. Rend le code du démontage. */
static int vol_free(jvol *v) {
  if (!v) return FL_OK;
  int rc = FL_OK;
  if (v->fs) {
    rc = fl_fs_sync(v->fs);       /* aucun fichier ouvert : close_children est passé avant */
    int ru = fl_fs_unmount(v->fs); /* libère même sur un disque mort */
    if (rc == FL_OK) rc = ru;
  }
  fl_bdev_close(v->plain);
  fl_luks_close(v->luks);
  fl_bdev_close(v->slice);
  free(v);
  return rc;
}

static int vol_destroy(void *obj, int64_t h) {
  close_children(h, T_FILE, file_destroy);
  return vol_free(obj);
}

/* Pile entière avant le transport : le usb_bdev copie le transport sans le posséder. */
static void disk_free(jdisk *d) {
  if (!d) return;
  fl_bdev_close(d->dev);
  fl_bdev_close(d->base);
#if defined(__linux__)
  fl_usbdevfs_transport_free(d->usb);
#endif
  free(d);
}

static int disk_destroy(void *obj, int64_t h) {
  close_children(h, T_VOL, vol_destroy);
  disk_free(obj);
  return FL_OK;
}

/* d->base rempli : ajoute le cache (sauf coffre), enregistre le disque (sous `parent` : fichier d'un coffre,
 * tenu par l'appelant). Libère tout en cas d'échec. */
static int64_t disk_register(jdisk *d, int64_t parent, bool cache) {
  d->counted = (fl_bdev){&counted_ops, d->base->sector_size, d->base->sector_count, d->base->read_only, d};
  int rc = FL_OK;
  if (cache) {
    rc = fl_cache_bdev_new(&d->counted, CACHE_BLOCK, CACHE_BLOCKS, &d->dev);
  } else {
    d->dev = &d->counted; /* fl_bdev_close(&counted) est sans effet */
  }
  if (rc != FL_OK) {
    d->dev = NULL;
    disk_free(d);
    return rc;
  }
  int64_t h = tab_put(T_DISK, parent, d);
  if (h < 0) disk_free(d);
  return h;
}

int64_t fj_open_image(const char *path, bool read_only) {
  if (!path) return FL_EINVAL;
  jdisk *d = calloc(1, sizeof *d);
  if (!d) return FL_ENOMEM;
  int rc = fl_file_bdev_open(path, 512, read_only, &d->base);
  if (rc != FL_OK) {
    d->base = NULL;
    disk_free(d);
    return rc;
  }
  return disk_register(d, 0, true);
}

int64_t fj_open_usb(int fd, int iface, int ep_in, int ep_out) {
#if defined(__linux__)
  if (fd < 0 || iface < 0 || iface > 255 || ep_in < 0 || ep_in > 255 || ep_out < 0 || ep_out > 255)
    return FL_EINVAL;
  jdisk *d = calloc(1, sizeof *d);
  if (!d) return FL_ENOMEM;
  int rc = fl_usbdevfs_transport_new(fd, (uint8_t)iface, (uint8_t)ep_in, (uint8_t)ep_out, &d->usb);
  /* en écriture : MODE SENSE dit si le disque est protégé (alors lecture seule, RO_WP au montage) */
  if (rc == FL_OK) rc = fl_usb_bdev_open(d->usb, 0, false, &d->base);
  if (rc != FL_OK) {
    d->base = NULL;
    disk_free(d);
    return rc;
  }
  return disk_register(d, 0, true);
#else
  (void)fd;
  (void)iface;
  (void)ep_in;
  (void)ep_out;
  return FL_ENOTSUP;
#endif
}

int64_t fj_open_disk_fd(int fd, bool read_only) {
  if (fd < 0) return FL_EINVAL;
  jdisk *d = calloc(1, sizeof *d);
  if (!d) {
    close(fd);
    return FL_ENOMEM;
  }
  int rc = fl_fd_bdev_open(fd, 512, read_only, &d->base); /* le descripteur lui appartient, même en échec */
  if (rc != FL_OK) {
    d->base = NULL;
    disk_free(d);
    return rc;
  }
  return disk_register(d, 0, false);
}

int fj_close_file(int64_t file);

int64_t fj_open_disk_file(int64_t file, int64_t size) {
  fl_file *f = tab_acquire(file, T_FILE);
  if (!f) return FL_EINVAL;
  jdisk *d = size > 0 ? calloc(1, sizeof *d) : NULL;
  int64_t h = size <= 0 ? FL_EINVAL : !d ? FL_ENOMEM : FL_OK;
  if (h == FL_OK) {
    h = fl_fsfile_bdev_new(f, (uint64_t)size, false, &d->base);
    if (h == FL_EROFS) h = fl_fsfile_bdev_new(f, (uint64_t)size, true, &d->base);
    if (h != FL_OK) {
      d->base = NULL;
      disk_free(d);
    } else {
      /* enregistré sous la référence du fichier : sa fermeture le verra */
      h = disk_register(d, file, false);
    }
  }
  tab_release(file, T_FILE);
  if (h < 0) fj_close_file(file);
  return h;
}

/* Un coffre sur un fichier du moteur ferme ensuite ce fichier, qui lui appartient. */
int fj_close_disk(int64_t disk) {
  pthread_mutex_lock(&g_mu);
  slot *s = lookup(disk, T_DISK);
  int64_t parent = s ? s->parent : 0;
  pthread_mutex_unlock(&g_mu);
  int rc = tab_close(disk, T_DISK, disk_destroy);
  if (rc != FL_EINVAL && parent) {
    int rf = fj_close_file(parent); /* FL_EINVAL : déjà en fermeture par ailleurs, qui le synchronise */
    if (rc == FL_OK && rf != FL_EINVAL) rc = rf;
  }
  return rc;
}

/* ---- analyse ---- */

static const char *table_name(fl_pt_kind k) {
  switch (k) {
    case FL_PT_GPT: return "gpt";
    case FL_PT_MBR: return "mbr";
    default: return "none";
  }
}

static bool is_luks(fl_content c) { return c == FL_CONTENT_LUKS1 || c == FL_CONTENT_LUKS2; }

static void scan_part(fl_json *j, fl_bdev *dev, const fl_partition *p) {
  fl_bdev *sl = NULL;
  fl_probe_result pr;
  memset(&pr, 0, sizeof pr);
  fl_luks *l = NULL;
  bool damaged = false;
  int err = fl_slice_bdev_new(dev, p->first_lba, p->sector_count, &sl);
  if (err == FL_OK) err = fl_probe(sl, &pr);
  if (err != FL_OK) {
    memset(&pr, 0, sizeof pr);
  } else if (is_luks(pr.content)) {
    err = fl_luks_open(sl, &l);
  } else if (pr.content == FL_CONTENT_UNKNOWN && fl_luks_open(sl, &l) == FL_OK) {
    /* magie du primaire détruite, en-tête LUKS2 secondaire valide */
    damaged = true;
    pr.content = fl_luks_version(l) == 1 ? FL_CONTENT_LUKS1 : FL_CONTENT_LUKS2;
  }
  pr.label[sizeof pr.label - 1] = 0;
  pr.uuid[sizeof pr.uuid - 1] = 0;

  fl_json_obj_begin(j);
  fl_json_key(j, "index");
  fl_json_u64(j, p->index);
  fl_json_key(j, "first_lba");
  fl_json_u64(j, p->first_lba);
  fl_json_key(j, "size");
  fl_json_u64(j, p->sector_count * dev->sector_size); /* borné par la taille du disque */
  fl_json_key(j, "content");
  fl_json_cstr(j, fl_content_name(pr.content));
  fl_json_key(j, "label");
  fl_json_cstr(j, pr.label);
  fl_json_key(j, "uuid");
  fl_json_cstr(j, pr.uuid);
  fl_json_key(j, "supported");
  fl_json_bool(j, err == FL_OK && fl_content_supported(pr.content));
  if (l) {
    uint32_t kib = 0;
    fl_luks_max_kdf_memory_kib(l, &kib);
    fl_json_key(j, "luks");
    fl_json_obj_begin(j);
    fl_json_key(j, "version");
    fl_json_i64(j, fl_luks_version(l));
    fl_json_key(j, "cipher");
    fl_json_cstr(j, fl_luks_cipher(l));
    fl_json_key(j, "primary_damaged");
    fl_json_bool(j, damaged);
    fl_json_key(j, "max_kdf_memory_kib");
    fl_json_u64(j, kib);
    fl_json_obj_end(j);
  }
  if (err != FL_OK) {
    fl_json_key(j, "err");
    fl_json_i64(j, err);
  }
  fl_json_obj_end(j);
  fl_luks_close(l);
  fl_bdev_close(sl);
}

int fj_scan(int64_t disk, fl_json *out) {
  jdisk *d = tab_acquire(disk, T_DISK);
  if (!d) return FL_EINVAL;
  fl_part_table *t = calloc(1, sizeof *t);
  int rc = t ? fl_part_scan(d->dev, t) : FL_ENOMEM;
  if (rc == FL_OK) {
    fl_json_reset(out);
    fl_json_obj_begin(out);
    fl_json_key(out, "sector_size");
    fl_json_u64(out, d->dev->sector_size);
    fl_json_key(out, "size");
    fl_json_u64(out, fl_bdev_size_bytes(d->dev));
    fl_json_key(out, "table");
    fl_json_cstr(out, table_name(t->kind));
    fl_json_key(out, "parts");
    fl_json_arr_begin(out);
    for (uint32_t i = 0; i < t->count && i < sizeof t->parts / sizeof t->parts[0]; i++)
      scan_part(out, d->dev, &t->parts[i]);
    fl_json_arr_end(out);
    fl_json_obj_end(out);
    rc = out->err;
  }
  free(t);
  tab_release(disk, T_DISK);
  return rc;
}

/* ---- volumes ---- */

static int vol_open(fl_bdev *dev, uint32_t part_index, int slot, const void *pass, size_t passlen, bool want_rw,
                    jvol *v) {
  fl_part_table *t = calloc(1, sizeof *t);
  if (!t) return FL_ENOMEM;
  int rc = fl_part_scan(dev, t);
  const fl_partition *p = NULL;
  for (uint32_t i = 0; rc == FL_OK && i < t->count && i < sizeof t->parts / sizeof t->parts[0]; i++)
    if (t->parts[i].index == part_index) {
      p = &t->parts[i];
      break;
    }
  if (rc == FL_OK && !p) rc = FL_EINVAL;
  if (rc == FL_OK) rc = fl_slice_bdev_new(dev, p->first_lba, p->sector_count, &v->slice);
  free(t);
  if (rc != FL_OK) return rc;

  fl_probe_result pr;
  if ((rc = fl_probe(v->slice, &pr)) != FL_OK) return rc;
  bool luks = false;
  if (is_luks(pr.content)) {
    if ((rc = fl_luks_open(v->slice, &v->luks)) != FL_OK) return rc;
    luks = true;
  } else if (pr.content == FL_CONTENT_UNKNOWN && fl_luks_open(v->slice, &v->luks) == FL_OK) {
    luks = true; /* en-tête principal abîmé, secondaire valide */
  }
  fl_bdev *target = v->slice;
  if (luks) {
    if (!pass) return FL_EINVAL;
    if ((rc = fl_luks_unlock_slot(v->luks, slot, pass, passlen, &v->plain)) != FL_OK) return rc;
    if ((rc = fl_probe(v->plain, &pr)) != FL_OK) return rc;
    target = v->plain;
  }
  if (!fl_content_supported(pr.content) || is_luks(pr.content)) return FL_ENOTSUP; /* ext4, FAT, exFAT */
  v->kind = pr.content;
  return fl_fs_mount(target, pr.content, want_rw, &v->fs);
}

static void (*g_mount_hook)(void *);
static void *g_mount_hook_arg;
void fj_debug_set_mount_hook(void (*fn)(void *), void *arg) {
  g_mount_hook = fn;
  g_mount_hook_arg = arg;
}

int64_t fj_mount(int64_t disk, uint32_t part_index, const void *pass, size_t passlen, bool want_rw) {
  return fj_mount_slot(disk, part_index, -1, pass, passlen, want_rw);
}

int64_t fj_mount_slot(int64_t disk, uint32_t part_index, int slot, const void *pass_in, size_t passlen, bool want_rw) {
  uint8_t *pass = NULL;
  int prc = pass_take(pass_in, passlen, &pass);
  jdisk *d = prc == FL_OK && slot >= -1 ? tab_acquire(disk, T_DISK) : NULL;
  if (!d) {
    pass_drop(pass, passlen);
    return prc != FL_OK ? prc : FL_EINVAL;
  }
  pthread_mutex_lock(&g_mu);
  bool formatting = d->formatting;
  if (!formatting) d->mounting++; /* jusqu'à l'enregistrement du volume, fj_format le voit */
  pthread_mutex_unlock(&g_mu);
  int64_t h;
  jvol *v = formatting ? NULL : calloc(1, sizeof *v);
  if (formatting) {
    h = FL_EBUSY;
  } else if (!v) {
    h = FL_ENOMEM;
  } else {
    int rc = vol_open(d->dev, part_index, slot, pass ? pass : pass_in, passlen, want_rw, v); /* "" : phrase vide */
    if (rc != FL_OK) {
      vol_free(v);
      h = rc;
    } else {
      if (g_mount_hook) g_mount_hook(g_mount_hook_arg); /* tests : pause avant l'enregistrement */
      /* enregistré tant que l'on tient la référence du disque : fj_close_disk le verra */
      h = tab_put(T_VOL, disk, v);
      if (h < 0) vol_free(v);
    }
  }
  if (!formatting) {
    pthread_mutex_lock(&g_mu);
    d->mounting--;
    pthread_mutex_unlock(&g_mu);
  }
  tab_release(disk, T_DISK);
  pass_drop(pass, passlen);
  return h;
}

int fj_unmount(int64_t vol, bool force) {
  pthread_mutex_lock(&g_mu);
  slot *s = lookup(vol, T_VOL);
  if (!s) {
    pthread_mutex_unlock(&g_mu);
    return FL_EINVAL;
  }
  if (!force) {
    /* le disque parent ferme ses volumes : ce démontage-ci n'a plus rien à faire, et n'est pas une erreur de poignée */
    slot *ps = lookup(s->parent, T_DISK);
    if (ps && ps->closing) {
      pthread_mutex_unlock(&g_mu);
      return FL_EBUSY;
    }
  }
  if (s->closing) {
    pthread_mutex_unlock(&g_mu);
    return FL_EINVAL;
  }
  if (!force && live_children(vol, T_FILE)) {
    pthread_mutex_unlock(&g_mu);
    return FL_EBUSY;
  }
  s->closing = true;
  if (!force) {
    /* un fj_open_file en cours a pu ouvrir un fichier entre-temps */
    while (s->refs) pthread_cond_wait(&g_cv, &g_mu);
    if (live_children(vol, T_FILE)) {
      s->closing = false;
      pthread_cond_broadcast(&g_cv); /* un fj_close_disk peut attendre ce volume : il le fermera lui-même */
      pthread_mutex_unlock(&g_mu);
      return FL_EBUSY;
    }
  }
  int rc = finish_close_locked(s, vol, vol_destroy);
  pthread_mutex_unlock(&g_mu);
  return rc;
}

static const char *type_code(fl_ftype t) {
  switch (t) {
    case FL_FT_FILE: return "f";
    case FL_FT_DIR: return "d";
    case FL_FT_SYMLINK: return "l";
    default: return "o";
  }
}

static void entry_json(fl_json *j, const char *name, size_t namelen, const fl_stat *st) {
  fl_json_obj_begin(j);
  fl_json_key(j, "name");
  fl_json_str(j, name, namelen);
  fl_json_key(j, "type");
  fl_json_cstr(j, type_code(st->type));
  fl_json_key(j, "size");
  fl_json_u64(j, st->size);
  fl_json_key(j, "mtime");
  fl_json_i64(j, st->mtime);
  fl_json_key(j, "mode"); /* type + droits ; propriétaire : sens réel sur ext4 seulement */
  fl_json_u64(j, st->mode);
  fl_json_key(j, "uid");
  fl_json_u64(j, st->uid);
  fl_json_key(j, "gid");
  fl_json_u64(j, st->gid);
  fl_json_obj_end(j);
}

int fj_statfs(int64_t vol, fl_json *out) {
  jvol *v = tab_acquire(vol, T_VOL);
  if (!v) return FL_EINVAL;
  fl_statfs sf;
  memset(&sf, 0, sizeof sf);
  int rc = fl_fs_statfs(v->fs, &sf);
  fl_content kind = v->kind;
  tab_release(vol, T_VOL);
  if (rc != FL_OK) return rc;
  sf.label[sizeof sf.label - 1] = 0;
  sf.ro_reason[sizeof sf.ro_reason - 1] = 0;
  fl_json_reset(out);
  fl_json_obj_begin(out);
  fl_json_key(out, "total");
  fl_json_u64(out, sf.total_bytes);
  fl_json_key(out, "free");
  fl_json_u64(out, sf.free_bytes);
  fl_json_key(out, "label");
  fl_json_cstr(out, sf.label);
  fl_json_key(out, "read_only");
  fl_json_bool(out, sf.read_only);
  fl_json_key(out, "ro_reason");
  fl_json_cstr(out, sf.ro_reason);
  fl_json_key(out, "needs_recovery");
  fl_json_bool(out, sf.needs_recovery);
  fl_json_key(out, "fs");
  fl_json_cstr(out, fl_content_name(kind));
  fl_json_obj_end(out);
  return out->err;
}

int fj_stat(int64_t vol, const char *path, fl_json *out) {
  if (!path) return FL_EINVAL;
  jvol *v = tab_acquire(vol, T_VOL);
  if (!v) return FL_EINVAL;
  fl_stat st;
  int rc = fl_fs_stat(v->fs, path, &st);
  tab_release(vol, T_VOL);
  if (rc != FL_OK) return rc;
  const char *slash = strrchr(path, '/');
  const char *name = slash ? slash + 1 : path; /* "" pour "/" */
  fl_json_reset(out);
  entry_json(out, name, strlen(name), &st);
  return out->err;
}

typedef struct {
  char *name;
  fl_stat st;
} lent;

typedef struct {
  lent *v;
  size_t n, cap;
} lents;

static int list_cb(void *ctx, const fl_dirent *e) {
  lents *l = ctx;
  if (l->n >= FJ_LIST_MAX) return FL_ENOMEM;
  if (l->n == l->cap) {
    size_t cap = l->cap ? l->cap * 2 : 64;
    lent *nv = realloc(l->v, cap * sizeof *nv);
    if (!nv) return FL_ENOMEM;
    l->v = nv;
    l->cap = cap;
  }
  size_t len = strnlen(e->name, sizeof e->name);
  char *name = malloc(len + 1);
  if (!name) return FL_ENOMEM;
  memcpy(name, e->name, len);
  name[len] = 0;
  l->v[l->n].name = name;
  l->v[l->n].st = e->st;
  l->n++;
  return 0;
}

static int lent_cmp(const void *a, const void *b) {
  return strcmp(((const lent *)a)->name, ((const lent *)b)->name); /* octets non signés */
}

int fj_list(int64_t vol, const char *path, fl_json *out) {
  if (!path) return FL_EINVAL;
  jvol *v = tab_acquire(vol, T_VOL);
  if (!v) return FL_EINVAL;
  lents l = {NULL, 0, 0};
  int rc = fl_fs_readdir(v->fs, path, list_cb, &l);
  tab_release(vol, T_VOL);
  if (rc == FL_OK) {
    if (l.n > 1) qsort(l.v, l.n, sizeof *l.v, lent_cmp);
    fl_json_reset(out);
    fl_json_set_max(out, FL_JSON_LIST_MAX); /* au-delà : FL_ENOMEM, message habituel */
    fl_json_arr_begin(out);
    for (size_t i = 0; i < l.n && out->err == FL_OK; i++) entry_json(out, l.v[i].name, strlen(l.v[i].name), &l.v[i].st);
    fl_json_arr_end(out);
    rc = out->err;
  }
  for (size_t i = 0; i < l.n; i++) free(l.v[i].name);
  free(l.v);
  return rc;
}

/* ---- fichiers ---- */

int64_t fj_open_file(int64_t vol, const char *path, int flags) {
  if (!path) return FL_EINVAL;
  jvol *v = tab_acquire(vol, T_VOL);
  if (!v) return FL_EINVAL;
  fl_file *f = NULL;
  int64_t h = fl_fs_open(v->fs, path, flags, &f);
  if (h == FL_OK) {
    /* enregistré sous la référence du volume : fj_unmount le verra */
    h = tab_put(T_FILE, vol, f);
    if (h < 0) fl_file_close(f);
  }
  tab_release(vol, T_VOL);
  return h;
}

int64_t fj_pread(int64_t file, void *buf, size_t len, uint64_t off) {
  if (!buf && len) return FL_EINVAL;
  fl_file *f = tab_acquire(file, T_FILE);
  if (!f) return FL_EINVAL;
  if (len > FJ_PREAD_MAX) len = FJ_PREAD_MAX;
  int64_t r = fl_file_pread(f, buf, len, off);
  tab_release(file, T_FILE);
  return r;
}

int64_t fj_pwrite(int64_t file, const void *buf, size_t len, uint64_t off) {
  if ((!buf && len) || len > FJ_PREAD_MAX) return FL_EINVAL;
  fl_file *f = tab_acquire(file, T_FILE);
  if (!f) return FL_EINVAL;
  int64_t r = fl_file_pwrite(f, buf, len, off);
  tab_release(file, T_FILE);
  return r;
}

int fj_truncate(int64_t file, uint64_t size) {
  fl_file *f = tab_acquire(file, T_FILE);
  if (!f) return FL_EINVAL;
  int rc = fl_file_truncate(f, size);
  tab_release(file, T_FILE);
  return rc;
}

int fj_close_file(int64_t file) { return tab_close(file, T_FILE, file_destroy); }

/* Opération sur un chemin d'un volume, référence tenue. */
static int vol_path_op(int64_t vol, const char *path, int (*op)(fl_fs *, const char *)) {
  if (!path) return FL_EINVAL;
  jvol *v = tab_acquire(vol, T_VOL);
  if (!v) return FL_EINVAL;
  int rc = op(v->fs, path);
  tab_release(vol, T_VOL);
  return rc;
}

int fj_mkdir(int64_t vol, const char *path) { return vol_path_op(vol, path, fl_fs_mkdir); }
int fj_unlink(int64_t vol, const char *path) { return vol_path_op(vol, path, fl_fs_unlink); }
int fj_rmdir(int64_t vol, const char *path) { return vol_path_op(vol, path, fl_fs_rmdir); }

int fj_rename(int64_t vol, const char *from, const char *to) {
  if (!from || !to) return FL_EINVAL;
  jvol *v = tab_acquire(vol, T_VOL);
  if (!v) return FL_EINVAL;
  int rc = fl_fs_rename(v->fs, from, to);
  tab_release(vol, T_VOL);
  return rc;
}

int fj_sync(int64_t vol) {
  jvol *v = tab_acquire(vol, T_VOL);
  if (!v) return FL_EINVAL;
  int rc = fl_fs_sync(v->fs);
  tab_release(vol, T_VOL);
  return rc;
}

int64_t fj_debug_flushes(int64_t disk) {
  jdisk *d = tab_acquire(disk, T_DISK);
  if (!d) return FL_EINVAL;
  int64_t n = (int64_t)atomic_load(&d->flushes);
  tab_release(disk, T_DISK);
  return n;
}

/* ---- formatage (phase 8) ---- */

static int parse_format_opts(const char *json, fl_fmt_opts *o, char *label, size_t cap) {
  cJSON *r = json ? cJSON_Parse(json) : NULL;
  if (!cJSON_IsObject(r)) {
    cJSON_Delete(r);
    return FL_EINVAL;
  }
  static const char *noms[] = {"fat32", "exfat", "ext4", "ntfs"};
  static const fl_fmt_fs fss[] = {FL_FMT_FAT32, FL_FMT_EXFAT, FL_FMT_EXT4, FL_FMT_NTFS};
  const char *fs = cJSON_GetStringValue(cJSON_GetObjectItem(r, "fs"));
  const cJSON *enc = cJSON_GetObjectItem(r, "encrypted"), *lab = cJSON_GetObjectItem(r, "label");
  const cJSON *mem = cJSON_GetObjectItem(r, "kdf_mem_kib"), *uid = cJSON_GetObjectItem(r, "uid"),
              *gid = cJSON_GetObjectItem(r, "gid"), *table = cJSON_GetObjectItem(r, "table");
  int rc = FL_EINVAL;
  memset(o, 0, sizeof *o);
  for (size_t i = 0; fs && i < sizeof noms / sizeof noms[0]; i++)
    if (!strcmp(fs, noms[i])) {
      o->fs = fss[i];
      rc = FL_OK;
    }
  if ((enc && !cJSON_IsBool(enc)) || (lab && !cJSON_IsString(lab)) || (mem && !cJSON_IsNumber(mem)) ||
      (uid && !cJSON_IsNumber(uid)) || (gid && !cJSON_IsNumber(gid)) ||
      (table && (!cJSON_IsString(table) || strcmp(table->valuestring, "none") != 0)))
    rc = FL_EINVAL;
  if (rc == FL_OK) {
    o->encrypted = cJSON_IsTrue(enc);
    const char *l = lab ? lab->valuestring : "";
    if (strlen(l) >= cap) rc = FL_EINVAL;
    else snprintf(label, cap, "%s", l);
    o->label = label;
    double m = mem ? mem->valuedouble : 1048576, u = uid ? uid->valuedouble : 1000, g = gid ? gid->valuedouble : 1000;
    if (m < 0 || m > UINT32_MAX || u < 0 || u > UINT32_MAX || g < 0 || g > UINT32_MAX) rc = FL_EINVAL;
    o->kdf_mem_kib = (uint32_t)m;
    o->root_uid = (uint32_t)u;
    o->root_gid = (uint32_t)g;
    o->no_table = table != NULL;
  }
  cJSON_Delete(r);
  return rc;
}

int fj_format(int64_t disk, const char *json, const void *pass_in, size_t passlen,
              void (*progress)(int pct, void *arg), void *arg) {
  fl_fmt_opts o;
  char label[256];
  uint8_t *pass = NULL;
  int rc = pass_take(pass_in, passlen, &pass);
  if (rc == FL_OK) rc = parse_format_opts(json, &o, label, sizeof label);
  jdisk *d = tab_acquire(disk, T_DISK);
  if (!d) {
    pass_drop(pass, passlen);
    return FL_EINVAL;
  }
  if (rc == FL_OK) {
    pthread_mutex_lock(&g_mu);
    if (d->formatting || d->mounting > 0 || live_children(disk, T_VOL) > 0) rc = FL_EBUSY;
    else d->formatting = true; /* plus aucun fj_mount sur ce disque jusqu'à la fin */
    pthread_mutex_unlock(&g_mu);
  }
  if (rc == FL_OK) {
    rc = d->dev->read_only ? FL_EROFS : fl_format(d->dev, &o, pass ? pass : pass_in, passlen, progress, arg);
    pthread_mutex_lock(&g_mu);
    d->formatting = false;
    pthread_mutex_unlock(&g_mu);
  }
  tab_release(disk, T_DISK);
  pass_drop(pass, passlen);
  return rc;
}

/* ---- archives (phase 9) ---- */

/* Une archive sur un fichier du moteur est l'enfant de sa poignée de fichier : elle lit et écrit le fl_file
 * directement (le fichier ne peut être détruit qu'après elle, file_destroy fermant d'abord ses archives),
 * et ferme la poignée de fichier avec elle. Sur un descripteur : pas de parent, le descripteur est fermé. */
typedef struct {
  int fd;          /* -1 pour un fichier du moteur */
  fl_file *file;
  uint64_t pos;    /* écriture : position suivante */
  fl_arc_in in;
  fl_arc_out out;
  fl_arc_reader *r;
  fl_arc_writer *w;
  fl_agew *aw;     /* écrivain age (T_AGEW) */
  fl_ager *ar;     /* lecteur age (T_AGER) */
  bool commit;     /* fermeture explicite d'un ZIP ou d'un fichier age écrit : terminer plutôt qu'abandonner */
  pthread_mutex_t mu; /* libarchive : une opération à la fois par archive */
} jarc;

static int64_t arc_pread(void *ctx, void *buf, size_t len, uint64_t off) {
  jarc *a = ctx;
  if (a->file) return fl_file_pread(a->file, buf, len, off);
  ssize_t n;
  do n = pread(a->fd, buf, len, (off_t)off);
  while (n < 0 && errno == EINTR);
  return n < 0 ? FL_EIO : n;
}

static int arc_write(void *ctx, const void *buf, size_t len) {
  jarc *a = ctx;
  const uint8_t *p = buf;
  while (len) {
    int64_t n;
    if (a->file) {
      n = fl_file_pwrite(a->file, p, len, a->pos);
    } else {
      do n = write(a->fd, p, len);
      while (n < 0 && errno == EINTR);
      if (n < 0) n = errno == ENOSPC ? FL_ENOSPC : FL_EIO;
    }
    if (n < 0) return (int)n;
    if (n == 0) return FL_EIO;
    a->pos += (uint64_t)n;
    p += n;
    len -= (size_t)n;
  }
  return FL_OK;
}

/* Libère l'archive ; ferme le descripteur, jamais le fichier (fermé par l'appelant). */
static int arc_free(jarc *a, bool commit) {
  int rc = FL_OK;
  if (a->r) fl_arc_close(a->r);
  if (a->w) rc = fl_arcw_close(a->w, commit);
  if (a->aw) rc = fl_agew_close(a->aw, commit);
  if (a->ar) fl_ager_close(a->ar);
  if (a->fd >= 0) close(a->fd);
  pthread_mutex_destroy(&a->mu);
  free(a);
  return rc;
}

static int arc_destroy(void *obj, int64_t h) {
  (void)h;
  return arc_free(obj, ((jarc *)obj)->commit);
}

/* Fichier fermé (ou volume, disque) sous l'archive : abandon, sans écrire. */
static int arc_abandon(void *obj, int64_t h) {
  (void)h;
  return arc_free(obj, false);
}

static int file_destroy(void *obj, int64_t h) {
  close_children(h, T_ARC, arc_abandon);
  close_children(h, T_AGEW, arc_abandon);
  close_children(h, T_AGER, arc_abandon);
  close_children(h, T_DISK, disk_destroy); /* coffre posé sur ce fichier : démonté de force, synchronisé */
  return fl_file_close(obj); /* fichier écrit : synchronisation */
}

static jarc *arc_new(int fd) {
  jarc *a = calloc(1, sizeof *a);
  if (!a) return NULL;
  a->fd = fd;
  a->in = (fl_arc_in){a, 0, arc_pread};
  a->out = (fl_arc_out){a, arc_write};
  pthread_mutex_init(&a->mu, NULL);
  return a;
}

/* Ce qu'ouvre une poignée de flux. */
typedef enum { K_ARC_R, K_ARC_W, K_AGEW, K_AGER } skind;

typedef struct {
  const char *mode; /* archives : NULL, "plain", "aes", "age" */
  const uint8_t *pass;
  size_t passlen;
  uint8_t log2n;    /* écriture age */
} sopts;

static int kind_type(skind k) { return k == K_AGEW ? T_AGEW : k == K_AGER ? T_AGER : T_ARC; }

/* Plus grand log2 N de scrypt (r = 8 : 2^(n+10) octets) qui tient dans 0,8 × la mémoire disponible, 20 au plus. */
static uint8_t age_max_log2n(void) {
  uint64_t avail = 0;
  FILE *f = fopen("/proc/meminfo", "re");
  if (f) {
    char line[128];
    unsigned long long kib;
    while (fgets(line, sizeof line, f))
      if (sscanf(line, "MemAvailable: %llu kB", &kib) == 1) {
        avail = (uint64_t)kib * 1024;
        break;
      }
    fclose(f);
  }
  if (!avail) {
    long pages = sysconf(_SC_AVPHYS_PAGES), sz = sysconf(_SC_PAGESIZE);
    if (pages > 0 && sz > 0) avail = (uint64_t)pages * (uint64_t)sz;
  }
  if (!avail) return 18;
  uint64_t budget = avail / 10 * 8;
  uint8_t n = 20;
  while (n > 1 && (1ull << (n + 10)) > budget) n--;
  return n;
}

/* Mode d'archive valide ; aes et age demandent une phrase. */
static int check_mode(const sopts *o) {
  if (!o->mode || !strcmp(o->mode, "plain")) return FL_OK;
  if (strcmp(o->mode, "aes") && strcmp(o->mode, "age")) return FL_EINVAL;
  return o->pass && o->passlen ? FL_OK : FL_EINVAL;
}

/* Ouvre le lecteur ou l'écrivain sur `a`, puis l'enregistre (sous `parent` : fichier tenu par l'appelant). */
static int64_t stream_start(jarc *a, int64_t parent, skind k, const sopts *o) {
  bool age = o->mode && !strcmp(o->mode, "age"), aes = o->mode && !strcmp(o->mode, "aes");
  int rc = check_mode(o);
  if (rc == FL_OK && (k == K_AGEW || k == K_AGER) && (!o->pass || !o->passlen)) rc = FL_EINVAL;
  if (rc == FL_OK) {
    switch (k) {
      case K_ARC_R:
        rc = age ? fl_arc_open_age(&a->in, o->pass, o->passlen, age_max_log2n(), &a->r)
                 : fl_arc_open2(&a->in, o->pass, o->passlen, &a->r);
        break;
      case K_ARC_W:
        rc = age   ? fl_arcw_open_age(&a->out, o->pass, o->passlen, 18, &a->w)
             : aes ? fl_arcw_open2(&a->out, o->pass, o->passlen, &a->w)
                   : fl_arcw_open(&a->out, &a->w);
        break;
      case K_AGEW: rc = fl_agew_open(&a->out, o->pass, o->passlen, o->log2n, &a->aw); break;
      case K_AGER: rc = fl_ager_open(&a->in, o->pass, o->passlen, age_max_log2n(), &a->ar); break;
    }
  }
  if (rc != FL_OK) {
    arc_free(a, false);
    return rc;
  }
  int64_t h = tab_put(kind_type(k), parent, a);
  if (h < 0) arc_free(a, false);
  return h;
}

static bool reads(skind k) { return k == K_ARC_R || k == K_AGER; }

static int64_t stream_open_fd(int fd, skind k, const sopts *o) {
  if (fd < 0) return FL_EINVAL;
  jarc *a = arc_new(fd);
  if (!a) {
    close(fd);
    return FL_ENOMEM;
  }
  if (reads(k)) {
    off_t size = lseek(fd, 0, SEEK_END);
    if (size < 0) {
      arc_free(a, false);
      return FL_EINVAL;
    }
    a->in.size = size;
  }
  return stream_start(a, 0, k, o);
}

static int64_t stream_open_file(int64_t file, int64_t size, skind k, const sopts *o) {
  if (size < 0) {
    fj_close_file(file);
    return FL_EINVAL;
  }
  fl_file *f = tab_acquire(file, T_FILE);
  if (!f) return FL_EINVAL;
  jarc *a = arc_new(-1);
  int64_t h = FL_ENOMEM;
  if (a) {
    a->file = f;
    a->in.size = size;
    /* enregistré sous la référence du fichier : sa fermeture le verra */
    h = stream_start(a, file, k, o);
  }
  tab_release(file, T_FILE);
  if (h < 0) fj_close_file(file);
  return h;
}

/* Copie la phrase, ouvre sur un descripteur (file < 0) ou un fichier, efface la copie. */
static int64_t stream_open(int fd, int64_t file, int64_t size, skind k, const char *mode, const void *pass_in,
                           size_t passlen, uint8_t log2n) {
  uint8_t *pass = NULL;
  int64_t h = pass_take(pass_in, passlen, &pass);
  if (h != FL_OK) {
    if (fd >= 0) close(fd);
    else if (file >= 0) fj_close_file(file);
  } else {
    sopts o = {mode, pass, pass ? passlen : 0, log2n};
    h = file < 0 ? stream_open_fd(fd, k, &o) : stream_open_file(file, size, k, &o);
  }
  pass_drop(pass, passlen);
  return h;
}

int64_t fj_arc_open_fd(int fd, const char *mode, const void *pass, size_t passlen) {
  return stream_open(fd, -1, 0, K_ARC_R, mode, pass, passlen, 0);
}
int64_t fj_arc_open_file(int64_t file, int64_t size, const char *mode, const void *pass, size_t passlen) {
  return stream_open(-1, file, size, K_ARC_R, mode, pass, passlen, 0);
}
int64_t fj_arcw_open_fd(int fd, const char *mode, const void *pass, size_t passlen) {
  return stream_open(fd, -1, 0, K_ARC_W, mode, pass, passlen, 0);
}
int64_t fj_arcw_open_file(int64_t file, const char *mode, const void *pass, size_t passlen) {
  return stream_open(-1, file, 0, K_ARC_W, mode, pass, passlen, 0);
}
int64_t fj_agew_open_fd(int fd, const void *pass, size_t passlen, uint8_t log2n) {
  return stream_open(fd, -1, 0, K_AGEW, NULL, pass, passlen, log2n);
}
int64_t fj_agew_open_file(int64_t file, const void *pass, size_t passlen, uint8_t log2n) {
  return stream_open(-1, file, 0, K_AGEW, NULL, pass, passlen, log2n);
}
int64_t fj_ager_open_fd(int fd, const void *pass, size_t passlen) {
  return stream_open(fd, -1, 0, K_AGER, NULL, pass, passlen, 0);
}
int64_t fj_ager_open_file(int64_t file, int64_t size, const void *pass, size_t passlen) {
  return stream_open(-1, file, size, K_AGER, NULL, pass, passlen, 0);
}

static const char *arc_type_code(fl_arc_type t) {
  switch (t) {
    case FL_ARC_FILE: return "f";
    case FL_ARC_DIR: return "d";
    case FL_ARC_SYMLINK: return "l";
    case FL_ARC_HARDLINK: return "h";
    default: return "o";
  }
}

/* Base64 (RFC 4648, avec bourrage) de n octets dans out (au moins 4 * ((n + 2) / 3) + 1 octets). */
static void base64(const uint8_t *in, size_t n, char *out) {
  static const char tab[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  size_t o = 0;
  for (size_t i = 0; i < n; i += 3) {
    uint32_t v = (uint32_t)in[i] << 16 | (i + 1 < n ? (uint32_t)in[i + 1] << 8 : 0) | (i + 2 < n ? in[i + 2] : 0);
    out[o++] = tab[v >> 18 & 63];
    out[o++] = tab[v >> 12 & 63];
    out[o++] = i + 1 < n ? tab[v >> 6 & 63] : '=';
    out[o++] = i + 2 < n ? tab[v & 63] : '=';
  }
  out[o] = 0;
}

int fj_arc_next(int64_t arc, fl_json *out) {
  jarc *a = tab_acquire(arc, T_ARC);
  if (!a) return FL_EINVAL;
  fl_arc_entry *e = a->r ? malloc(sizeof *e) : NULL;
  int rc = !a->r ? FL_EINVAL : !e ? FL_ENOMEM : FL_OK;
  bool raw = false;
  if (rc == FL_OK) {
    pthread_mutex_lock(&a->mu);
    rc = fl_arc_next(a->r, e);
    raw = rc == 1 && strcmp(fl_arc_format(a->r), "raw") == 0; /* .gz ou .xz seul : nom « data » de libarchive */
    pthread_mutex_unlock(&a->mu);
  }
  tab_release(arc, T_ARC);
  if (rc == 1) {
    char name[4 * ((sizeof e->name + 2) / 3) + 1];
    base64((const uint8_t *)e->name, e->name_len, name);
    fl_json_reset(out);
    fl_json_obj_begin(out);
    fl_json_key(out, "name");
    fl_json_cstr(out, name);
    fl_json_key(out, "type");
    fl_json_cstr(out, arc_type_code(e->type));
    fl_json_key(out, "size");
    fl_json_i64(out, e->size);
    fl_json_key(out, "mtime");
    fl_json_i64(out, e->mtime);
    fl_json_key(out, "encrypted");
    fl_json_bool(out, e->encrypted);
    fl_json_key(out, "raw");
    fl_json_bool(out, raw);
    fl_json_obj_end(out);
    if (out->err != FL_OK) rc = out->err;
  }
  free(e);
  return rc;
}

int64_t fj_arc_read(int64_t arc, void *buf, size_t len) {
  if (!buf && len) return FL_EINVAL;
  jarc *a = tab_acquire(arc, T_ARC);
  if (!a) return FL_EINVAL;
  if (len > FJ_PREAD_MAX) len = FJ_PREAD_MAX;
  int64_t r = FL_EINVAL;
  if (a->r) {
    pthread_mutex_lock(&a->mu);
    r = fl_arc_read(a->r, buf, len);
    pthread_mutex_unlock(&a->mu);
  }
  tab_release(arc, T_ARC);
  return r;
}

/* Fermeture explicite : l'archive ou le flux age (commit pour un ZIP ou un fichier age écrit), puis la poignée de
 * fichier dont il est l'enfant. */
static int arc_close(int64_t arc, int type, bool commit) {
  pthread_mutex_lock(&g_mu);
  slot *s = lookup(arc, type);
  if (!s || s->closing) {
    pthread_mutex_unlock(&g_mu);
    return FL_EINVAL;
  }
  ((jarc *)s->obj)->commit = commit;
  int64_t parent = s->parent;
  s->closing = true;
  int rc = finish_close_locked(s, arc, arc_destroy);
  pthread_mutex_unlock(&g_mu);
  if (parent) {
    int rf = fj_close_file(parent); /* FL_EINVAL : déjà en fermeture par ailleurs, qui le synchronise */
    if (rc == FL_OK && rf != FL_EINVAL) rc = rf;
  }
  return rc;
}

int fj_arc_close(int64_t arc) { return arc_close(arc, T_ARC, false); }
int fj_arcw_close(int64_t arc, bool commit) { return arc_close(arc, T_ARC, commit); }
int fj_agew_close(int64_t w, bool commit) { return arc_close(w, T_AGEW, commit); }
int fj_ager_close(int64_t r) { return arc_close(r, T_AGER, false); }

int fj_arcw_add(int64_t arc, const char *json) {
  cJSON *o = json ? cJSON_Parse(json) : NULL;
  const char *name = cJSON_GetStringValue(cJSON_GetObjectItem(o, "name"));
  const char *type = cJSON_GetStringValue(cJSON_GetObjectItem(o, "type"));
  const cJSON *size = cJSON_GetObjectItem(o, "size"), *mtime = cJSON_GetObjectItem(o, "mtime"),
              *store = cJSON_GetObjectItem(o, "store");
  int rc = FL_EINVAL;
  if (name && type && (!strcmp(type, "f") || !strcmp(type, "d")) && cJSON_IsNumber(size) && size->valuedouble >= 0 &&
      size->valuedouble < 9.2e18 && (!mtime || cJSON_IsNumber(mtime)) && (!store || cJSON_IsBool(store))) {
    jarc *a = tab_acquire(arc, T_ARC);
    if (a) {
      if (a->w) {
        pthread_mutex_lock(&a->mu);
        rc = fl_arcw_add(a->w, name, *type == 'd' ? FL_ARC_DIR : FL_ARC_FILE, (int64_t)size->valuedouble,
                         mtime ? (int64_t)mtime->valuedouble : 0, cJSON_IsTrue(store));
        pthread_mutex_unlock(&a->mu);
      }
      tab_release(arc, T_ARC);
    }
  }
  cJSON_Delete(o);
  return rc;
}

int fj_arcw_write(int64_t arc, const void *buf, size_t len) {
  if (!buf && len) return FL_EINVAL;
  jarc *a = tab_acquire(arc, T_ARC);
  if (!a) return FL_EINVAL;
  int rc = FL_EINVAL;
  if (a->w) {
    pthread_mutex_lock(&a->mu);
    rc = fl_arcw_write(a->w, buf, len);
    pthread_mutex_unlock(&a->mu);
  }
  tab_release(arc, T_ARC);
  return rc;
}

/* ---- fichiers age (phase 14) ---- */

int fj_agew_write(int64_t w, const void *buf, size_t len) {
  if (!buf && len) return FL_EINVAL;
  jarc *a = tab_acquire(w, T_AGEW);
  if (!a) return FL_EINVAL;
  pthread_mutex_lock(&a->mu);
  int rc = fl_agew_write(a->aw, buf, len);
  pthread_mutex_unlock(&a->mu);
  tab_release(w, T_AGEW);
  return rc;
}

int64_t fj_ager_size(int64_t r) {
  jarc *a = tab_acquire(r, T_AGER);
  if (!a) return FL_EINVAL;
  int64_t n = fl_ager_size(a->ar);
  tab_release(r, T_AGER);
  return n;
}

int64_t fj_ager_pread(int64_t r, void *buf, size_t len, uint64_t off) {
  if (!buf && len) return FL_EINVAL;
  jarc *a = tab_acquire(r, T_AGER);
  if (!a) return FL_EINVAL;
  if (len > FJ_PREAD_MAX) len = FJ_PREAD_MAX;
  pthread_mutex_lock(&a->mu); /* fl_ager_pread : un appel à la fois */
  int64_t n = fl_ager_pread(a->ar, buf, len, off);
  pthread_mutex_unlock(&a->mu);
  tab_release(r, T_AGER);
  return n;
}

/* log2 N, 0 si ce n'est pas un fichier age scrypt, ou fl_err ; `a` est seulement emprunté. */
static int peek(jarc *a) {
  uint8_t n = 0;
  int rc = fl_age_peek(&a->in, &n);
  return rc == 1 ? n : rc;
}

int fj_age_peek_fd(int fd) {
  struct stat st;
  if (fd < 0 || fstat(fd, &st) != 0) return FL_EINVAL;
  jarc *a = arc_new(fd);
  if (!a) return FL_ENOMEM;
  a->in.size = st.st_size;
  int rc = peek(a);
  a->fd = -1; /* le descripteur reste à l'appelant */
  arc_free(a, false);
  return rc;
}

int fj_age_peek_file(int64_t file, int64_t size) {
  if (size < 0) return FL_EINVAL;
  fl_file *f = tab_acquire(file, T_FILE);
  if (!f) return FL_EINVAL;
  jarc *a = arc_new(-1);
  int rc = FL_ENOMEM;
  if (a) {
    a->file = f;
    a->in.size = size;
    rc = peek(a);
    arc_free(a, false);
  }
  tab_release(file, T_FILE);
  return rc;
}

/* Extrémité de fj_age_rewrap : descripteur (pris) ou fichier du moteur (référence tenue jusqu'à end_close). */
static jarc *end_open(int fd, int64_t file, int64_t size) {
  if (fd >= 0) {
    jarc *a = arc_new(fd);
    if (!a) {
      close(fd);
      return NULL;
    }
    off_t sz = lseek(fd, 0, SEEK_END);
    a->in.size = sz < 0 ? 0 : sz;
    return a;
  }
  fl_file *f = file > 0 ? tab_acquire(file, T_FILE) : NULL;
  if (!f) return NULL;
  jarc *a = arc_new(-1);
  if (!a) {
    tab_release(file, T_FILE);
    return NULL;
  }
  a->file = f;
  a->in.size = size;
  return a;
}

/* Libère l'extrémité ; ferme le descripteur, ou relâche puis ferme le fichier (synchronisé). */
static int end_close(jarc *a, int fd, int64_t file) {
  int rc = FL_OK;
  if (a) {
    bool on_file = a->file != NULL;
    arc_free(a, false);
    if (on_file) tab_release(file, T_FILE);
  }
  if (fd < 0 && file > 0) {
    int rf = fj_close_file(file);
    if (rf != FL_EINVAL) rc = rf;
  }
  return rc;
}

int fj_age_rewrap(int in_fd, int64_t in_file, int64_t in_size, int out_fd, int64_t out_file, const void *old,
                  size_t oldlen, const void *nw, size_t nwlen, uint8_t log2n) {
  uint8_t *po = NULL, *pn = NULL;
  int rc = pass_take(old, oldlen, &po);
  if (rc == FL_OK) rc = pass_take(nw, nwlen, &pn);
  jarc *in = end_open(in_fd, in_file, in_size < 0 ? 0 : in_size);
  jarc *out = end_open(out_fd, out_file, 0);
  if (rc == FL_OK && (!in || !out || !po || !pn || in_size < 0)) rc = FL_EINVAL;
  if (rc == FL_OK) rc = fl_age_rewrap(&in->in, &out->out, po, oldlen, pn, nwlen, log2n);
  end_close(in, in_fd, in_file);
  int rw = end_close(out, out_fd, out_file);
  if (rc == FL_OK) rc = rw;
  pass_drop(po, oldlen);
  pass_drop(pn, nwlen);
  return rc;
}

/* ---- emplacements de clé d'un coffre (phase 14) ---- */

/* Disque d'un coffre : LUKS sur tout le disque, sans table. */
static int whole_disk_luks(fl_bdev *dev) {
  fl_part_table *t = calloc(1, sizeof *t);
  if (!t) return FL_ENOMEM;
  int rc = fl_part_scan(dev, t);
  if (rc == FL_OK && t->kind != FL_PT_NONE) rc = FL_ENOTSUP;
  free(t);
  return rc;
}

int fj_luks_slots(int64_t disk, fl_json *out) {
  jdisk *d = tab_acquire(disk, T_DISK);
  if (!d) return FL_EINVAL;
  int rc = whole_disk_luks(d->dev);
  fl_luks *l = NULL;
  uint32_t mask = 0;
  if (rc == FL_OK) rc = fl_luks_open(d->dev, &l);
  if (rc == FL_OK) rc = fl_luks_slots(d->dev, &mask);
  if (rc == FL_OK) {
    fl_json_reset(out);
    fl_json_obj_begin(out);
    fl_json_key(out, "version");
    fl_json_i64(out, fl_luks_version(l));
    fl_json_key(out, "slots");
    fl_json_arr_begin(out);
    for (int i = 0; i < 32; i++)
      if (mask & (1u << i)) fl_json_i64(out, i);
    fl_json_arr_end(out);
    fl_json_obj_end(out);
    rc = out->err;
  }
  fl_luks_close(l);
  tab_release(disk, T_DISK);
  return rc;
}

/* Prend le disque pour une modification d'emplacement : aucun volume monté ni en cours de montage, et plus aucun
 * montage ni formatage jusqu'à slot_end. */
static jdisk *slot_begin(int64_t disk, int *rc) {
  jdisk *d = tab_acquire(disk, T_DISK);
  if (!d) {
    *rc = FL_EINVAL;
    return NULL;
  }
  pthread_mutex_lock(&g_mu);
  if (d->formatting || d->mounting > 0 || live_children(disk, T_VOL) > 0) *rc = FL_EBUSY;
  else d->formatting = true;
  pthread_mutex_unlock(&g_mu);
  if (*rc == FL_OK) {
    *rc = whole_disk_luks(d->dev);
    if (*rc == FL_OK && d->dev->read_only) *rc = FL_EROFS;
    if (*rc != FL_OK) {
      pthread_mutex_lock(&g_mu);
      d->formatting = false;
      pthread_mutex_unlock(&g_mu);
    }
  }
  if (*rc != FL_OK) {
    tab_release(disk, T_DISK);
    return NULL;
  }
  return d;
}

static void slot_end(int64_t disk, jdisk *d) {
  pthread_mutex_lock(&g_mu);
  d->formatting = false;
  pthread_mutex_unlock(&g_mu);
  tab_release(disk, T_DISK);
}

int fj_luks_slot_set(int64_t disk, int slot, const void *auth, size_t authlen, const void *nw, size_t nwlen,
                     uint32_t kdf_mem_kib, uint32_t kdf_time) {
  uint8_t *pa = NULL, *pn = NULL;
  int rc = pass_take(auth, authlen, &pa);
  if (rc == FL_OK) rc = pass_take(nw, nwlen, &pn);
  jdisk *d = rc == FL_OK ? slot_begin(disk, &rc) : NULL;
  if (d) {
    rc = fl_luks2_slot_set(d->dev, slot, pa ? pa : auth, authlen, pn, nwlen, kdf_mem_kib, kdf_time);
    slot_end(disk, d);
  }
  pass_drop(pa, authlen);
  pass_drop(pn, nwlen);
  return rc;
}

int fj_luks_slot_remove(int64_t disk, int slot, const void *auth, size_t authlen) {
  uint8_t *pa = NULL;
  int rc = pass_take(auth, authlen, &pa);
  jdisk *d = rc == FL_OK ? slot_begin(disk, &rc) : NULL;
  if (d) {
    rc = fl_luks2_slot_remove(d->dev, slot, pa ? pa : auth, authlen);
    slot_end(disk, d);
  }
  pass_drop(pa, authlen);
  return rc;
}

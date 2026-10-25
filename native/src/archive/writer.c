#define _GNU_SOURCE
/* Écriture de ZIP sur libarchive (phase 9) : entrées poussées une à une, deflate (niveau 6) ou stockage au
 * choix par entrée, noms UTF-8 avec le drapeau UTF-8 (hdrcharset), ZIP64 quand une taille l'exige, champ de
 * date étendu (UTC) en plus de l'heure DOS. Un nom absolu, vide ou avec un segment « . », « .. » ou vide est
 * refusé ; un abandon (close sans commit) n'écrit plus rien sur la destination.
 * Phase 14 : ZIP chiffré WinZip AES-256 (libarchive sur mbedTLS), et ZIP écrit dans un flux age. */
#include <archive.h>
#include <archive_entry.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>

#include "archive/arc_internal.h"
#include "fluluks/age.h"
#include "fluluks/archive.h"
#include "fluluks/error.h"
#include "fluluks/secure.h"

struct fl_arc_writer {
  struct archive *a;
  const fl_arc_out *out;
  int io_err;          /* dernière erreur de la destination, 0 sinon */
  int64_t remaining;   /* octets encore attendus pour l'entrée courante */
  bool failed;         /* une erreur a eu lieu : seul close(false) reste permis */
  bool discard;        /* abandon : libarchive termine dans le vide, rien n'atteint la destination */
  fl_agew *age;        /* flux age sous le ZIP (fl_arcw_open_age), sinon NULL */
  fl_arc_out age_out;  /* sortie en clair écrite dans `age` */
};

static la_ssize_t cb_write(struct archive *a, void *data, const void *buf, size_t len) {
  fl_arc_writer *w = data;
  if (w->discard) return (la_ssize_t)len;
  int rc = w->out->write(w->out->ctx, buf, len);
  if (rc < 0) {
    w->io_err = rc;
    archive_set_error(a, EIO, "écriture de la destination : %d", rc);
    return -1;
  }
  return (la_ssize_t)len;
}

static int err_code(fl_arc_writer *w) {
  w->failed = true;
  return w->io_err ? w->io_err : FL_EIO;
}

/* Ouvre `w` (déjà alloué, w->out posé) ; libère l'archive en cas d'échec, pas `w`. */
static int open_writer(fl_arc_writer *w, const void *pass, size_t passlen) {
  w->a = archive_write_new();
  if (!w->a) return FL_ENOMEM;
  struct archive *a = w->a;
  char *c = NULL;
  if (pass) {
    /* copie terminée par NUL en mémoire sécurisée ; libarchive efface la sienne au archive_write_free */
    c = fl_secure_alloc(passlen + 1);
    if (!c) {
      archive_write_free(a);
      return FL_ENOMEM;
    }
    memcpy(c, pass, passlen);
  }
  locale_t old = fl_arc_utf8_begin();
  int rc = archive_write_set_format_zip(a);
  if (rc == ARCHIVE_OK) rc = archive_write_set_format_option(a, "zip", "hdrcharset", "UTF-8");
  if (rc == ARCHIVE_OK) rc = archive_write_set_format_option(a, "zip", "compression-level", "6");
  if (rc == ARCHIVE_OK && c) rc = archive_write_set_format_option(a, "zip", "encryption", "aes256");
  if (rc == ARCHIVE_OK && c) rc = archive_write_set_passphrase(a, c);
  if (c) fl_secure_free(c, passlen + 1);
  if (rc == ARCHIVE_OK) rc = archive_write_set_bytes_per_block(a, 64 * 1024);
  if (rc == ARCHIVE_OK) rc = archive_write_set_bytes_in_last_block(a, 1); /* pas de bourrage final */
  if (rc == ARCHIVE_OK) rc = archive_write_open2(a, w, NULL, cb_write, NULL, NULL);
  fl_arc_utf8_end(old);
  if (rc != ARCHIVE_OK) {
    int code = w->io_err ? w->io_err : FL_EIO;
    archive_write_fail(a);
    archive_write_free(a);
    w->a = NULL;
    return code;
  }
  return FL_OK;
}

int fl_arcw_open2(const fl_arc_out *out, const void *pass, size_t passlen, fl_arc_writer **wp) {
  if (!out || !out->write || !wp) return FL_EINVAL;
  *wp = NULL;
  if (pass && (passlen == 0 || memchr(pass, 0, passlen))) return FL_EINVAL;
  fl_arc_writer *w = calloc(1, sizeof *w);
  if (!w) return FL_ENOMEM;
  w->out = out;
  int code = open_writer(w, pass, passlen);
  if (code != FL_OK) {
    free(w);
    return code;
  }
  *wp = w;
  return FL_OK;
}

int fl_arcw_open(const fl_arc_out *out, fl_arc_writer **wp) { return fl_arcw_open2(out, NULL, 0, wp); }

static int age_write(void *ctx, const void *buf, size_t len) { return fl_agew_write(ctx, buf, len); }

int fl_arcw_open_age(const fl_arc_out *out, const void *pass, size_t passlen, uint8_t log2n, fl_arc_writer **wp) {
  if (!out || !out->write || !pass || !wp) return FL_EINVAL;
  *wp = NULL;
  fl_arc_writer *w = calloc(1, sizeof *w);
  if (!w) return FL_ENOMEM;
  int code = fl_agew_open(out, pass, passlen, log2n, &w->age);
  if (code == FL_OK) {
    w->age_out = (fl_arc_out){.ctx = w->age, .write = age_write};
    w->out = &w->age_out;
    code = open_writer(w, NULL, 0);
    if (code != FL_OK) fl_agew_close(w->age, false);
  }
  if (code != FL_OK) {
    free(w);
    return code;
  }
  *wp = w;
  return FL_OK;
}

/* Vrai si le nom est relatif, non vide, sans segment vide, « . » ni « .. ». */
static bool name_ok(const char *n) {
  if (!n || !*n || *n == '/') return false;
  for (const char *p = n; *p;) {
    const char *slash = strchr(p, '/');
    size_t len = slash ? (size_t)(slash - p) : strlen(p);
    if (len == 0 || (len == 1 && p[0] == '.') || (len == 2 && p[0] == '.' && p[1] == '.')) return false;
    if (!slash) break;
    p = slash + 1;
  }
  return true;
}

int fl_arcw_add(fl_arc_writer *w, const char *name_utf8, fl_arc_type type, int64_t size, int64_t mtime, bool store) {
  if (!w || w->failed || w->remaining != 0) return FL_EINVAL;
  if (!name_ok(name_utf8) || (type != FL_ARC_FILE && type != FL_ARC_DIR) || size < 0) return FL_EINVAL;
  struct archive_entry *e = archive_entry_new();
  if (!e) return FL_ENOMEM;
  locale_t old = fl_arc_utf8_begin();
  archive_entry_set_pathname_utf8(e, name_utf8);
  archive_entry_set_filetype(e, type == FL_ARC_DIR ? AE_IFDIR : AE_IFREG);
  archive_entry_set_perm(e, type == FL_ARC_DIR ? 0755 : 0644);
  archive_entry_set_size(e, type == FL_ARC_DIR ? 0 : size);
  archive_entry_set_mtime(e, (time_t)mtime, 0);
  int rc = store ? archive_write_zip_set_compression_store(w->a) : archive_write_zip_set_compression_deflate(w->a);
  if (rc == ARCHIVE_OK) rc = archive_write_header(w->a, e);
  fl_arc_utf8_end(old);
  archive_entry_free(e);
  if (rc != ARCHIVE_OK) return err_code(w);
  w->remaining = type == FL_ARC_DIR ? 0 : size;
  return FL_OK;
}

int fl_arcw_write(fl_arc_writer *w, const void *buf, size_t len) {
  if (!w || w->failed || (!buf && len)) return FL_EINVAL;
  if ((int64_t)len > w->remaining) return FL_EINVAL;
  size_t done = 0;
  while (done < len) {
    la_ssize_t n = archive_write_data(w->a, (const char *)buf + done, len - done);
    if (n <= 0) return err_code(w);
    done += (size_t)n;
  }
  w->remaining -= (int64_t)len;
  return FL_OK;
}

int fl_arcw_close(fl_arc_writer *w, bool commit) {
  if (!w) return FL_EINVAL;
  int code = FL_OK;
  if (commit && !w->failed && w->remaining == 0) {
    locale_t old = fl_arc_utf8_begin();
    if (archive_write_close(w->a) != ARCHIVE_OK) code = w->io_err ? w->io_err : FL_EIO;
    fl_arc_utf8_end(old);
  } else {
    if (commit) code = w->failed ? (w->io_err ? w->io_err : FL_EIO) : FL_EINVAL; /* entrée incomplète */
    if (w->failed) {
      archive_write_fail(w->a); /* archive_write_free n'écrit alors plus rien */
    } else {
      /* archive_write_fail perdrait l'état de compression de l'entrée en cours : libarchive termine
       * normalement, mais dans le vide */
      w->discard = true;
      locale_t old = fl_arc_utf8_begin();
      archive_write_close(w->a);
      fl_arc_utf8_end(old);
    }
  }
  archive_write_free(w->a);
  if (w->age) {
    /* le flux age se termine seulement si le ZIP est complet ; sinon plus rien n'est écrit */
    int c = fl_agew_close(w->age, commit && code == FL_OK);
    if (code == FL_OK && commit) code = c;
  }
  free(w);
  return code;
}

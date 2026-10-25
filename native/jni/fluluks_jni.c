/* Pont JNI du moteur FluLuks : conversion des arguments, le travail est fait par handles.c.
 *
 * Règles :
 *   - chaînes vers Java : ASCII seulement via NewStringUTF (version) ; tout le reste en byte[] UTF-8
 *     (JSON, messages d'erreur), car le « modified UTF-8 » de JNI casse les émojis ;
 *   - accès aux tableaux par GetByteArrayRegion / SetByteArrayRegion uniquement (jamais d'accès
 *     « critique » pendant une E/S, qui bloquerait le ramasse-miettes) ;
 *   - la phrase de passe est copiée en mémoire sécurisée puis le tableau Java est mis à zéro, sur tous
 *     les chemins (succès, erreur, poignée invalide) ; elle n'est jamais journalisée ;
 *   - erreurs : codes fl_err (< 0) ; les fonctions à JSON rendent {"err":<code>}. */
#include <jni.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "fluluks/error.h"
#include "fluluks/secure.h"
#include "handles.h"
#include "json_out.h"

#define FL_JNI_VERSION "fluluks 0.1.0"
#define FJ_PASS_MAX 8192   /* comme fluluks-cli */
#define PATH_BYTES 4096 /* chemins : 4095 octets au plus (fs.h) */

#define JNI_FN(name) Java_com_mawena_fluluks_engine_NativeEngine_##name

static jbyteArray to_bytes(JNIEnv *env, const char *s, size_t n) {
  if (n > (size_t)INT32_MAX) return NULL;
  jbyteArray a = (*env)->NewByteArray(env, (jsize)n);
  if (!a) return NULL; /* OutOfMemoryError en attente côté Java */
  if (n) (*env)->SetByteArrayRegion(env, a, 0, (jsize)n, (const jbyte *)s);
  return a;
}

/* Rend le JSON (ou {"err":rc}) et libère j. */
static jbyteArray json_result(JNIEnv *env, int rc, fl_json *j) {
  if (rc == FL_OK && j->err != FL_OK) rc = j->err;
  if (rc == FL_OK && !j->buf) rc = FL_EIO;
  if (rc != FL_OK) fl_json_error(j, rc);
  jbyteArray a = j->err == FL_OK && j->buf ? to_bytes(env, j->buf, j->len) : to_bytes(env, "{\"err\":-3}", 10);
  fl_json_free(j);
  return a;
}

/* Copie un byte[] d'au plus max octets en chaîne C terminée par NUL (malloc). NULL et *err si absent, trop
 * long ou avec un NUL. */
static char *cstr_from_max(JNIEnv *env, jbyteArray a, jsize max, int *err) {
  if (!a) {
    *err = FL_EINVAL;
    return NULL;
  }
  jsize n = (*env)->GetArrayLength(env, a);
  if (n < 0 || n > max) {
    *err = FL_EINVAL;
    return NULL;
  }
  char *s = malloc((size_t)n + 1);
  if (!s) {
    *err = FL_ENOMEM;
    return NULL;
  }
  if (n) (*env)->GetByteArrayRegion(env, a, 0, n, (jbyte *)s);
  s[n] = 0;
  if (memchr(s, 0, (size_t)n)) {
    free(s);
    *err = FL_EINVAL;
    return NULL;
  }
  return s;
}

static char *cstr_from(JNIEnv *env, jbyteArray a, int *err) { return cstr_from_max(env, a, PATH_BYTES, err); }

static void zero_array(JNIEnv *env, jbyteArray a, jsize n) {
  static const jbyte zeros[4096];
  for (jsize off = 0; off < n;) {
    jsize k = n - off < (jsize)sizeof zeros ? n - off : (jsize)sizeof zeros;
    (*env)->SetByteArrayRegion(env, a, off, k, zeros);
    off += k;
  }
}

JNIEXPORT jstring JNICALL JNI_FN(version)(JNIEnv *env, jobject thiz) {
  (void)thiz;
  /* Chaîne ASCII pure : NewStringUTF est sûr ici. */
  return (*env)->NewStringUTF(env, FL_JNI_VERSION);
}

JNIEXPORT jbyteArray JNICALL JNI_FN(strerror)(JNIEnv *env, jobject thiz, jint code) {
  (void)thiz;
  const char *m = fl_strerror(code);
  return to_bytes(env, m, strlen(m));
}

JNIEXPORT jlong JNICALL JNI_FN(openImage)(JNIEnv *env, jobject thiz, jbyteArray path, jboolean read_only) {
  (void)thiz;
  int err = FL_OK;
  char *p = cstr_from(env, path, &err);
  if (!p) return err;
  jlong h = fj_open_image(p, read_only == JNI_TRUE);
  free(p);
  return h;
}

JNIEXPORT jlong JNICALL JNI_FN(openUsb)(JNIEnv *env, jobject thiz, jint fd, jint iface, jint ep_in, jint ep_out) {
  (void)env;
  (void)thiz;
  return fj_open_usb(fd, iface, ep_in, ep_out);
}

JNIEXPORT jint JNICALL JNI_FN(closeDisk)(JNIEnv *env, jobject thiz, jlong disk) {
  (void)env;
  (void)thiz;
  return fj_close_disk(disk);
}

JNIEXPORT jbyteArray JNICALL JNI_FN(scan)(JNIEnv *env, jobject thiz, jlong disk) {
  (void)thiz;
  fl_json j;
  fl_json_init(&j);
  int rc = fj_scan(disk, &j);
  return json_result(env, rc, &j);
}

/* Copie la phrase de passe (NULL accepté) en mémoire sécurisée, puis met le tableau Java à zéro, sur tous
 * les chemins. *p à libérer par fl_secure_free(*p, *alloc). */
static int take_pass(JNIEnv *env, jbyteArray pass, uint8_t **p, size_t *plen, size_t *alloc) {
  *p = NULL;
  *plen = *alloc = 0;
  if (!pass) return FL_OK;
  int err = FL_OK;
  jsize n = (*env)->GetArrayLength(env, pass);
  if (n < 0 || n > FJ_PASS_MAX) {
    err = FL_EINVAL;
  } else {
    *alloc = n ? (size_t)n : 1;
    *p = fl_secure_alloc(*alloc);
    if (!*p) {
      err = FL_ENOMEM;
    } else {
      if (n) (*env)->GetByteArrayRegion(env, pass, 0, n, (jbyte *)*p);
      *plen = (size_t)n;
    }
  }
  zero_array(env, pass, n); /* avant toute validation : aussi sur les chemins d'erreur */
  return err;
}

JNIEXPORT jlong JNICALL JNI_FN(mount)(JNIEnv *env, jobject thiz, jlong disk, jint part, jbyteArray pass,
                                      jboolean writable) {
  (void)thiz;
  uint8_t *p;
  size_t plen, alloc;
  int err = take_pass(env, pass, &p, &plen, &alloc);
  jlong r = err;
  if (err == FL_OK) r = part < 0 ? FL_EINVAL : fj_mount(disk, (uint32_t)part, p, plen, writable == JNI_TRUE);
  fl_secure_free(p, alloc);
  return r;
}

JNIEXPORT jint JNICALL JNI_FN(unmount)(JNIEnv *env, jobject thiz, jlong vol, jboolean force) {
  (void)env;
  (void)thiz;
  return fj_unmount(vol, force == JNI_TRUE);
}

JNIEXPORT jbyteArray JNICALL JNI_FN(statfs)(JNIEnv *env, jobject thiz, jlong vol) {
  (void)thiz;
  fl_json j;
  fl_json_init(&j);
  int rc = fj_statfs(vol, &j);
  return json_result(env, rc, &j);
}

JNIEXPORT jbyteArray JNICALL JNI_FN(stat)(JNIEnv *env, jobject thiz, jlong vol, jbyteArray path) {
  (void)thiz;
  fl_json j;
  fl_json_init(&j);
  int rc = FL_OK;
  char *p = cstr_from(env, path, &rc);
  if (p) rc = fj_stat(vol, p, &j);
  free(p);
  return json_result(env, rc, &j);
}

JNIEXPORT jbyteArray JNICALL JNI_FN(list)(JNIEnv *env, jobject thiz, jlong vol, jbyteArray path) {
  (void)thiz;
  fl_json j;
  fl_json_init(&j);
  int rc = FL_OK;
  char *p = cstr_from(env, path, &rc);
  if (p) rc = fj_list(vol, p, &j);
  free(p);
  return json_result(env, rc, &j);
}

JNIEXPORT jlong JNICALL JNI_FN(openFile)(JNIEnv *env, jobject thiz, jlong vol, jbyteArray path, jint flags) {
  (void)thiz;
  int err = FL_OK;
  char *p = cstr_from(env, path, &err);
  if (!p) return err;
  jlong h = fj_open_file(vol, p, flags);
  free(p);
  return h;
}

JNIEXPORT jint JNICALL JNI_FN(pread)(JNIEnv *env, jobject thiz, jlong file, jlong offset, jbyteArray buf, jint len) {
  (void)thiz;
  if (!buf || len < 0 || offset < 0) return FL_EINVAL;
  if (len > (*env)->GetArrayLength(env, buf)) return FL_EINVAL;
  size_t n = (size_t)len < FJ_PREAD_MAX ? (size_t)len : FJ_PREAD_MAX;
  uint8_t one;
  uint8_t *tmp = n ? malloc(n) : &one; /* len 0 : valide quand même la poignée */
  if (!tmp) return FL_ENOMEM;
  int64_t r = fj_pread(file, tmp, n, (uint64_t)offset);
  if (r > 0) (*env)->SetByteArrayRegion(env, buf, 0, (jsize)r, (const jbyte *)tmp);
  if (n) free(tmp);
  return (jint)r; /* r <= FJ_PREAD_MAX ou fl_err */
}

JNIEXPORT jint JNICALL JNI_FN(closeFile)(JNIEnv *env, jobject thiz, jlong file) {
  (void)env;
  (void)thiz;
  return fj_close_file(file);
}

JNIEXPORT jint JNICALL JNI_FN(pwrite)(JNIEnv *env, jobject thiz, jlong file, jlong offset, jbyteArray buf, jint len) {
  (void)thiz;
  if (!buf || len < 0 || offset < 0) return FL_EINVAL;
  if (len > (*env)->GetArrayLength(env, buf) || (size_t)len > FJ_PREAD_MAX) return FL_EINVAL;
  uint8_t one;
  uint8_t *tmp = len ? malloc((size_t)len) : &one; /* len 0 : valide quand même la poignée */
  if (!tmp) return FL_ENOMEM;
  if (len) (*env)->GetByteArrayRegion(env, buf, 0, len, (jbyte *)tmp);
  int64_t r = fj_pwrite(file, tmp, (size_t)len, (uint64_t)offset);
  if (len) free(tmp);
  return (jint)r; /* r <= FJ_PREAD_MAX ou fl_err */
}

JNIEXPORT jint JNICALL JNI_FN(truncate)(JNIEnv *env, jobject thiz, jlong file, jlong size) {
  (void)env;
  (void)thiz;
  if (size < 0) return FL_EINVAL;
  return fj_truncate(file, (uint64_t)size);
}

/* Opération d'un chemin. */
static jint path_op(JNIEnv *env, jlong vol, jbyteArray path, int (*op)(int64_t, const char *)) {
  int err = FL_OK;
  char *p = cstr_from(env, path, &err);
  if (!p) return err;
  int rc = op(vol, p);
  free(p);
  return rc;
}

JNIEXPORT jint JNICALL JNI_FN(mkdir)(JNIEnv *env, jobject thiz, jlong vol, jbyteArray path) {
  (void)thiz;
  return path_op(env, vol, path, fj_mkdir);
}

JNIEXPORT jint JNICALL JNI_FN(unlink)(JNIEnv *env, jobject thiz, jlong vol, jbyteArray path) {
  (void)thiz;
  return path_op(env, vol, path, fj_unlink);
}

JNIEXPORT jint JNICALL JNI_FN(rmdir)(JNIEnv *env, jobject thiz, jlong vol, jbyteArray path) {
  (void)thiz;
  return path_op(env, vol, path, fj_rmdir);
}

JNIEXPORT jint JNICALL JNI_FN(rename)(JNIEnv *env, jobject thiz, jlong vol, jbyteArray from, jbyteArray to) {
  (void)thiz;
  int err = FL_OK;
  char *f = cstr_from(env, from, &err);
  if (!f) return err;
  char *t = cstr_from(env, to, &err);
  if (!t) {
    free(f);
    return err;
  }
  int rc = fj_rename(vol, f, t);
  free(f);
  free(t);
  return rc;
}

JNIEXPORT jint JNICALL JNI_FN(sync)(JNIEnv *env, jobject thiz, jlong vol) {
  (void)env;
  (void)thiz;
  return fj_sync(vol);
}

/* Formatage (phase 8) : listener (facultatif) reçoit onProgress(int) depuis ce fil. */
typedef struct {
  JNIEnv *env;
  jobject listener;
  jmethodID on_progress;
} progress_ctx;

static void on_progress(int pct, void *arg) {
  progress_ctx *c = arg;
  if (!c->on_progress) return;
  (*c->env)->CallVoidMethod(c->env, c->listener, c->on_progress, (jint)pct);
  if ((*c->env)->ExceptionCheck(c->env)) (*c->env)->ExceptionClear(c->env); /* l'affichage ne doit pas arrêter le formatage */
}

JNIEXPORT jint JNICALL JNI_FN(format)(JNIEnv *env, jobject thiz, jlong disk, jbyteArray opts, jbyteArray pass,
                                      jobject listener) {
  (void)thiz;
  uint8_t *p;
  size_t plen, alloc;
  int err = take_pass(env, pass, &p, &plen, &alloc);
  char *o = err == FL_OK ? cstr_from(env, opts, &err) : NULL;
  progress_ctx c = {env, listener, NULL};
  if (listener) {
    jclass k = (*env)->GetObjectClass(env, listener);
    c.on_progress = k ? (*env)->GetMethodID(env, k, "onProgress", "(I)V") : NULL;
    if ((*env)->ExceptionCheck(env)) {
      (*env)->ExceptionClear(env);
      c.on_progress = NULL;
    }
  }
  if (err == FL_OK) err = fj_format(disk, o, p, plen, on_progress, &c);
  free(o);
  fl_secure_free(p, alloc);
  return err;
}

/* ---- archives (phase 9) ---- */

#define ARC_JSON_BYTES 32768 /* fj_arcw_add : nom de 4095 octets échappé, et le reste */

/* JSON de l'entrée, {"err":rc}, ou null à la fin. */
JNIEXPORT jbyteArray JNICALL JNI_FN(arcNext)(JNIEnv *env, jobject thiz, jlong arc) {
  (void)thiz;
  fl_json j;
  fl_json_init(&j);
  int rc = fj_arc_next(arc, &j);
  if (rc == 0) {
    fl_json_free(&j);
    return NULL;
  }
  return json_result(env, rc == 1 ? FL_OK : rc, &j);
}

JNIEXPORT jint JNICALL JNI_FN(arcRead)(JNIEnv *env, jobject thiz, jlong arc, jbyteArray buf, jint len) {
  (void)thiz;
  if (!buf || len < 0 || len > (*env)->GetArrayLength(env, buf)) return FL_EINVAL;
  size_t n = (size_t)len < FJ_PREAD_MAX ? (size_t)len : FJ_PREAD_MAX;
  uint8_t one;
  uint8_t *tmp = n ? malloc(n) : &one; /* len 0 : valide quand même la poignée */
  if (!tmp) return FL_ENOMEM;
  int64_t r = fj_arc_read(arc, tmp, n);
  if (r > 0) (*env)->SetByteArrayRegion(env, buf, 0, (jsize)r, (const jbyte *)tmp);
  if (n) free(tmp);
  return (jint)r; /* r <= FJ_PREAD_MAX ou fl_err */
}

JNIEXPORT jint JNICALL JNI_FN(arcClose)(JNIEnv *env, jobject thiz, jlong arc) {
  (void)env;
  (void)thiz;
  return fj_arc_close(arc);
}

JNIEXPORT jint JNICALL JNI_FN(arcwAdd)(JNIEnv *env, jobject thiz, jlong arc, jbyteArray json) {
  (void)thiz;
  int err = FL_OK;
  char *s = cstr_from_max(env, json, ARC_JSON_BYTES, &err);
  if (!s) return err;
  int rc = fj_arcw_add(arc, s);
  free(s);
  return rc;
}

JNIEXPORT jint JNICALL JNI_FN(arcwWrite)(JNIEnv *env, jobject thiz, jlong arc, jbyteArray buf, jint len) {
  (void)thiz;
  if (!buf || len < 0 || len > (*env)->GetArrayLength(env, buf) || (size_t)len > FJ_PREAD_MAX) return FL_EINVAL;
  uint8_t one;
  uint8_t *tmp = len ? malloc((size_t)len) : &one;
  if (!tmp) return FL_ENOMEM;
  if (len) (*env)->GetByteArrayRegion(env, buf, 0, len, (jbyte *)tmp);
  int rc = fj_arcw_write(arc, tmp, (size_t)len);
  if (len) free(tmp);
  return rc;
}

JNIEXPORT jint JNICALL JNI_FN(arcwClose)(JNIEnv *env, jobject thiz, jlong arc, jboolean commit) {
  (void)env;
  (void)thiz;
  return fj_arcw_close(arc, commit == JNI_TRUE);
}

/* ---- chiffrement et coffres (phase 14) ---- */

/* ArcMode (Kotlin) → mode de handles.h ; une valeur inconnue est refusée par le moteur (FL_EINVAL). */
static const char *arc_mode(jint m) { return m == 0 ? NULL : m == 1 ? "aes" : m == 2 ? "age" : "?"; }

JNIEXPORT jlong JNICALL JNI_FN(arcOpenFd)(JNIEnv *env, jobject thiz, jint fd, jint mode, jbyteArray pass) {
  (void)thiz;
  uint8_t *p;
  size_t plen, alloc;
  int err = take_pass(env, pass, &p, &plen, &alloc);
  jlong r = err == FL_OK ? fj_arc_open_fd(fd, arc_mode(mode), p, plen) : err;
  if (err != FL_OK && fd >= 0) close(fd); /* le descripteur appartient à l'archive, même en échec */
  fl_secure_free(p, alloc);
  return r;
}

JNIEXPORT jlong JNICALL JNI_FN(arcOpenFile)(JNIEnv *env, jobject thiz, jlong file, jlong size, jint mode,
                                            jbyteArray pass) {
  (void)thiz;
  uint8_t *p;
  size_t plen, alloc;
  int err = take_pass(env, pass, &p, &plen, &alloc);
  jlong r = err == FL_OK ? fj_arc_open_file(file, size, arc_mode(mode), p, plen) : err;
  if (err != FL_OK) fj_close_file(file);
  fl_secure_free(p, alloc);
  return r;
}

JNIEXPORT jlong JNICALL JNI_FN(arcwOpenFd)(JNIEnv *env, jobject thiz, jint fd, jint mode, jbyteArray pass) {
  (void)thiz;
  uint8_t *p;
  size_t plen, alloc;
  int err = take_pass(env, pass, &p, &plen, &alloc);
  jlong r = err == FL_OK ? fj_arcw_open_fd(fd, arc_mode(mode), p, plen) : err;
  if (err != FL_OK && fd >= 0) close(fd);
  fl_secure_free(p, alloc);
  return r;
}

JNIEXPORT jlong JNICALL JNI_FN(arcwOpenFile)(JNIEnv *env, jobject thiz, jlong file, jint mode, jbyteArray pass) {
  (void)thiz;
  uint8_t *p;
  size_t plen, alloc;
  int err = take_pass(env, pass, &p, &plen, &alloc);
  jlong r = err == FL_OK ? fj_arcw_open_file(file, arc_mode(mode), p, plen) : err;
  if (err != FL_OK) fj_close_file(file);
  fl_secure_free(p, alloc);
  return r;
}

static int log2n_ok(jint n) { return n >= 1 && n <= 30; }

JNIEXPORT jlong JNICALL JNI_FN(ageWriterOpenFd)(JNIEnv *env, jobject thiz, jint fd, jbyteArray pass, jint log2n) {
  (void)thiz;
  uint8_t *p;
  size_t plen, alloc;
  int err = take_pass(env, pass, &p, &plen, &alloc);
  if (err == FL_OK && !log2n_ok(log2n)) err = FL_EINVAL;
  jlong r = err == FL_OK ? fj_agew_open_fd(fd, p, plen, (uint8_t)log2n) : err;
  if (err != FL_OK && fd >= 0) close(fd);
  fl_secure_free(p, alloc);
  return r;
}

JNIEXPORT jlong JNICALL JNI_FN(ageWriterOpenFile)(JNIEnv *env, jobject thiz, jlong file, jbyteArray pass,
                                                  jint log2n) {
  (void)thiz;
  uint8_t *p;
  size_t plen, alloc;
  int err = take_pass(env, pass, &p, &plen, &alloc);
  if (err == FL_OK && !log2n_ok(log2n)) err = FL_EINVAL;
  jlong r = err == FL_OK ? fj_agew_open_file(file, p, plen, (uint8_t)log2n) : err;
  if (err != FL_OK) fj_close_file(file);
  fl_secure_free(p, alloc);
  return r;
}

JNIEXPORT jint JNICALL JNI_FN(ageWrite)(JNIEnv *env, jobject thiz, jlong w, jbyteArray buf, jint len) {
  (void)thiz;
  if (!buf || len < 0 || len > (*env)->GetArrayLength(env, buf) || (size_t)len > FJ_PREAD_MAX) return FL_EINVAL;
  uint8_t one;
  uint8_t *tmp = len ? malloc((size_t)len) : &one;
  if (!tmp) return FL_ENOMEM;
  if (len) (*env)->GetByteArrayRegion(env, buf, 0, len, (jbyte *)tmp);
  int rc = fj_agew_write(w, tmp, (size_t)len);
  if (len) {
    fl_memzero(tmp, (size_t)len); /* clair à chiffrer : ne traîne pas dans le tas */
    free(tmp);
  }
  return rc;
}

JNIEXPORT jint JNICALL JNI_FN(ageWriterClose)(JNIEnv *env, jobject thiz, jlong w, jboolean commit) {
  (void)env;
  (void)thiz;
  return fj_agew_close(w, commit == JNI_TRUE);
}

JNIEXPORT jlong JNICALL JNI_FN(ageReaderOpenFd)(JNIEnv *env, jobject thiz, jint fd, jbyteArray pass) {
  (void)thiz;
  uint8_t *p;
  size_t plen, alloc;
  int err = take_pass(env, pass, &p, &plen, &alloc);
  jlong r = err == FL_OK ? fj_ager_open_fd(fd, p, plen) : err;
  if (err != FL_OK && fd >= 0) close(fd);
  fl_secure_free(p, alloc);
  return r;
}

JNIEXPORT jlong JNICALL JNI_FN(ageReaderOpenFile)(JNIEnv *env, jobject thiz, jlong file, jlong size,
                                                  jbyteArray pass) {
  (void)thiz;
  uint8_t *p;
  size_t plen, alloc;
  int err = take_pass(env, pass, &p, &plen, &alloc);
  jlong r = err == FL_OK ? fj_ager_open_file(file, size, p, plen) : err;
  if (err != FL_OK) fj_close_file(file);
  fl_secure_free(p, alloc);
  return r;
}

JNIEXPORT jlong JNICALL JNI_FN(ageSize)(JNIEnv *env, jobject thiz, jlong r) {
  (void)env;
  (void)thiz;
  return fj_ager_size(r);
}

JNIEXPORT jint JNICALL JNI_FN(agePread)(JNIEnv *env, jobject thiz, jlong r, jlong offset, jbyteArray buf, jint len) {
  (void)thiz;
  if (!buf || len < 0 || offset < 0 || len > (*env)->GetArrayLength(env, buf)) return FL_EINVAL;
  size_t n = (size_t)len < FJ_PREAD_MAX ? (size_t)len : FJ_PREAD_MAX;
  uint8_t one;
  uint8_t *tmp = n ? malloc(n) : &one;
  if (!tmp) return FL_ENOMEM;
  int64_t got = fj_ager_pread(r, tmp, n, (uint64_t)offset);
  if (got > 0) (*env)->SetByteArrayRegion(env, buf, 0, (jsize)got, (const jbyte *)tmp);
  if (n) {
    fl_memzero(tmp, n); /* clair déchiffré : ne traîne pas dans le tas */
    free(tmp);
  }
  return (jint)got;
}

JNIEXPORT jint JNICALL JNI_FN(ageReaderClose)(JNIEnv *env, jobject thiz, jlong r) {
  (void)env;
  (void)thiz;
  return fj_ager_close(r);
}

JNIEXPORT jint JNICALL JNI_FN(agePeekFd)(JNIEnv *env, jobject thiz, jint fd) {
  (void)env;
  (void)thiz;
  return fj_age_peek_fd(fd);
}

JNIEXPORT jint JNICALL JNI_FN(agePeekFile)(JNIEnv *env, jobject thiz, jlong file, jlong size) {
  (void)env;
  (void)thiz;
  return fj_age_peek_file(file, size);
}

JNIEXPORT jint JNICALL JNI_FN(ageRewrap)(JNIEnv *env, jobject thiz, jint in_fd, jlong in_file, jlong in_size,
                                         jint out_fd, jlong out_file, jbyteArray old, jbyteArray nw, jint log2n) {
  (void)thiz;
  uint8_t *po, *pn;
  size_t lo, ao, ln, an;
  int err = take_pass(env, old, &po, &lo, &ao);
  int err2 = take_pass(env, nw, &pn, &ln, &an); /* les deux tableaux sont mis à zéro dans tous les cas */
  if (err == FL_OK) err = err2;
  if (err == FL_OK && (!po || !pn || !log2n_ok(log2n))) err = FL_EINVAL;
  int rc = err == FL_OK ? fj_age_rewrap(in_fd, in_file, in_size, out_fd, out_file, po, lo, pn, ln, (uint8_t)log2n)
                        : fj_age_rewrap(in_fd, in_file, in_size, out_fd, out_file, NULL, 0, NULL, 0, 18);
  if (err != FL_OK) rc = err; /* l'appel sans phrase ne sert qu'à fermer les deux extrémités */
  fl_secure_free(po, ao);
  fl_secure_free(pn, an);
  return rc;
}

JNIEXPORT jlong JNICALL JNI_FN(openDiskFd)(JNIEnv *env, jobject thiz, jint fd, jboolean read_only) {
  (void)env;
  (void)thiz;
  return fj_open_disk_fd(fd, read_only == JNI_TRUE);
}

JNIEXPORT jlong JNICALL JNI_FN(openDiskOnFile)(JNIEnv *env, jobject thiz, jlong file, jlong size) {
  (void)env;
  (void)thiz;
  return fj_open_disk_file(file, size);
}

JNIEXPORT jbyteArray JNICALL JNI_FN(luksSlots)(JNIEnv *env, jobject thiz, jlong disk) {
  (void)thiz;
  fl_json j;
  fl_json_init(&j);
  int rc = fj_luks_slots(disk, &j);
  return json_result(env, rc, &j);
}

JNIEXPORT jint JNICALL JNI_FN(luksSlotSet)(JNIEnv *env, jobject thiz, jlong disk, jint slot, jbyteArray auth,
                                           jbyteArray nw, jint kdf_mem_kib, jint kdf_time) {
  (void)thiz;
  uint8_t *pa, *pn;
  size_t la, aa, ln, an;
  int err = take_pass(env, auth, &pa, &la, &aa);
  int err2 = take_pass(env, nw, &pn, &ln, &an);
  if (err == FL_OK) err = err2;
  if (err == FL_OK && (!pa || !pn || kdf_mem_kib < 0 || kdf_time < 0)) err = FL_EINVAL;
  int rc = err == FL_OK ? fj_luks_slot_set(disk, slot, pa, la, pn, ln, (uint32_t)kdf_mem_kib, (uint32_t)kdf_time) : err;
  fl_secure_free(pa, aa);
  fl_secure_free(pn, an);
  return rc;
}

JNIEXPORT jint JNICALL JNI_FN(luksSlotRemove)(JNIEnv *env, jobject thiz, jlong disk, jint slot, jbyteArray auth) {
  (void)thiz;
  uint8_t *pa;
  size_t la, aa;
  int err = take_pass(env, auth, &pa, &la, &aa);
  if (err == FL_OK && !pa) err = FL_EINVAL;
  int rc = err == FL_OK ? fj_luks_slot_remove(disk, slot, pa, la) : err;
  fl_secure_free(pa, aa);
  return rc;
}

JNIEXPORT jlong JNICALL JNI_FN(mountSlot)(JNIEnv *env, jobject thiz, jlong disk, jint part, jint slot,
                                          jbyteArray pass, jboolean writable) {
  (void)thiz;
  uint8_t *p;
  size_t plen, alloc;
  int err = take_pass(env, pass, &p, &plen, &alloc);
  jlong r = err;
  if (err == FL_OK) r = part < 0 ? FL_EINVAL : fj_mount_slot(disk, (uint32_t)part, slot, p, plen, writable == JNI_TRUE);
  fl_secure_free(p, alloc);
  return r;
}

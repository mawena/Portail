/* Voir tool_run.h. */

#define _GNU_SOURCE

#include "partops/tool_run.h"

#include <pthread.h>
#include <string.h>
#include <sys/types.h>

#include "fluluks/error.h"

#define BIG_STACK (8u << 20)

static ssize_t cap_write(void *cookie, const char *data, size_t n) {
  fl_capture *c = cookie;
  if (c->buf && c->len + 1 < c->cap) {
    size_t k = c->cap - 1 - c->len < n ? c->cap - 1 - c->len : n;
    memcpy(c->buf + c->len, data, k);
    c->len += k;
    c->buf[c->len] = '\0';
  }
  return (ssize_t)n;
}

#ifdef __BIONIC__
/* Bionic : funopen (BSD) ; fopencookie n'y existe qu'à partir de l'API 32. */
static int cap_write_bsd(void *cookie, const char *data, int n) {
  return n < 0 ? -1 : (int)cap_write(cookie, data, (size_t)n);
}
#endif

FILE *fl_capture_open(fl_capture *c) {
  c->len = 0;
  if (c->buf && c->cap) c->buf[0] = '\0';
#ifdef __BIONIC__
  FILE *f = funopen(c, NULL, cap_write_bsd, NULL, NULL);
#else
  cookie_io_functions_t io = {.write = cap_write};
  FILE *f = fopencookie(c, "w", io);
#endif
  if (f) setvbuf(f, NULL, _IONBF, 0);
  return f;
}

typedef struct {
  int (*fn)(void *);
  void *arg;
  int rc;
} job;

static void *trampoline(void *p) {
  job *j = p;
  j->rc = j->fn(j->arg);
  return NULL;
}

int fl_run_big_stack(int (*fn)(void *), void *arg) {
  job j = {fn, arg, FL_EIO};
  pthread_attr_t a;
  pthread_t t;
  int rc = FL_ENOMEM;
  if (pthread_attr_init(&a) != 0) return rc;
  if (pthread_attr_setstacksize(&a, BIG_STACK) == 0 && pthread_create(&t, &a, trampoline, &j) == 0) {
    pthread_join(t, NULL);
    rc = j.rc;
  }
  pthread_attr_destroy(&a);
  return rc;
}

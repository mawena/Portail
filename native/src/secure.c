#define _DEFAULT_SOURCE
#include "fluluks/secure.h"

#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/mman.h>


void *fl_secure_alloc(size_t n) {
  if (n == 0) n = 1;
  void *p = calloc(1, n);
  if (p) (void)mlock(p, n); /* au mieux : l'échec (RLIMIT_MEMLOCK) est toléré */
  return p;
}

static void (*g_free_hook)(void *, const void *, size_t);
static void *g_free_hook_arg;

void fl_secure_debug_set_free_hook(void (*fn)(void *arg, const void *p, size_t n), void *arg) {
  g_free_hook = fn;
  g_free_hook_arg = arg;
}

void fl_secure_free(void *p, size_t n) {
  if (!p) return;
  if (n == 0) n = 1;
  if (g_free_hook) g_free_hook(g_free_hook_arg, p, n);
  fl_memzero(p, n);
  (void)munlock(p, n);
  free(p);
}

#ifndef FL_PARTOPS_TOOL_RUN_H
#define FL_PARTOPS_TOOL_RUN_H

/* Outils d'amont appelés comme bibliothèque (e2fsck, resize2fs, ntfsresize, ntfsfix ; phase 18) : sortie
 * gardée dans un tampon borné, appel sur un fil à grande pile. */

#include <stddef.h>
#include <stdio.h>

typedef struct {
  char *buf;       /* NULL : sortie jetée */
  size_t cap, len; /* len < cap, buf[len] = NUL */
} fl_capture;

/* FILE* sans tampon qui garde les cap - 1 premiers octets écrits dans c->buf (le reste est compté puis
 * jeté). NULL si la mémoire manque. */
FILE *fl_capture_open(fl_capture *c);
/* fn(arg) sur un fil à pile de 8 Mio, attendu jusqu'à sa fin : son code, ou FL_ENOMEM si le fil n'a pas pu
 * être créé. */
int fl_run_big_stack(int (*fn)(void *), void *arg);

#endif

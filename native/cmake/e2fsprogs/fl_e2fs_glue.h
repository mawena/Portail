/* Inclus de force dans chaque fichier d'e2fsprogs (cmake/e2fsprogs.cmake) : e2fsck et resize2fs
 * deviennent une bibliothèque, sans toucher aux sources d'amont. Voir fl_e2fs_glue.c. */
#ifndef FL_E2FS_GLUE_H
#define FL_E2FS_GLUE_H

#include <stdio.h>
#include <stdlib.h>

FILE *fl_e2fs_stdout(void);
void fl_e2fs_exit(int code) __attribute__((noreturn));
int fl_e2fs_puts(const char *s);

#ifndef FL_E2FS_GLUE_IMPL
#undef stdout
#undef stderr
#define stdout (fl_e2fs_stdout())
#define stderr (fl_e2fs_stdout())
#define printf(...) fprintf(fl_e2fs_stdout(), __VA_ARGS__)
#define vprintf(f, a) vfprintf(fl_e2fs_stdout(), (f), (a))
#define puts(s) fl_e2fs_puts(s)
#define putchar(c) fputc((c), fl_e2fs_stdout())
#define exit(c) fl_e2fs_exit(c)
#endif

#endif

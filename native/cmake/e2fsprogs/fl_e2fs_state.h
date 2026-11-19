/* Variables de fl_e2fs_glue.c, remplies par le moteur (src/partops/e2fs.c). */
#ifndef FL_E2FS_STATE_H
#define FL_E2FS_STATE_H

#include <setjmp.h>
#include <stdint.h>
#include <stdio.h>

#include "ext2fs/ext2_fs.h"
#include "ext2fs/ext2fs.h"

extern io_manager fl_e2fs_io_manager;  /* remplace unix_io_manager */
extern FILE *fl_e2fs_report;           /* sortie de l'appel en cours (NULL : stderr) */
extern jmp_buf *fl_e2fs_jump;          /* retour de fl_e2fs_exit */
extern int fl_e2fs_exit_code;          /* code passé à exit() */
extern uint64_t fl_e2fs_dev_bytes;     /* taille du volume, pour ext2fs_get_device_size2 */
#define FL_E2FS_DEVNAME "fl-volume"
void fl_e2fs_reset_globals(void);
int fl_e2fsck_main(int argc, char *argv[]);

#endif

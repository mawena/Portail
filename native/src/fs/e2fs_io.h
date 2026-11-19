#ifndef FL_FS_E2FS_IO_H
#define FL_FS_E2FS_IO_H

#include "ext2fs/ext2_fs.h"
#include "ext2fs/ext2fs.h"
#include "fluluks/blockdev.h"

/* io_manager d'e2fsprogs sur fl_bdev. Le canal ouvert parle au volume lié par fl_e2fs_io_bind (NULL :
 * aucun ; l'ouverture échoue). Appelé seulement sous le verrou de src/partops/e2fs.c. */
io_manager fl_e2fs_bdev_manager(void);
void fl_e2fs_io_bind(fl_bdev *vol);
/* Première erreur rendue par le volume lié (FL_OK : aucune), pour distinguer un disque débranché d'un
 * système de fichiers abîmé. */
int fl_e2fs_io_error(void);

#endif

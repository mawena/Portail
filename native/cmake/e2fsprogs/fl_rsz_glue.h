/* Inclus de force dans resize/resize2fs.c seul, après fl_e2fs_glue.h (cmake/e2fsprogs.cmake). En amont,
 * le chemin d'erreur de resize_fs (« errout ») libère rfs sans ses bitmaps reserve_blocks et move_blocks :
 * l'outil quitte aussitôt, mais dans le moteur ce serait une fuite à chaque échec. Ici, la libération de
 * rfs passe par fl_rsz_free_rfs (fl_rsz_glue.c), qui les libère d'abord quand old_fs est encore là (chemin d'erreur ;
 * le chemin réussi met old_fs à NULL et a déjà libéré ces bitmaps). Aucun correctif du code amont. */
#ifndef FL_RSZ_GLUE_H
#define FL_RSZ_GLUE_H

#include "config.h"
#include "ext2fs/ext2fs.h"

struct ext2_resize_struct;
errcode_t fl_rsz_free_rfs(struct ext2_resize_struct **p); /* fl_rsz_glue.c */

#define ext2fs_free_mem(p) \
  _Generic((p), struct ext2_resize_struct **: fl_rsz_free_rfs, default: ext2fs_free_mem)(p)

#endif

/* Voir fl_rsz_glue.h : libère les bitmaps que le chemin d'erreur de resize_fs oublie. */
#include "config.h"
#include "resize2fs.h"

errcode_t fl_rsz_free_rfs(struct ext2_resize_struct **p) {
  ext2_resize_t r = *p;
  if (r && r->old_fs) {
    if (r->reserve_blocks) ext2fs_free_block_bitmap(r->reserve_blocks);
    if (r->move_blocks) ext2fs_free_block_bitmap(r->move_blocks);
    r->reserve_blocks = r->move_blocks = NULL;
  }
  return ext2fs_free_mem(p);
}

/* ntfsresize de ntfs-3g 2022.10.3 comme bibliothèque (phase 18). La source d'amont est incluse telle quelle ;
 * fl_ntt_resize reprend le déroulé de son main (« --info » ou « --size »), sans ligne de commande ni question,
 * sur le volume du moteur (ntfs_tool.h). */

#define _GNU_SOURCE
#include "partops/ntfs_tool_prelude.h"
#undef main
#define main static fl_ntt_unused_main_resize
#define ntfs_device_default_io_ops fl_ntt_dummy_ops
extern struct ntfs_device_operations fl_ntt_dummy_ops;

/* Inodes ouverts par ntfsresize, suivis : lookup_data_attr d'amont n'en referme aucun (fuite), et un exit()
 * au milieu laisserait les autres. Ils sont rendus, sans écriture, avant le démontage. */
#define NR_INODES 64
static ntfs_inode *g_inodes[NR_INODES];

static ntfs_inode *fl_nr_inode_open(ntfs_volume *vol, const MFT_REF mref) {
  ntfs_inode *ni = ntfs_inode_open(vol, mref);
  for (int i = 0; ni && i < NR_INODES; i++)
    if (!g_inodes[i]) {
      g_inodes[i] = ni;
      break;
    }
  return ni;
}

static int fl_nr_inode_close(ntfs_inode *ni) {
  for (int i = 0; ni && i < NR_INODES; i++)
    if (g_inodes[i] == ni) g_inodes[i] = NULL;
  return ntfs_inode_close(ni);
}

/* Rend les inodes encore ouverts sans rien écrire : ntfsresize écrit lui-même ses enregistrements MFT. */
static void release_inodes(void) {
  for (int i = 0; i < NR_INODES; i++) {
    ntfs_inode *ni = g_inodes[i];
    g_inodes[i] = NULL;
    if (!ni) continue;
    NInoClearDirty(ni);
    NInoAttrListClearDirty(ni);
    ntfs_inode_close(ni);
  }
}

#define ntfs_inode_open fl_nr_inode_open
#define ntfs_inode_close fl_nr_inode_close

#include "ntfsresize.c"

#undef ntfs_inode_open
#undef ntfs_inode_close

#undef main
#undef exit

static ntfsck_t g_fsck;
static ntfs_resize_t g_resize;

/* La table des amas passe de g_fsck à g_resize, qui peut la réallouer (truncate_bitmap_data_attr) : une seule
 * des deux copies du pointeur est à jour. */
void fl_ntt_resize_cleanup(void) {
  release_inodes();
  free(g_resize.lcn_bitmap.bm ? g_resize.lcn_bitmap.bm : g_fsck.lcn_bitmap.bm);
  memset(&g_fsck, 0, sizeof g_fsck);
  memset(&g_resize, 0, sizeof g_resize);
}

int fl_ntt_resize(long long dev_bytes, long long new_bytes, long long *min_bytes, fl_ntt_progress cb, void *arg) {
  memset(&opt, 0, sizeof opt);
  opt.volume = FL_NTT_DEVNAME;
  opt.info = new_bytes == 0;
  opt.ro_flag = opt.info ? NTFS_MNT_RDONLY : 0;
  opt.bytes = new_bytes;
  opt.reliable_size = 1;
  fl_ntt_resize_cleanup();

  printf("%s v%s (libntfs-3g)\n", EXEC_NAME, VERSION);
  ntfs_volume *vol = mount_volume(); /* refuse un volume marqué à vérifier (opt.force = 0) */
  s64 device_size = dev_bytes;
  print_vol_size("Current device size", device_size);
  if (device_size < vol->nr_clusters * vol->cluster_size)
    err_exit("Current NTFS volume size is bigger than the device size!\n");

  s64 new_size = opt.bytes > vol->sector_size ? (opt.bytes - vol->sector_size) / vol->cluster_size : 0;
  if (!opt.info) {
    print_vol_size("New volume size    ", vol_size(vol, new_size));
    if (device_size < opt.bytes) err_exit("New size can't be bigger than the device size.\n");
    if (new_size == vol->nr_clusters || (opt.bytes == device_size && new_size == vol->nr_clusters - 1)) {
      printf("Nothing to do: NTFS volume size is already OK.\n");
      release_inodes();
      ntfs_umount(vol, 0);
      return 0;
    }
  }

  g_resize.vol = vol;
  g_resize.new_volume_size = new_size;
  if (new_size < vol->nr_clusters) g_resize.shrink = 1;
  g_resize.badclusters = check_bad_sectors(vol);
  NVolSetNoFixupWarn(vol);
  check_cluster_allocation(vol, &g_fsck);
  print_disk_usage(vol, g_fsck.inuse);
  g_resize.inuse = g_fsck.inuse;
  g_resize.lcn_bitmap = g_fsck.lcn_bitmap;
  g_resize.mirr_from = MIRR_OLD;
  set_resize_constraints(&g_resize);
  set_disk_usage_constraint(&g_resize);
  check_resize_constraints(&g_resize);

  if (opt.info) {
    advise_on_resize(&g_resize);
    /* comme print_advise : prochain amas utilisable, plus un amas pour la copie du secteur de démarrage,
     * plus le secteur de cette copie au bout de la partition */
    if (min_bytes) *min_bytes = (g_resize.last_unsupp + 2) * vol->cluster_size + vol->sector_size;
    fl_ntt_resize_cleanup();
    ntfs_umount(vol, 0);
    return 0;
  }
  if (cb) cb(10, arg);

  prepare_volume_fixup(vol);
  if (g_resize.relocations) relocate_inodes(&g_resize);
  if (cb) cb(70, arg);
  truncate_badclust_file(&g_resize);
  truncate_bitmap_file(&g_resize);
  delayed_updates(&g_resize);
  update_bootsector(&g_resize);
  if (cb) cb(90, arg);

  printf("Syncing device ...\n");
  if (vol->dev->d_ops->sync(vol->dev) == -1) perr_exit("fsync");
  printf("Successfully resized NTFS on device '%s'.\n", vol->dev->d_name);
  if (g_resize.shrink) printf("%s", resize_important_msg);
  fl_ntt_resize_cleanup();
  if (ntfs_umount(vol, 0)) return 1;
  if (cb) cb(100, arg);
  return 0;
}

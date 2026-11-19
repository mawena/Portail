/* ntfsfix de ntfs-3g 2022.10.3 comme bibliothèque (phase 18), en « -n » seulement (rien n'est écrit). La source
 * d'amont est incluse telle quelle ; fl_ntt_fixcheck reprend le déroulé de son main pour « -n ». */

#define _GNU_SOURCE
#include "partops/ntfs_tool_prelude.h"
#undef main
#define main static fl_ntt_unused_main_fix
#define ntfs_device_default_io_ops fl_ntt_dummy_ops
extern struct ntfs_device_operations fl_ntt_dummy_ops;

#include "ntfsfix.c"

#undef main
#undef exit

int fl_ntt_fixcheck(bool *dirty, bool *mounted) {
  memset(&opt, 0, sizeof opt);
  opt.volume = FL_NTT_DEVNAME;
  opt.no_action = TRUE;
  *dirty = false;
  *mounted = false;

  ntfs_log_info("Mounting volume... ");
  ntfs_volume *vol = ntfs_mount(opt.volume, NTFS_MNT_RDONLY);
  if (vol) {
    ntfs_log_info(OK);
    ntfs_log_info("Processing of $MFT and $MFTMirr completed successfully.\n");
  } else {
    ntfs_log_info(FAILED);
    if (fix_mount() < 0) {
      ntfs_log_info("No change made\n");
      return 1;
    }
    vol = ntfs_mount(opt.volume, NTFS_MNT_RDONLY);
    if (!vol) {
      ntfs_log_perror("Remount failed");
      return 1;
    }
  }
  *mounted = true;
  int ret = 0;
  if (check_alternate_boot(vol)) {
    ntfs_log_error("Error: Failed to fix the alternate boot sector\n");
    ret = 1;
  }
  *dirty = (vol->flags & VOLUME_IS_DIRTY) != 0;
  if (*dirty) ntfs_log_info("Volume is marked dirty (scheduled for check by Windows).\n");
  ntfs_log_info("NTFS volume version is %i.%i.\n", vol->major_ver, vol->minor_ver);
  if (ntfs_version_is_supported(vol)) {
    ntfs_log_error("Error: Unknown NTFS version.\n");
    ret = 1;
  }
  if (!ret) ntfs_log_info("NTFS partition %s was processed successfully.\n", vol->dev->d_name);
  if (ntfs_umount(vol, 1)) ret = 1;
  return ret;
}

/* Inclus par ntfsresize_tool.c et ntfsfix_tool.c avant la source d'amont : en-têtes d'abord (leurs
 * déclarations gardent les vrais noms), puis les macros qui détournent ce que l'outil appelle. */
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <limits.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* config.h inclus ici une fois (HAVE_CONFIG_H n'est pas défini pour ces fichiers) : l'outil d'amont refuse
 * de se compiler sans accès disque par défaut, que nous remplaçons. */
#include "config.h"
#undef NO_NTFS_DEVICE_DEFAULT_IO_OPS
#include "types.h"
#include "param.h"
#include "debug.h"
#include "support.h"
#include "endians.h"
#include "bootsect.h"
#include "device.h"
#include "attrib.h"
#include "volume.h"
#include "mft.h"
#include "bitmap.h"
#include "inode.h"
#include "runlist.h"
#include "logfile.h"
#include "mst.h"
#include "logging.h"
#include "misc.h"
#include "utils.h"

#include "partops/ntfs_tool.h"

#undef stdout
#undef stderr
#define stdout (fl_ntt_out())
#define stderr (fl_ntt_out())
#define printf(...) fprintf(fl_ntt_out(), __VA_ARGS__)
#define vprintf(f, a) vfprintf(fl_ntt_out(), (f), (a))
#define puts(s) (fputs((s), fl_ntt_out()), fputc('\n', fl_ntt_out()))
#define putchar(c) fputc((c), fl_ntt_out())
#define exit(c) fl_ntt_exit(c)
#define ntfs_mount fl_ntt_mount
#define ntfs_umount fl_ntt_umount
#define ntfs_device_alloc fl_ntt_device_alloc
#define ntfs_device_free fl_ntt_device_free
#define ntfs_volume_startup fl_ntt_volume_startup
#define ntfs_check_if_mounted fl_ntt_check_if_mounted
/* journal des outils : laissé à notre gestionnaire (fl_ntt_begin) */
#define ntfs_log_set_handler(h) ((void)(h))

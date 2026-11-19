#ifndef FL_PARTOPS_NTFS_TOOL_H
#define FL_PARTOPS_NTFS_TOOL_H

/* ntfsresize et ntfsfix de ntfs-3g appelés comme bibliothèque (phase 18). Leurs sources d'amont, intactes,
 * sont incluses dans ntfsresize_tool.c et ntfsfix_tool.c après ces macros : leurs ouvertures de volume
 * passent par le volume du moteur, leurs exit() reviennent à l'appelant par longjmp, leurs sorties vont dans
 * le rapport. Un seul appel à la fois, sous le verrou des systèmes de fichiers. */

#include <setjmp.h>
#include <stdbool.h>
#include <stdio.h>

#include "fluluks/blockdev.h"
#include "ntfs-3g/device.h"
#include "ntfs-3g/volume.h"

#define FL_NTT_DEVNAME "fl-volume"

/* Début d'un appel : volume, écriture permise ou non, sortie (rapport). */
void fl_ntt_begin(fl_bdev *bd, bool writable, FILE *out);
/* Fin d'un appel : tout volume encore monté est démonté (sans écriture forcée), tout périphérique libéré.
 * Rend la première erreur du disque vue pendant l'appel (FL_OK sinon). */
int fl_ntt_end(void);
/* Première erreur du disque vue jusqu'ici (FL_OK sinon). */
int fl_ntt_io_error(void);

/* Remplaçants de libntfs-3g pour les outils. */
ntfs_volume *fl_ntt_mount(const char *name, ntfs_mount_flags flags);
struct ntfs_device *fl_ntt_device_alloc(const char *name, int state, struct ntfs_device_operations *dops,
                                        void *priv_data);
int fl_ntt_device_free(struct ntfs_device *dev);
ntfs_volume *fl_ntt_volume_startup(struct ntfs_device *dev, ntfs_mount_flags flags);
int fl_ntt_umount(ntfs_volume *vol, const BOOL force);
int fl_ntt_check_if_mounted(const char *file, unsigned long *mnt_flags);

FILE *fl_ntt_out(void);
void fl_ntt_exit(int code) __attribute__((noreturn));
extern jmp_buf *fl_ntt_jump;
extern int fl_ntt_exit_code;

/* Pilotes (ntfsresize_tool.c, ntfsfix_tool.c). */
typedef void (*fl_ntt_progress)(int pct, void *arg);
/* new_bytes = 0 : « ntfsresize --info » ; *min_bytes = taille de partition minimale (volume réduit au plus
 * court, plus le secteur de la copie du secteur de démarrage). Sinon : redimensionne à new_bytes.
 * Rend 0, ou le code d'exit() de l'outil (1 : refus ou erreur). */
int fl_ntt_resize(long long dev_bytes, long long new_bytes, long long *min_bytes, fl_ntt_progress cb, void *arg);
void fl_ntt_resize_cleanup(void);
/* « ntfsfix -n » : 0 si rien à redire, 1 sinon ; *dirty : volume marqué à vérifier ; *mounted : le volume
 * a pu être ouvert. */
int fl_ntt_fixcheck(bool *dirty, bool *mounted);

#endif

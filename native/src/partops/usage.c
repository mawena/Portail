/* Contenu, étiquette et place occupée d'une partition (phase 17), pour la vue du disque : le système de
 * fichiers est monté en lecture seule le temps d'un statfs. Une partition chiffrée ou inconnue n'a que
 * son contenu (et l'étiquette que la sonde sait lire). */
#include <stdlib.h>
#include <string.h>

#include "fluluks/error.h"
#include "fluluks/fs.h"
#include "fluluks/partedit.h"
#include "fluluks/partops.h"
#include "fluluks/probe.h"

static bool mountable(fl_content c) {
  return c == FL_CONTENT_EXT4 || c == FL_CONTENT_FAT12 || c == FL_CONTENT_FAT16 || c == FL_CONTENT_FAT32 ||
         c == FL_CONTENT_EXFAT || c == FL_CONTENT_NTFS;
}

int fl_part_usage_of(fl_bdev *disk, uint32_t index, fl_part_usage *out) {
  if (!disk || !out) return FL_EINVAL;
  memset(out, 0, sizeof *out);
  fl_pt_layout *l = calloc(1, sizeof *l);
  if (!l) return FL_ENOMEM;
  int rc = fl_pt_load(disk, l);
  const fl_pt_entry *p = NULL;
  for (uint32_t i = 0; rc == FL_OK && i < l->count; i++)
    if (l->e[i].index == index) p = &l->e[i];
  if (rc == FL_OK && !p) rc = FL_ENOENT;
  fl_bdev *s = NULL;
  if (rc == FL_OK) rc = fl_slice_bdev_new(disk, p->first_lba, p->sector_count, &s);
  free(l);
  if (rc != FL_OK) return rc;
  fl_probe_result pr;
  rc = fl_probe(s, &pr);
  if (rc == FL_OK) {
    out->content = pr.content;
    memcpy(out->label, pr.label, sizeof out->label);
    fl_fs *fs = NULL;
    fl_statfs st;
    /* un système de fichiers illisible n'est pas une erreur de la vue : seulement « inconnu » */
    if (mountable(pr.content) && fl_fs_mount(s, pr.content, false, &fs) == FL_OK) {
      if (fl_fs_statfs(fs, &st) == FL_OK && st.free_bytes <= st.total_bytes) {
        out->known = true;
        out->total_bytes = st.total_bytes;
        out->used_bytes = st.total_bytes - st.free_bytes;
        if (st.label[0]) memcpy(out->label, st.label, sizeof out->label);
      }
      fl_fs_unmount(fs);
    }
  }
  fl_bdev_close(s);
  return rc;
}

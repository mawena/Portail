/* Créer, supprimer et formater une partition (phase 17).
 *
 * Chaque opération relit la table (fl_pt_load) et revérifie tout avant d'écrire : la partition visée doit
 * être au début attendu (FL_ECHANGED sinon), la nouvelle table doit passer fl_pt_validate, la place doit
 * suffire au format. Une table MBR à partition étendue n'est jamais réécrite (FL_ENOTSUP). La création
 * écrit la table avant le système de fichiers : un échec ensuite laisse une partition vide, jamais une
 * table qui désigne des données d'une autre partition. */
#include <stdlib.h>
#include <string.h>

#include "fluluks/error.h"
#include "fluluks/partedit.h"
#include "fluluks/partops.h"
#include "format/format_internal.h"

#define MIB (1024ull * 1024ull)

/* Table relue, ou FL_ENOTSUP si elle ne se modifie pas ici. */
static int load_editable(fl_bdev *disk, fl_pt_layout **out) {
  fl_pt_layout *l = calloc(1, sizeof *l);
  if (!l) return FL_ENOMEM;
  int rc = fl_pt_load(disk, l);
  if (rc == FL_OK && (l->kind == FL_PT_NONE)) rc = FL_EINVAL; /* créer une table d'abord */
  if (rc == FL_OK && l->has_extended) rc = FL_ENOTSUP;
  if (rc != FL_OK) {
    free(l);
    return rc;
  }
  *out = l;
  return FL_OK;
}

/* Position de `index` dans la table, s'il est au début attendu ; -1 sinon. */
static int find(const fl_pt_layout *l, uint32_t index, uint64_t expect_first_lba) {
  for (uint32_t i = 0; i < l->count; i++)
    if (l->e[i].index == index) return l->e[i].first_lba == expect_first_lba ? (int)i : -1;
  return -1;
}

/* Index libre : GPT 1..128, MBR 1..4 ; 0 si la table est pleine. */
static uint32_t free_index(const fl_pt_layout *l) {
  uint32_t max = l->kind == FL_PT_GPT ? 128 : 4;
  for (uint32_t idx = 1; idx <= max; idx++) {
    bool taken = false;
    for (uint32_t i = 0; i < l->count && !taken; i++) taken = l->e[i].index == idx;
    if (!taken) return idx;
  }
  return 0;
}

static void set_type(fl_pt_entry *p, fl_pt_kind kind, const fl_fmt_opts *o) {
  uint8_t mt, gt[16];
  fl_fmt_part_type(o->fs, o->encrypted, &mt, gt);
  if (kind == FL_PT_GPT) memcpy(p->gpt_type, gt, 16);
  else p->mbr_type = mt;
}

int fl_part_create(fl_bdev *disk, uint64_t first_lba, uint64_t count, const fl_fmt_opts *o,
                   const void *pass, size_t passlen, fl_progress_fn cb, void *arg, uint32_t *index_out) {
  if (!disk || !o || !index_out || disk->sector_size < 512 || disk->sector_size > MIB) return FL_EINVAL;
  uint64_t m = MIB / disk->sector_size;
  if (count == 0 || first_lba % m != 0 || count % m != 0) return FL_EINVAL;
  fl_pt_layout *l = NULL;
  int rc = load_editable(disk, &l);
  if (rc != FL_OK) return rc;
  uint32_t idx = free_index(l);
  if (idx == 0) rc = FL_EINVAL;
  if (rc == FL_OK) {
    fl_pt_entry *p = &l->e[l->count++];
    memset(p, 0, sizeof *p);
    p->index = idx;
    p->first_lba = first_lba;
    p->sector_count = count;
    set_type(p, l->kind, o);
    rc = fl_pt_validate(l);
  }
  if (rc == FL_OK) rc = fl_fmt_check(disk, o, pass, passlen, count);
  if (rc == FL_OK) {
    if (cb) cb(0, arg);
    rc = fl_pt_store(disk, l);
  }
  if (rc == FL_OK) rc = fl_fmt_slice(disk, first_lba, count, o, true, first_lba, pass, passlen, cb, arg);
  free(l);
  if (rc == FL_OK) {
    *index_out = idx;
    if (cb) cb(100, arg);
  }
  return rc;
}

int fl_part_delete(fl_bdev *disk, uint32_t index, uint64_t expect_first_lba) {
  if (!disk) return FL_EINVAL;
  fl_pt_layout *l = NULL;
  int rc = load_editable(disk, &l);
  if (rc != FL_OK) return rc;
  int i = find(l, index, expect_first_lba);
  if (i < 0) {
    rc = FL_ECHANGED;
  } else {
    memmove(&l->e[i], &l->e[i + 1], (l->count - (uint32_t)i - 1) * sizeof l->e[0]);
    l->count--;
    rc = fl_pt_store(disk, l);
  }
  free(l);
  return rc;
}

int fl_part_format(fl_bdev *disk, uint32_t index, uint64_t expect_first_lba, const fl_fmt_opts *o,
                   const void *pass, size_t passlen, fl_progress_fn cb, void *arg) {
  if (!disk || !o) return FL_EINVAL;
  fl_pt_layout *l = NULL;
  int rc = load_editable(disk, &l);
  if (rc != FL_OK) return rc;
  int i = find(l, index, expect_first_lba);
  if (i < 0) rc = FL_ECHANGED;
  fl_pt_entry before;
  if (rc == FL_OK) {
    before = l->e[i];
    rc = fl_fmt_check(disk, o, pass, passlen, l->e[i].sector_count);
  }
  if (rc == FL_OK) {
    if (cb) cb(0, arg);
    set_type(&l->e[i], l->kind, o);
    if (memcmp(&before, &l->e[i], sizeof before) != 0) rc = fl_pt_store(disk, l);
  }
  if (rc == FL_OK)
    rc = fl_fmt_slice(disk, l->e[i].first_lba, l->e[i].sector_count, o, true, l->e[i].first_lba, pass, passlen, cb,
                      arg);
  if (rc == FL_OK && cb) cb(100, arg);
  free(l);
  return rc;
}

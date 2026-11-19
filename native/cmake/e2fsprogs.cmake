# --- e2fsprogs 1.47.3 (phase 18) ------------------------------------------------------------------
# Copie d'amont non modifiée dans third_party/e2fsprogs (sous-ensemble : lib/ext2fs, lib/et, lib/e2p,
# lib/support, lib/uuid, e2fsck, resize ; voir third_party/PATCHES.md). Pas de « configure » : notre
# configuration et les fichiers que l'amont génère sont dans cmake/e2fsprogs/ (config.h écrit à la main
# d'après util/android_config.h ; tables d'erreurs par lib/et/et_[ch].awk, crc32c_table.h par
# gen_crc32ctable, types par util/android_types.h, comme util/gen-android-files d'amont).
#
# Aucun correctif : e2fsck et resize2fs sont appelés comme bibliothèque par src/partops/e2fs.c grâce à
# cmake/e2fsprogs/fl_e2fs_glue.h, inclus de force dans chaque fichier d'e2fsprogs :
#   - exit() devient fl_e2fs_exit() (retour par longjmp vers l'appelant, jamais de fin du processus) ;
#   - stdout, stderr, printf, vprintf, puts et putchar écrivent dans le rapport de l'appel en cours ;
#   - unix_io_manager devient fl_e2fs_io_manager (accès au disque du moteur, src/fs/e2fs_io.c) ;
#   - ext2fs_get_device_size2 devient fl_e2fs_get_device_size2 dans e2fsck et resize2fs ;
#   - ext2fs_open2, ext2fs_close_free et ext2fs_free deviennent fl_e2fs_… dans e2fsck (suivi des
#     systèmes de fichiers ouverts, libérés si exit() est appelé) ;
#   - init_resource_track et print_resource_track de resize2fs deviennent fl_rsz_… (doublons d'e2fsck) ;
#   - le main d'e2fsck (unix.c) devient fl_e2fsck_main, et son check_plausibility (qui cherche un fichier
#     du nom du volume) fl_e2fs_check_plausibility ; sigcatcher.c n'est pas compilé (aucun
#     gestionnaire de SIGSEGV posé dans le processus de l'application).
set(E2FS_DIR ${TP}/e2fsprogs)
set(E2FS_GEN ${CMAKE_CURRENT_LIST_DIR}/e2fsprogs)

set(_e2_ext2fs alloc alloc_sb alloc_stats alloc_tables atexit badblocks bb_inode bitmaps bitops blkmap64_ba
  blkmap64_rb blknum block bmap check_desc crc16 crc32c csum closefs dblist dblist_dir digest_encode dirblock
  dirhash dir_iterate dupfs expanddir ext_attr extent fallocate fileio finddev flushb freefs gen_bitmap
  gen_bitmap64 get_num_dirs get_pathname getsize getsectsize hashmap i_block icount imager ind_block initialize
  getenv inline inline_data inode io_manager ismounted link llseek lookup mmp mkdir mkjournal namei native newdir
   nls_utf8 openfs orphan progress punch qcow2 rbtree read_bb read_bb_file res_gdt rw_bitmaps sha256 sha512 swapfs
  symlink undo_io unlink valid_blk version)
set(_e2_support devname dict mkquota parse_qtype plausible profile profile_helpers quotaio quotaio_tree
  quotaio_v2 cstring)
set(_e2_e2p encoding errcode feature hashstr iod ljs ls mntopts parse_num pe pf ps uuid ostype percent)
set(_e2_et error_message et_name init_et com_err com_right)
set(_e2_uuid clear compare copy gen_uuid isnull pack parse unpack unparse uuid_time)
set(_e2_e2fsck unix e2fsck super pass1 pass1b pass2 pass3 pass4 pass5 journal badblocks util dirinfo
  dx_dirinfo ehandler problem message quota recovery region revoke ea_refcount rehash logfile readahead
  extents encrypted_files)
set(_e2_resize resize2fs extent resource_track)

set(E2FS_SOURCES ${E2FS_GEN}/ext2fs/ext2_err.c ${E2FS_GEN}/support/prof_err.c)
foreach(_lib ext2fs support e2p et uuid)
  foreach(f IN LISTS _e2_${_lib})
    list(APPEND E2FS_SOURCES ${E2FS_DIR}/lib/${_lib}/${f}.c)
  endforeach()
endforeach()
foreach(f IN LISTS _e2_e2fsck)
  list(APPEND E2FS_SOURCES ${E2FS_DIR}/e2fsck/${f}.c)
endforeach()
foreach(f IN LISTS _e2_resize)
  list(APPEND E2FS_SOURCES ${E2FS_DIR}/resize/${f}.c)
endforeach()

add_library(fl_e2fsprogs STATIC ${E2FS_SOURCES} ${E2FS_GEN}/fl_e2fs_glue.c ${E2FS_GEN}/fl_rsz_glue.c)
target_include_directories(fl_e2fsprogs SYSTEM PUBLIC ${E2FS_GEN} ${E2FS_DIR}/lib ${E2FS_DIR})
target_include_directories(fl_e2fsprogs PRIVATE ${E2FS_GEN}/ext2fs ${E2FS_GEN}/support ${E2FS_DIR}/lib/ext2fs
  ${E2FS_DIR}/lib/support ${E2FS_DIR}/e2fsck ${E2FS_DIR}/resize)
target_compile_definitions(fl_e2fsprogs PRIVATE HAVE_CONFIG_H _GNU_SOURCE _FILE_OFFSET_BITS=64
  unix_io_manager=fl_e2fs_io_manager)
target_compile_options(fl_e2fsprogs PRIVATE -w -include ${E2FS_GEN}/fl_e2fs_glue.h)
set(_e2_fsck_src)
foreach(f IN LISTS _e2_e2fsck)
  list(APPEND _e2_fsck_src ${E2FS_DIR}/e2fsck/${f}.c)
endforeach()
set(_e2_resize_src)
foreach(f IN LISTS _e2_resize)
  list(APPEND _e2_resize_src ${E2FS_DIR}/resize/${f}.c)
endforeach()
# e2fsck et resize2fs demandent la taille du volume par son nom : fl_e2fs_glue.c la donne. Les deux
# outils ont chacun leur init_resource_track et print_resource_track, de signatures différentes : ceux
# de resize2fs sont renommés.
# Dans e2fsck, chaque système de fichiers ouvert est suivi (fl_e2fs_glue.c) : un exit() au milieu
# libère aussi ceux que main garde dans ses variables locales.
set(_e2_fsck_defs ext2fs_get_device_size2=fl_e2fs_get_device_size2 ext2fs_open2=fl_e2fs_open2
  ext2fs_close_free=fl_e2fs_close_free ext2fs_free=fl_e2fs_free)
set_source_files_properties(${_e2_fsck_src} PROPERTIES COMPILE_DEFINITIONS "${_e2_fsck_defs}")
list(APPEND _e2_resize_src ${E2FS_GEN}/fl_rsz_glue.c)
set_source_files_properties(${_e2_resize_src} PROPERTIES COMPILE_DEFINITIONS
  "ext2fs_get_device_size2=fl_e2fs_get_device_size2;init_resource_track=fl_rsz_init_resource_track;print_resource_track=fl_rsz_print_resource_track")
# resize_fs oublie deux bitmaps sur son chemin d'erreur : fl_rsz_glue.h les libère (voir ce fichier).
set_source_files_properties(${E2FS_DIR}/resize/resize2fs.c PROPERTIES COMPILE_OPTIONS
  "-include;${E2FS_GEN}/fl_rsz_glue.h")
set_source_files_properties(${E2FS_DIR}/e2fsck/unix.c PROPERTIES COMPILE_DEFINITIONS
  "${_e2_fsck_defs};main=fl_e2fsck_main;check_plausibility=fl_e2fs_check_plausibility")
set_target_properties(fl_e2fsprogs PROPERTIES C_EXTENSIONS ON)
target_link_libraries(fl_e2fsprogs PUBLIC Threads::Threads)

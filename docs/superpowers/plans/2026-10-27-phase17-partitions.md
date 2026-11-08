# Portail — Phase 17 : gestion des partitions, comme GParted — Plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal :** Portail gère les partitions d'un disque USB à la manière de GParted : vue du disque à l'échelle (partitions,
espace libre, système de fichiers, étiquette, taille, place occupée), **créer** une partition dans un espace libre,
la **supprimer**, **formater une seule partition**, changer son **étiquette**, créer une **nouvelle table** MBR ou GPT,
**agrandir ou réduire** une partition et son système de fichiers (ext4 par `resize2fs`, NTFS par `ntfsresize`, aussi
dans un volume LUKS), et choisir la **taille** au formatage du disque. Les opérations sont préparées, résumées, puis
appliquées une à une après confirmation. Fin de phase : version **v1.10.0**.

**Architecture :**
- **Moteur natif (C11)** : `src/part/` gagne un modèle de table **modifiable** (`fl_pt_layout` : lecture complète,
  contrôle, écriture qui garde tout ce qu'elle ne change pas, nouvelle table, espaces libres) ; `src/partops/` les
  opérations (créer, supprimer, formater, étiquette, place occupée, vérification, redimensionnement), chacune
  revalidée avant d'écrire. **e2fsprogs** (libext2fs, `e2fsck`, `resize2fs`) et **`ntfsresize`/`ntfsfix`** de ntfs-3g
  sont compilés comme bibliothèques, sur l'accès au disque du moteur (`io_manager` d'e2fsprogs et `ntfs_device`
  existant de ntfs-3g), comme `mkntfs` depuis la phase 8.
- **Kotlin, paquet `com.mawena.fluluks.partitions`** : `PartitionManager` (vue du disque, application d'une suite
  d'opérations, une à la fois, refus si un volume du disque est ouvert, progression, messages en français), branché sur
  `VolumeManager` comme le formatage de la phase 8.
- **Flutter, dossier `lib/src/partitions/`** : `DiskPlan` (modèle pur : vue du disque, opérations en attente, aperçu
  et validation instantanés), écran du disque (barre à l'échelle, liste, actions), dialogues, résumé et application.
  L'écran de formatage de la phase 8 gagne la taille.

**Tech Stack :** C11, e2fsprogs **1.47.3** (sous-ensemble copié), ntfs-3g **2022.10.3** (déjà présent, `ntfsresize.c` et
`ntfsfix.c` ajoutés), FatFs R0.16 (`f_setlabel`, déjà activé), Kotlin, coroutines, Pigeon 27.3.0, Flutter 3.41, JUnit 4,
AndroidX Test ; juges du PC : `sfdisk`, `sgdisk`, `e2fsck`, `resize2fs`, `ntfsfix`, `ntfslabel`, `fatlabel`,
`exfatlabel`, `fsck.fat`, `fsck.exfat`, `blkid`, `cryptsetup`, montage par le noyau.

**Spec :** [docs/superpowers/specs/2026-10-17-fluluks-design.md](../specs/2026-10-17-fluluks-design.md), **§ 17**
(partitions), § 24 à § 26 (e2fsprogs et ntfs-3g apportés par cette phase, réutilisés par la réparation de la phase 18 ;
numérotation), § 14 (formatage de la phase 8), § 19 (interface et accessibilité), § 27 (barre de navigation).

## Global Constraints

- **Ordre :** les phases 15 et 16 sont fusionnées dans `develop` (2026-10-27) ; leurs essais sur le Pixel restent à
  faire et passent avant la publication des versions. Branche `feature/partitions` créée depuis `develop`, dans
  l'arbre principal `../Portail` (pas de second arbre : l'utilisateur a demandé de supprimer les dossiers inutiles).
- **Commits :** identité `mawena <gamligocharles@gmail.com>`, Conventional Commits en français, sans aucune
  attribution ni mention d'outil d'aide à l'écriture ; fichiers nommés (`git commit -- <fichiers>`, nouveaux fichiers
  ajoutés d'abord). Chaque tâche coche ses étapes ici et sa ligne dans la feuille de route, dans le commit
  `docs(feuille-de-route): phase 17, Tn faite sur feature/partitions` (ne nomme que la feuille de route et ce plan),
  reporté aussitôt sur `develop` avec le même texte.
- **Version :** `v1.10.0`, pubspec `1.10.0+18` (`1.8.0+16` et `1.9.0+17` pour les phases 15 et 16).
- **Dépendances :** e2fsprogs 1.47.3 (tarball signé de kernel.org, empreinte SHA-256 notée dans `PATCHES.md`) ; les
  fichiers de ntfs-3g 2022.10.3 manquants (`ntfsprogs/ntfsresize.c`, `ntfsprogs/ntfsfix.c`) tirés du même tarball que
  la copie existante. Aucune nouvelle bibliothèque Java, Kotlin ni Dart. Correctifs dans `native/third_party/patches/`,
  appliqués à la configuration comme ceux de lwext4 et de ntfs-3g (`native/cmake/third_party.cmake`).
- **Licences :** e2fsprogs (libext2fs LGPL 2, e2fsck et resize2fs GPL 2, libcom_err et libuuid de type BSD/MIT) ajouté
  à `lib/src/licenses.dart`, au README et à `PATCHES.md`.
- **Sûreté (spec § 17) :** jamais d'écriture sur un disque dont un volume est ouvert (coffre compris) ; jamais sur le
  stockage du téléphone ni une carte SD ; chaque opération revalide l'état réel du disque avant d'écrire (table
  relue, partition attendue au même début) ; le système de fichiers est vérifié en lecture seule (`e2fsck -fn`,
  `ntfsfix -n`) avant un redimensionnement ; le début d'une partition ne change jamais.
- **Architecture existante :** écritures par `fl_bdev` (cache et USB du moteur) ; poignées et refus de montage pendant
  une opération dans `native/jni/handles.c` (comme `fj_format`) ; Kotlin dans le dispatcher de `VolumeManager` ; Pigeon
  (`pigeons/fluluks_api.dart`, puis `dart run pigeon --input pigeons/fluluks_api.dart`) ; chaînes dans `Fr` ; jetons et
  composants du design system (`ui/tokens.dart`, `ui/widgets.dart`, `ui/sheets.dart`, `ui/dialogs.dart`) ; écrans au
  banc `test/screen_harness.dart`.
- **Langue :** toute chaîne visible en français, typographie vérifiée par `test/strings_test.dart` (U+00A0 avant « : »
  et dans les guillemets, U+202F avant « ? ! ; » et « % ») ; tailles par `Fr.humanSize`.
- **Valeurs fixées** *(décisions du planificateur, voir la fin du plan)* :
  - alignement **1 Mio** (début et taille des partitions créées ou redimensionnées), taille saisie au Mio près ;
  - GPT : **128** entrées de 128 octets ; MBR : **4** partitions principales, **2^32 − 1** secteurs au plus ;
  - types : GPT `0FC63DAF-8483-4772-8E79-3D69D8477DE4` (Linux : ext4, LUKS) et
    `EBD0A0A2-B9E5-4433-87C0-68B6B72699C7` (données Microsoft : FAT32, exFAT, NTFS) ; MBR `0x83`, `0x0C`, `0x07`,
    comme la phase 8 ;
  - taille minimale d'une partition créée : celle du système de fichiers (phase 8 : FAT32 ≈ 33 Mio en secteurs de
    512 octets, **8 Mio** pour exFAT, ext4 et NTFS), plus **16 Mio** d'en-tête LUKS2 si chiffrée ;
  - redimensionnement : au plus **la fin de l'espace libre qui suit** ; au moins le minimum rendu par le moteur
    (`calculate_minimum_resize_size` pour ext4, `ntfsresize --info` pour NTFS) arrondi au Mio supérieur, plus l'en-tête
    LUKS si chiffrée ;
  - e2fsck et ntfsresize : **un appel à la fois** (état global), sur un fil à pile de **8 Mio** ;
  - rapport de vérification montré : **20** premières lignes.
- **Téléphone :** jamais de `flutter drive` sans `--keep-app-running`, jamais `connectedAndroidTest` ; essais
  instrumentés par `adb install -r -t` (application et APK de test),
  `adb shell am instrument -w -r -e class com.mawena.fluluks.<Classe> com.mawena.fluluks.test/androidx.test.runner.AndroidJUnitRunner`,
  puis désinstallation de `com.mawena.fluluks.test` seulement. APK de l'utilisateur sauvegardée avant, rendue après.
  Essais sur des images dans `/data/local/tmp/fluluks/`, puis sur une clé USB sacrifiée, **jamais sur le vrai disque**.
- **Tests :** à la fin de chaque tâche, `flutter analyze`, `flutter test` et
  `cd android && ./gradlew -q --offline :app:testDebugUnitTest` sont verts ; une tâche qui touche `native/` lance aussi
  `cmake -S native -B build/native -G Ninja -DCMAKE_BUILD_TYPE=Debug -DFL_TESTS=ON -DFL_SANITIZE=ON`,
  `cmake --build build/native` et `ctest --test-dir build/native --output-on-failure -LE lent` (ASan/UBSan propres),
  et `flutter build apk --debug` (compilation Android du moteur). Les tests sur le téléphone
  (`tools/android/run_native_tests.sh <numéro-adb>`) sont regroupés en T11. Jamais `dart format` sur des dossiers
  entiers.

## Review Focus

1. **Coupure pendant une écriture** (disque débranché, erreur d'E/S au milieu) : la table n'est jamais à moitié écrite
   (GPT : secours d'abord, en-tête principal en dernier) ; un agrandissement coupé après la table garde les données ;
   une réduction n'écrit la table qu'après le système de fichiers. → T1 : `gptWriteCutLeavesOneValidCopy` ; T6 :
   `growCutAfterTableKeepsData`, `shrinkCutBeforeTableKeepsData`.
2. **Tables étrangères ou hostiles** (créées par Windows, sgdisk, un appareil photo) : GPT de secours absent ou pas en
   fin de disque (disque cloné plus grand), entrées de taille ou de nombre inhabituels, MBR hybride, partitions qui se
   chevauchent ou débordent, secteurs de 4 Kio. → T1 : `foreignGptEntriesPreserved`, `backupGptMovedToEnd`,
   `overlapRefused`, `hybridMbrRefused`, `sector4kLayout`.
3. **Le disque change entre la préparation et l'application** (volume ouvert entre-temps, table changée ailleurs,
   disque débranché puis rebranché). → T2 : `opRefusedWhenPartitionMoved` ; T7 : `applyRefusedWhenVolumeOpened`,
   `applyStopsAtFirstFailureAndRescans`.
4. **Tailles limites** : réduire sous la place occupée ou sous le minimum du système de fichiers, FAT32 au-delà de
   2 Tio, MBR au-delà de 2 Tio, cinquième partition principale, espace libre de moins d'un Mio. → T6 :
   `shrinkBelowMinimumRefused` ; T8 : `validateRejectsFifthPrimary`, `validateRejectsBeyondMbrLimit`,
   `tinyGapsNotOffered`.
5. **Perte de données par mégarde** : opération destructive sans confirmation forte, suppression d'une partition
   d'un volume ouvert, réduction d'un ext4 qui n'a pas été vérifié. → T6 : `resizeRefusedWhenCheckFails` ; T9 :
   `destructiveBatchNeedsDiskName`, `openVolumeHasNoActions`.

---

### Task 1 : table de partitions modifiable (moteur)

**Files :**
- Create : `native/include/fluluks/partedit.h`, `native/src/part/layout.c`, `native/src/part/layout_write.c`,
  `native/tests/test_part_layout.c`
- Modify : `native/src/format/part_write.c` (GUID aléatoire, effacement et écriture GPT/MBR partagés avec
  `layout_write.c` par `native/src/part/part_internal.h`), `native/CMakeLists.txt`, `native/include/fluluks/error.h`
- Test : `native/tests/test_part_layout.c` (juges `sfdisk --json`, `sgdisk -v`, `sgdisk -p` par `fu_run`)

**Interfaces :**
- Produces :
  ```c
  typedef struct {
    uint32_t index;             /* GPT : 1..128 (position dans le tableau) ; MBR : 1..4, logiques 5.. */
    uint64_t first_lba, sector_count;
    uint8_t  mbr_type;          /* 0 en GPT */
    uint8_t  gpt_type[16], gpt_guid[16];
    uint64_t gpt_attrs;
    char     name[73];          /* nom GPT, UTF-8 */
    bool     logical;           /* MBR : dans une partition étendue */
  } fl_pt_entry;
  typedef struct {
    fl_pt_kind kind;            /* NONE : aucune table (disque vierge ou système de fichiers sans table) */
    uint32_t sector_size; uint64_t sector_count;
    uint64_t first_usable, last_usable;  /* GPT : bornes de l'en-tête ; MBR : 1 Mio et fin du disque (2^32-1) */
    uint8_t  disk_guid[16]; uint32_t mbr_signature;
    bool     has_extended;      /* MBR avec partition étendue : seule l'étiquette se change */
    uint32_t count; fl_pt_entry e[128];
  } fl_pt_layout;
  typedef struct { uint64_t first_lba, sector_count; } fl_pt_region;

  int fl_pt_load(fl_bdev *d, fl_pt_layout *out);           /* GPT valide (principal ou secours), MBR, NONE */
  int fl_pt_validate(const fl_pt_layout *l);               /* FL_OK ou FL_EINVAL : chevauchement, hors bornes,
                                                              MBR > 4 principales ou > 2^32-1, index en double */
  int fl_pt_store(fl_bdev *d, const fl_pt_layout *l);      /* écrit la table ; garde code d'amorçage, signature,
                                                              GUID, attributs, noms, entrées inconnues */
  int fl_pt_new_table(fl_bdev *d, fl_pt_kind kind);        /* efface le premier et le dernier Mio, table vide */
  uint32_t fl_pt_free(const fl_pt_layout *l, fl_pt_region *out, uint32_t cap); /* espaces libres alignés ≥ 1 Mio */
  #define FL_ECHANGED (-19) /* la table ne correspond plus à ce qui a été préparé */
  ```
  `fl_part_scan` (phase 1) reste tel quel pour le montage.

- [ ] **Step 1 : tests en échec** (`test_part_layout.c`, images creuses de 64 Mio, 3 Gio et 8 Gio, secteurs de 512 et
  4096 octets, tables créées par `sfdisk` et `sgdisk`) : `loadMatchesSfdisk` (début, taille, type de chaque partition
  égaux à `sfdisk --json`) ; `storeRoundTripUnchanged` (charger puis écrire sans changement : les 34 premiers et 33
  derniers secteurs identiques octet pour octet, GPT ; secteur 0 identique, MBR) ; `foreignGptEntriesPreserved`
  (attributs, noms, GUID d'une table sgdisk gardés après ajout d'une partition ; `sgdisk -v` : « No problems found ») ;
  `backupGptMovedToEnd` (image agrandie de 1 Gio après sgdisk : après `fl_pt_store`, `sgdisk -v` propre et
  `last_usable` au bout du disque) ; `overlapRefused`, `beyondDiskRefused`, `fifthPrimaryRefused`,
  `mbrBeyond2TiBRefused` (FL_EINVAL, rien écrit) ; `hybridMbrRefused` (MBR protecteur avec une seconde entrée :
  FL_ENOTSUP au chargement) ; `extendedFlagged` (MBR avec étendue et deux logiques : `has_extended`, logiques
  `logical`, index 5 et 6) ; `newTableGptAndMbr` (`sgdisk -v` propre, `sfdisk --json` sans partition, anciennes
  signatures effacées) ; `freeRegionsAligned` (trois trous dont un de 512 Kio : deux régions alignées sur 1 Mio) ;
  `sector4kLayout` ; `gptWriteCutLeavesOneValidCopy` (`fault_bdev` qui échoue à chaque écriture possible, l'une après
  l'autre : `fl_pt_load` relit toujours l'ancienne table ou la nouvelle, jamais une erreur).
- [ ] **Step 2 :** `cmake --build build/native && ctest --test-dir build/native -R test_part_layout` : échec
  (`partedit.h` absent).
- [ ] **Step 3 : implémentation.** Ordre d'écriture GPT : entrées de secours, en-tête de secours, entrées principales,
  MBR protecteur, en-tête principal en dernier, puis `fl_bdev_flush`. Entrées non comprises (nombre ≠ 128, taille ≠ 128)
  : FL_ENOTSUP au chargement (« table non modifiable ici »). Le code de `part_write.c` qui écrit un GPT ou un MBR à une
  partition passe par `fl_pt_store` (les tests de la phase 8 restent verts).
- [ ] **Step 4 :** tests du moteur verts, ASan/UBSan propres ; `flutter build apk --debug` compile.
- [ ] **Step 5 : commit** `feat(partitions): table de partitions modifiable dans le moteur`.

### Task 2 : créer, supprimer, formater une partition ; taille au formatage ; place occupée (moteur)

**Files :**
- Create : `native/include/fluluks/partops.h`, `native/src/partops/create.c`, `native/src/partops/usage.c`,
  `native/tests/test_partops.c`, `tools/fixtures/verify_partitions_with_kernel.sh`
- Modify : `native/src/format/format.c` (`fl_fmt_opts.part_bytes`, formatage d'une tranche partagé), 
  `native/include/fluluks/format.h`, `native/CMakeLists.txt`
- Test : `native/tests/test_partops.c`, `native/tests/test_format.c` (cas ajouté)

**Interfaces :**
- Consumes : `fl_pt_load`, `fl_pt_store`, `fl_pt_validate`, `fl_pt_free` (T1) ; `fl_luks2_format`, `fl_mkfs_*` (phase 8).
- Produces :
  ```c
  /* fl_fmt_opts gagne : uint64_t part_bytes;  0 = tout le disque (phase 8), sinon taille de la partition unique,
     arrondie au Mio inférieur, le reste du disque laissé libre. */
  typedef void (*fl_progress_fn)(int pct, void *arg);
  int fl_part_create(fl_bdev *disk, uint64_t first_lba, uint64_t count, const fl_fmt_opts *o,
                     const void *pass, size_t passlen, fl_progress_fn cb, void *arg, uint32_t *index_out);
  int fl_part_delete(fl_bdev *disk, uint32_t index, uint64_t expect_first_lba);
  int fl_part_format(fl_bdev *disk, uint32_t index, uint64_t expect_first_lba, const fl_fmt_opts *o,
                     const void *pass, size_t passlen, fl_progress_fn cb, void *arg);
  typedef struct { fl_content content; char label[64]; bool known; uint64_t used_bytes, total_bytes; } fl_part_usage;
  int fl_part_usage_of(fl_bdev *disk, uint32_t index, fl_part_usage *out); /* montage en lecture seule, statfs */
  ```
  Toute opération sur une partition existante recharge la table et rend FL_ECHANGED si `index` n'a plus
  `expect_first_lba`. Une partition étendue ou logique : FL_ENOTSUP pour créer, supprimer et formater.

- [ ] **Step 1 : tests en échec** (`test_partops.c`) : `createInFreeSpaceJudged` (pour FAT32, exFAT, ext4, NTFS et ext4
  chiffré : partition créée dans le trou entre deux partitions existantes ; `sfdisk --json` montre trois partitions,
  les deux voisines inchangées octet pour octet ; `fsck.fat -n`, `fsck.exfat -n`, `e2fsck -fn`, `ntfsfix -n`,
  `cryptsetup luksDump` propres sur la tranche extraite) ; `createTypeMatchesFs` (MBR `0x0C`/`0x07`/`0x83`, GPT
  Microsoft ou Linux) ; `createTooSmallRefused` (FL_ENOSPC, rien écrit) ; `deleteKeepsOthers` (voisines identiques
  octet pour octet, données de la partition supprimée non effacées) ; `formatOnePartitionOnly` (les autres
  identiques ; type mis à jour) ; `opRefusedWhenPartitionMoved` (FL_ECHANGED) ; `logicalRefused` (FL_ENOTSUP) ;
  `usageMatchesStatfs` (place occupée d'un ext4, d'un FAT32 et d'un NTFS remplis de 3 Mio de fichiers : égale à
  `df` du volume monté par le moteur ; LUKS verrouillé : `known` faux).
  `test_format.c` : `formatWithSizeLeavesRestFree` (`part_bytes` = 100 Mio sur 1 Gio : une partition de 100 Mio au
  Mio près, le reste libre selon `sfdisk`).
- [ ] **Step 2 :** `ctest -R 'test_partops|test_format$'` : échec.
- [ ] **Step 3 : implémentation.** Une seule fonction de formatage de tranche dans `format.c` (effacement du premier
  et du dernier Mio de la tranche, LUKS2 éventuel, système de fichiers) sert `fl_format`, `fl_part_create` et
  `fl_part_format`. `fl_part_create` écrit la table **avant** le système de fichiers (un échec laisse une partition
  vide, signalée par le rapport). `tools/fixtures/verify_partitions_with_kernel.sh <image>` : `losetup -P`, montage de
  chaque partition par le noyau (`cryptsetup open` pour LUKS, phrase en argument), écriture et relecture d'un fichier,
  démontage, `fsck` propre.
- [ ] **Step 4 :** tests du moteur verts ; `sudo tools/fixtures/verify_partitions_with_kernel.sh` sur les images
  gardées (`FL_KEEP=1`) : tout monté et propre.
- [ ] **Step 5 : commit** `feat(partitions): créer, supprimer et formater une partition, taille au formatage`.

### Task 3 : e2fsprogs dans le moteur (libext2fs, e2fsck en lecture seule, resize2fs)

**Files :**
- Create : `native/third_party/e2fsprogs/` (sous-ensemble de 1.47.3 : `lib/ext2fs`, `lib/et`, `lib/e2p`,
  `lib/support`, `lib/uuid`, `e2fsck`, `resize`, `COPYING`, `NOTICE`), `native/cmake/e2fsprogs/config.h`,
  `native/cmake/e2fsprogs.cmake`, `native/third_party/patches/e2fsprogs/0001-bibliotheque.patch`,
  `native/src/fs/e2fs_io.c` (io_manager sur `fl_bdev`), `native/src/partops/e2fs.c`, `native/tests/test_e2fs.c`
- Modify : `native/CMakeLists.txt`, `native/cmake/third_party.cmake`, `native/third_party/PATCHES.md`
- Test : `native/tests/test_e2fs.c`

**Interfaces :**
- Produces :
  ```c
  typedef struct { bool clean; int exit_code; char report[4096]; } fl_check_report;
  int fl_e2fs_check(fl_bdev *vol, fl_check_report *out);                    /* e2fsck -fn */
  int fl_e2fs_min_size(fl_bdev *vol, uint64_t *bytes);                      /* resize2fs -P */
  int fl_e2fs_resize(fl_bdev *vol, uint64_t new_bytes, fl_progress_fn cb, void *arg);
  int fl_e2fs_set_label(fl_bdev *vol, const char *label);                   /* 16 octets UTF-8 au plus */
  ```
  `vol` est la partition ou le volume LUKS déchiffré ; aucune de ces fonctions ne garde `vol` après son retour.

- [ ] **Step 1 : tests en échec** (`test_e2fs.c`, images faites par `mke2fs -t ext4` du PC, avec `metadata_csum`,
  `64bit`, `flex_bg` ; une image cassée par `debugfs -w -R "clri <12>"`) : `checkCleanImage` (`clean`, code 0) ;
  `checkReportsCorruption` (pas `clean`, rapport non vide, image inchangée : SHA-256 égal avant et après) ;
  `minSizeMatchesResize2fsP` (égal à `resize2fs -P` du PC, au bloc près) ; `growThenJudged` et `shrinkThenJudged`
  (image de 256 Mio remplie de 120 Mio de fichiers, portée à 512 puis 160 Mio : `e2fsck -fn` du PC propre, fichiers
  identiques par `debugfs -R "dump"` et SHA-256) ; `labelSetJudged` (`blkid -s LABEL` rend l'étiquette, `e2fsck -fn`
  propre) ; `exitNeverKillsProcess` (image dont le superbloc est détruit : FL_ECORRUPT rendu, le test continue) ;
  `twoCallsSequential` (deux vérifications de suite dans le même processus, ASan propre).
- [ ] **Step 2 :** `ctest -R test_e2fs` : échec.
- [ ] **Step 3 : implémentation.** Correctif `0001-bibliotheque.patch` : `main` d'e2fsck renommé et appelé avec
  `argv = {"e2fsck", "-fn", "fl"}` ; `exit` et `fatal_error` remplacés par un retour par `longjmp` vers
  `fl_e2fs_check` ; état global remis à zéro à chaque appel ; `unix_io_manager` remplacé par `fl_e2fs_io_manager`
  (nom de périphérique « fl » associé à `vol`). `resize2fs` appelé par `resize_fs()` et
  `calculate_minimum_resize_size()`, sans son `main`. Un mutex sérialise tous les appels ; chacun tourne sur un fil à
  pile de 8 Mio. `config.h` écrit à la main pour Linux et Android (pas de `configure`). Licences recopiées dans
  `PATCHES.md`.
- [ ] **Step 4 :** tests du moteur verts, ASan/UBSan propres ; `flutter build apk --debug` compile (arm64 et armv7).
- [ ] **Step 5 : commit** `feat(partitions): e2fsprogs dans le moteur, vérification et redimensionnement d'ext4`.

### Task 4 : ntfsresize et ntfsfix -n dans le moteur

**Files :**
- Create : `native/third_party/ntfs-3g/ntfsprogs/ntfsresize.c`, `native/third_party/ntfs-3g/ntfsprogs/ntfsfix.c`,
  `native/third_party/patches/ntfs-3g/0008-ntfsresize-ntfsfix-bibliotheque.patch`, `native/src/partops/ntfs.c`,
  `native/tests/test_ntfsresize.c`
- Modify : `native/cmake/ntfs-3g/` (cibles `fl_ntfsresize`, `fl_ntfsfix`), `native/CMakeLists.txt`,
  `native/third_party/PATCHES.md`

**Interfaces :**
- Consumes : `ntfs_dev.c` (périphérique ntfs-3g sur `fl_bdev`, phase 5), `fl_check_report` (T3).
- Produces :
  ```c
  int fl_ntfs_check(fl_bdev *vol, fl_check_report *out);          /* ntfsfix -n */
  int fl_ntfs_min_size(fl_bdev *vol, uint64_t *bytes);            /* ntfsresize --info */
  int fl_ntfs_resize(fl_bdev *vol, uint64_t new_bytes, fl_progress_fn cb, void *arg);
  int fl_ntfs_set_label(fl_bdev *vol, const char *label);         /* ntfs_volume_rename, 32 caractères */
  ```

- [ ] **Step 1 : tests en échec** (`test_ntfsresize.c`, images faites par `mkntfs -Q` du PC puis remplies par
  `ntfs-remplir`) : `checkClean`, `checkDirtyVolumeReported` (volume marqué sale : pas `clean`, image inchangée) ;
  `minSizeMatchesNtfsresizeInfo` (égal à `ntfsresize --info --force` du PC à 1 Mio près) ; `growThenJudged`,
  `shrinkThenJudged` (`ntfsfix -n` du PC propre, fichiers identiques par `ntfsjuge.py`) ; `labelSetJudged`
  (`ntfslabel` du PC la relit) ; `exitNeverKillsProcess` ; `resizeSetsChkdskFlagLikeUpstream` (comme `ntfsresize`,
  le volume est marqué à vérifier par Windows : comportement documenté, pas une erreur).
- [ ] **Step 2 :** `ctest -R test_ntfsresize` : échec.
- [ ] **Step 3 : implémentation** sur le modèle du correctif `0007-mkntfs-bibliotheque.patch` : `main` remplacé par des
  fonctions qui prennent le périphérique de l'appelant, `err_exit` et `exit` par un retour, globales remises à zéro,
  messages recueillis dans `report` au lieu de `stdout`. Mutex et fil à grande pile partagés avec T3.
- [ ] **Step 4 :** tests du moteur verts ; `flutter build apk --debug` compile.
- [ ] **Step 5 : commit** `feat(partitions): ntfsresize et ntfsfix dans le moteur`.

### Task 5 : étiquette d'une partition (moteur)

**Files :**
- Create : `native/src/partops/label.c`, `native/tests/test_part_label.c`
- Modify : `native/include/fluluks/partops.h`, `native/src/fs/fat_glue.c` (accès à `f_setlabel` sur une tranche)

**Interfaces :**
- Consumes : `fl_e2fs_set_label` (T3), `fl_ntfs_set_label` (T4), `fl_fmt_check_label` (phase 8).
- Produces : `int fl_part_set_label(fl_bdev *disk, uint32_t index, uint64_t expect_first_lba, const char *label, const void *pass, size_t passlen);`
  (chiffrée : étiquette du système de fichiers intérieur, phrase exigée, FL_EBADPASS sinon ; logique MBR permise).

- [ ] **Step 1 : tests en échec** : `fat32LabelBothPlaces` (`fatlabel` du PC et le champ du secteur de démarrage et de
  sa copie, secteur 6, rendent l'étiquette en majuscules ; `fsck.fat -n` propre) ; `exfatLabelJudged` (`exfatlabel`,
  `fsck.exfat -n`) ; `ext4LabelJudged` ; `ntfsLabelJudged` ; `encryptedLabelInside` (`blkid` du volume ouvert par
  `cryptsetup` du PC) ; `invalidLabelRefusedBeforeWrite` (FL_EINVAL, image inchangée) ; `wrongPassRefused`
  (FL_EBADPASS, image inchangée).
- [ ] **Step 2 :** `ctest -R test_part_label` : échec.
- [ ] **Step 3 : implémentation** : FAT32 et exFAT par `f_setlabel` de FatFs, puis, en FAT32, `BS_VolLab` du secteur
  de démarrage et de sa copie (comme `fatlabel`) ; ext4 et NTFS par T3 et T4.
- [ ] **Step 4 :** tests du moteur verts.
- [ ] **Step 5 : commit** `feat(partitions): changer l'étiquette d'une partition`.

### Task 6 : redimensionner une partition et son système de fichiers (moteur)

**Files :**
- Create : `native/src/partops/resize.c`, `native/tests/test_part_resize.c`
- Modify : `native/include/fluluks/partops.h`, `native/src/luks/luks2_slots.c` (taille d'un segment fixe réécrite)

**Interfaces :**
- Consumes : T1, T3, T4 ; `fl_luks_open` et `write_hdrs` (LUKS).
- Produces :
  ```c
  typedef struct { fl_content content; bool resizable; const char *why; /* raison en français si non */
                   uint64_t min_bytes, max_bytes; fl_check_report check; } fl_resize_info;
  int fl_part_resize_info(fl_bdev *disk, uint32_t index, uint64_t expect_first_lba,
                          const void *pass, size_t passlen, fl_resize_info *out);
  int fl_part_resize(fl_bdev *disk, uint32_t index, uint64_t expect_first_lba, uint64_t new_count,
                     const void *pass, size_t passlen, fl_progress_fn cb, void *arg);
  ```
  `fl_part_resize` refait la vérification (`check.clean` exigé, sinon FL_ECORRUPT) et la borne
  `min_bytes..max_bytes`, puis : **agrandir** = table, puis LUKS (segment fixe), puis système de fichiers ; **réduire**
  = système de fichiers, puis LUKS, puis table. FAT12/16/32 et exFAT : `resizable` faux, `why` = « FAT32 et exFAT ne
  se redimensionnent pas ici : copiez les fichiers ailleurs, puis recréez la partition ».

- [ ] **Step 1 : tests en échec** (`test_part_resize.c`) : `growExt4`, `shrinkExt4`, `growNtfs`, `shrinkNtfs`,
  `growLuks2Ext4`, `shrinkLuks2Ext4`, `growLuks1Ext4`, `resizeLuks2FixedSegment` (fichiers identiques par SHA-256,
  `sfdisk --json` montre la nouvelle taille, juges du PC propres, `cryptsetup luksDump` : taille du segment juste) ;
  `shrinkBelowMinimumRefused` et `growBeyondFreeRefused` (FL_EINVAL, image inchangée) ; `fatNotResizable` ;
  `resizeRefusedWhenCheckFails` (ext4 cassé : FL_ECORRUPT, image inchangée) ; `growCutAfterTableKeepsData` et
  `shrinkCutBeforeTableKeepsData` (`fault_bdev` coupé entre les étapes : la partition se monte et les fichiers sont
  intacts) ; `startNeverMoves` (début identique après chaque cas).
- [ ] **Step 2 :** `ctest -R test_part_resize` : échec.
- [ ] **Step 3 : implémentation** selon l'ordre ci-dessus ; un segment LUKS2 « dynamic » et LUKS1 suivent la partition
  sans écriture d'en-tête.
- [ ] **Step 4 :** tests du moteur verts ; `sudo tools/fixtures/verify_partitions_with_kernel.sh` sur les images
  redimensionnées gardées : montées par le noyau, propres.
- [ ] **Step 5 : commit** `feat(partitions): agrandir et réduire ext4 et NTFS, aussi dans LUKS`.

### Task 7 : JNI et Kotlin (`PartitionManager`)

**Files :**
- Create : `android/app/src/main/kotlin/com/mawena/fluluks/partitions/PartitionManager.kt`,
  `android/app/src/main/kotlin/com/mawena/fluluks/partitions/PartOps.kt`,
  `android/app/src/test/kotlin/com/mawena/fluluks/partitions/PartitionManagerTest.kt`
- Modify : `native/jni/fluluks_jni.c`, `native/jni/handles.c` (montage refusé pendant une opération, comme
  `fj_format`), `native/jni/json_out.c`, `engine/Engine.kt`, `engine/NativeEngine.kt`,
  `volumes/VolumeManager.kt` (taille au formatage ; accès aux volumes ouverts d'un disque), `bridge/HostApiImpl.kt`,
  `pigeons/fluluks_api.dart` et fichiers générés

**Interfaces :**
- Consumes : T1 à T6 par JNI : `partLayout(disk): ByteArray` (JSON de `fl_pt_layout`, espaces libres et
  `fl_part_usage` de chaque partition), `partApply(disk, op: ByteArray, pass: ByteArray?, progress): Int`,
  `partResizeInfo(disk, index, firstLba, pass): ByteArray`.
- Produces (Pigeon) :
  ```dart
  class LayoutPartMsg { int index; int firstLba; int sectorCount; String content; String label; bool encrypted;
    bool logical; int? usedBytes; String? volumeId; }
  class DiskLayoutMsg { String diskId; String table; /* none, mbr, gpt */ int sectorSize; int sectorCount;
    int firstUsable; int lastUsable; bool hasExtended; List<LayoutPartMsg> parts; }
  class PartOpMsg { String kind; /* create, delete, format, label, resize, newTable */ int? index; int? firstLba;
    int? sectorCount; String? fs; bool encrypted; String? label; String? table; Uint8List? passphrase; }
  class ResizeInfoMsg { bool resizable; String? why; int minBytes; int maxBytes; bool clean; String report; }
  class PartProgressMsg { int step; int steps; int pct; String? error; bool done; }
  // HostApi
  @async DiskLayoutMsg diskLayout(String diskId);
  @async ResizeInfoMsg resizeInfo(String diskId, int index, int firstLba, Uint8List? passphrase);
  void applyPartitionOps(String diskId, List<PartOpMsg> ops);
  // FlutterApi
  void onPartitionProgress(PartProgressMsg? p);
  // formatDisk gagne : int? sizeBytes
  ```
  Messages d'erreur en français dans `PartitionManager` (`MSG_PART_OPEN`, `MSG_PART_CHANGED`, `MSG_PART_DETACHED`,
  `MSG_PART_CHECK`, `MSG_PART_TOO_SMALL`, `MSG_PART_BADPASS`).

- [ ] **Step 1 : tests en échec** (`PartitionManagerTest`, faux moteur) : `layoutParsed` ; `applyRefusedWhenVolumeOpened`
  (aucun appel natif) ; `applyRunsOpsInOrderWithProgress` ; `applyStopsAtFirstFailureAndRescans` (troisième opération
  en échec : la quatrième n'est pas appelée, le disque est relu, `error` en français) ; `changedTableMessage`
  (FL_ECHANGED → `MSG_PART_CHANGED`) ; `passphrasesZeroedOnAllPaths` ; `mountRefusedWhileApplying` ;
  `formatWithSizePassesPartBytes`.
- [ ] **Step 2 :** `./gradlew -q --offline :app:testDebugUnitTest --tests '*PartitionManagerTest'` : échec.
- [ ] **Step 3 : implémentation** ; Pigeon régénéré ; `HostApiImpl` relie l'API.
- [ ] **Step 4 :** tests JVM, Flutter et moteur verts ; `flutter build apk --debug`.
- [ ] **Step 5 : commit** `feat(partitions): gestionnaire des partitions et pont Pigeon`.

### Task 8 : modèle des opérations en attente (Dart)

**Files :**
- Create : `lib/src/partitions/disk_plan.dart`, `test/disk_plan_test.dart`

**Interfaces :**
- Consumes : `DiskLayoutMsg`, `PartOpMsg` (T7).
- Produces :
  ```dart
  sealed class PendingOp { String describe(); bool get destructive; PartOpMsg toMsg(); }
  // CreateOp(firstLba, sectorCount, fs, encrypted, label), DeleteOp(index, firstLba), FormatOp(index, firstLba, fs,
  // encrypted, label), LabelOp(index, firstLba, label), ResizeOp(index, firstLba, newSectorCount), NewTableOp(table)
  class Slot { /* partition ou espace libre dans l'aperçu */ int firstLba; int sectorCount; LayoutPartMsg? part;
    PendingOp? changedBy; bool get isFree; }
  class DiskPlan {
    DiskPlan(DiskLayoutMsg layout);
    List<PendingOp> get pending;
    List<Slot> get preview;              // trié par début, espaces libres ≥ 1 Mio compris
    String? validate(PendingOp op);      // null si permis, sinon raison en français (Fr)
    void add(PendingOp op);              // validate == null exigé
    void undoLast(); void clear();
    bool get destructive;                // une opération supprime, formate, réduit ou crée une table
  }
  ```

- [ ] **Step 1 : tests en échec** (`disk_plan_test.dart`) : `previewShowsFreeGaps` ; `createFillsGap` ;
  `deleteMergesNeighbourGaps` ; `resizeShrinksAndOpensGap` ; `newTableClearsEverything` ;
  `validateRejectsFifthPrimary` ; `validateRejectsBeyondMbrLimit` ; `validateRejectsFat32Over2TiB` ;
  `validateRejectsOpsOnOpenVolume` ; `validateRejectsLogicalExceptLabel` ; `tinyGapsNotOffered` ;
  `opsOnCreatedPartitionRefused` (pas d'opération sur une partition encore en attente, sauf l'annuler) ;
  `undoRestoresPreview` ; `destructiveFlag` ; `alignedToMiB`.
- [ ] **Step 2 :** `flutter test test/disk_plan_test.dart` : échec.
- [ ] **Step 3 : implémentation** (pur, sans widget).
- [ ] **Step 4 :** `flutter analyze && flutter test` verts.
- [ ] **Step 5 : commit** `feat(partitions): opérations en attente et aperçu du disque`.

### Task 9 : écran du disque, dialogues, résumé et application (Flutter)

**Files :**
- Create : `lib/src/partitions/partitions_screen.dart`, `lib/src/partitions/partition_bar.dart`,
  `lib/src/partitions/partition_dialogs.dart`, `lib/src/partitions/apply_screen.dart`, `test/partitions_screen_test.dart`
- Modify : `lib/src/widgets/disk_card.dart` (menu : **Gérer les partitions…**), `lib/src/screens/format_screen.dart`
  (taille : « Tout le disque » ou au choix, en Mio/Gio), `lib/src/state/app_state.dart`, `lib/src/strings_fr.dart`,
  `test/screen_harness.dart`, `test/accessibility_test.dart`, `test/goldens_test.dart`

**Interfaces :**
- Consumes : `DiskPlan` (T8), API de T7.

- [ ] **Step 1 : tests en échec** (`partitions_screen_test.dart`) : `barToScale` (largeurs proportionnelles, une
  partition minuscule garde 8 dp) ; `rowShowsFsLabelSizeUsed` ; `freeSpaceOffersCreate` ;
  `partitionSheetActions` (Formater…, Redimensionner…, Changer l'étiquette…, Supprimer ; Redimensionner absent pour
  FAT32 et exFAT avec la raison) ; `openVolumeHasNoActions` (« Éjectez ce volume d'abord ») ;
  `resizeDialogBoundsFromResizeInfo` (curseur et champ bornés par `minBytes`/`maxBytes`, rapport montré si non propre) ;
  `pendingBarUndoAndClear` ; `summaryListsOpsInOrder` ; `destructiveBatchNeedsDiskName` ;
  `encryptedOpsAskPassphraseAtApply` ; `applyShowsStepProgressAndStopsOnError` ; `newTableFromAppBarMenu` ;
  `formatScreenSizeChoice` ; `semanticsReadsBar` (« Partition 1, ext4, Données, 120 Go, 80 Go utilisés ») ;
  `noOverflowAt200Percent`. Écrans `partitions`, `partitionsPending` et `partitionApply` au banc d'accessibilité et en
  images de référence (clair, sombre).
- [ ] **Step 2 :** `flutter test test/partitions_screen_test.dart` : échec.
- [ ] **Step 3 : implémentation.** L'écran s'ouvre au-dessus de la barre de navigation, depuis le menu ⋮ de la carte
  du disque ; avertissement permanent : « Un débranchement pendant une opération peut rendre une partition illisible :
  sauvegardez d'abord ». Les opérations s'appliquent une à une ; à la fin, le disque est relu et l'écran montre le
  résultat.
- [ ] **Step 4 :** `flutter analyze && flutter test` verts, images de référence regardées.
- [ ] **Step 5 : commit** `feat(partitions): écran du disque, comme GParted`.

### Task 10 : documentation

- [ ] README : section « Partitions (nouveau en 1.10.0) » (vue du disque, opérations, ordre et sûreté, redimensionnement
  ext4, NTFS et LUKS, FAT32 et exFAT refusés, déplacement non proposé) ; formatage : la taille ; limites (MBR étendu :
  étiquette seulement, NTFS réduit marqué à vérifier par Windows, une opération coupée) ; licences d'e2fsprogs ;
  commandes de `verify_partitions_with_kernel.sh` dans « Tests ».
- [ ] Aide : « Partager un disque en plusieurs partitions » et « Agrandir ou réduire une partition » ; strings testées.
- [ ] Fiche d'essai `docs/superpowers/research/<AAAA-MM-JJ>-essais-phase17/essais.md` (T12), copiée sur `develop` et
  sur le téléphone (`Download/portail-tests/phase17/`).
- [ ] **Commit** `docs: gestion des partitions`.

### Task 11 : essais instrumentés sur le Pixel

- [ ] `tools/android/run_native_tests.sh <numéro-adb>` : tous les tests du moteur, dont ceux des phases 16 et 17 (sans
  les juges du PC, absents du téléphone : les images écrites sont rapatriées et jugées sur le PC).
- [ ] `PartitionsInstrumentedTest` : sur une image de 512 Mio dans `/data/local/tmp/fluluks/`, créer trois partitions
  (exFAT, ext4 chiffré, NTFS), étiquettes, agrandir l'ext4 chiffré, réduire le NTFS, supprimer l'exFAT ; durées
  notées ; image rapatriée et jugée par `sfdisk`, `e2fsck`, `ntfsfix`, `cryptsetup` et le noyau.
- [ ] Mémoire et pile d'e2fsck et de resize2fs sur le téléphone (pas de plantage, rapport lisible).
- [ ] **Commit** `test(partitions): essais instrumentés sur le Pixel`.

### Task 12 *(utilisateur)* : essais sur le Pixel avec une clé USB sacrifiée

- [ ] Construire et installer l'APK sur le Pixel **avant** de demander l'essai (`adb install -r`, APK de
  l'utilisateur sauvegardée).
- [ ] Fiche remplie : formater la clé avec une taille de 1 Gio ; créer une seconde partition ; étiquettes ; agrandir et
  réduire un ext4 chiffré et un NTFS ; supprimer ; nouvelle table GPT ; refus avec un volume ouvert ; coupure (clé
  retirée pendant un agrandissement) puis relecture ; clé relue sous Ubuntu par GParted et sous Windows ; TalkBack,
  sombre, paysage, texte à 200 %.

### Fin de phase

- [ ] Relecture finale de toute la branche.
- [ ] Fusion `feature/partitions` → `develop`, puis `release/1.10.0` (pubspec `1.10.0+18`), `main`, étiquette signée
  `v1.10.0`, après les versions des phases 15 et 16. Pas de push sans l'accord de l'utilisateur.

---

## Décisions du planificateur

Prises en l'absence de l'utilisateur ; chacune se change à faible coût si l'essai la contredit.

1. **Aperçu en Dart, revalidation dans le moteur** : `DiskPlan` calcule l'aperçu et refuse les opérations impossibles
   à la frappe ; le moteur recharge la table et revérifie tout avant chaque écriture (FL_ECHANGED si le disque a
   changé). *Coût si faux : déplacer la validation en Kotlin, même liste de règles.*
2. **Le début d'une partition ne bouge jamais ; pas de déplacement en phase 17.** Déplacer recopie toutes les données
   ; une coupure au milieu, sans journal, laisse une partition à moitié décalée et illisible. GParted le fait, mais sur
   un PC branché au secteur ; sur un téléphone, une clé arrachée est courante. *Coût si faux : une tâche avec journal
   de déplacement sur le disque (reprise après coupure), dans une phase suivante.*
3. **FAT32 et exFAT ne se redimensionnent pas** : aucun outil libre de référence pour exFAT ; pour FAT32, `fatresize`
   (libparted) n'est pas sûr dans tous les cas et n'existe pas pour Android. Refus expliqué (copier, recréer).
   *Coût si faux : agrandir FAT32 seul (le cas simple), une tâche.*
4. **MBR avec partition étendue** : vue complète, étiquette seulement ; créer, supprimer, formater ou redimensionner
   une partition logique demanderait d'écrire la chaîne des EBR. Une nouvelle table reste possible. *Coût si faux :
   écriture des EBR, une tâche.* Les partitions créées en MBR sont principales (4 au plus).
5. **e2fsck et resize2fs dans le processus** (bibliothèque, `exit` remplacé par `longjmp`) plutôt qu'un exécutable à
   part : seul le processus de Portail parle au disque USB (transport du moteur sur usbfs). AOSP compile déjà
   e2fsprogs pour Android. *Coût si faux : un exécutable relié au moteur par un tube, une tâche.*
6. **Vérification exigée avant un redimensionnement** (`e2fsck -fn`, `ntfsfix -n` propres), sans réparation : la
   réparation est la phase 18 ; un volume douteux se répare sous Linux ou Windows. *Coût si faux : aucun, la phase 18
   ajoute « Réparer ».*
7. **Supprimer n'efface pas les données** (comme GParted) : recréer la même partition retrouve les fichiers. Créer ou
   formater efface le premier et le dernier Mio de la partition (anciennes signatures), comme la phase 8.
8. **Confirmation** : résumé de toutes les opérations ; si l'une est destructive (supprimer, formater, réduire,
   nouvelle table), saisir le nom du disque comme au formatage. Une erreur arrête la suite, les opérations restantes
   sont abandonnées et le disque relu.
9. **Phrase d'un volume chiffré** demandée à la confirmation, pour les opérations qui en ont besoin (étiquette,
   redimensionnement), passée au moteur et mise à zéro aussitôt ; jamais gardée dans l'aperçu.
10. **Place occupée** lue à l'ouverture de l'écran par un montage en lecture seule de chaque partition en clair ; une
    partition chiffrée verrouillée montre « chiffrée » sans place, un volume ouvert sa place connue.
11. **Étiquette FAT32 aux deux endroits** (entrée de la racine et secteur de démarrage avec sa copie), comme `fatlabel`
    : Windows lit la première, certains appareils la seconde. Le nom de partition GPT n'est pas modifié.
12. **Taille au formatage du disque** : « Tout le disque » par défaut ; au choix, la partition unique prend la taille
    donnée et le reste est libre, à partager ensuite dans l'écran du disque.
13. **Pas de second arbre de travail** : la phase se fait dans `../Portail` sur `feature/partitions`, à la demande de
    l'utilisateur (dossiers inutiles supprimés le 2026-10-27).

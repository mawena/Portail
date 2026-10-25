# Portail — Phase 16 : analyseur de stockage, comme celui d'Ubuntu — Plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal :** Portail reçoit un **analyseur de stockage** sur le modèle de Baobab (l'« Analyseur d'utilisation des
disques » d'Ubuntu) : accueil des emplacements avec leur occupation, analyse récursive annulable aux résultats
affichés au fur et à mesure, place réellement occupée (blocs alloués, liens physiques comptés une fois), arbre trié
par taille, **anneaux concentriques** et **carte proportionnelle** synchronisés avec l'arbre, zoom au doigt, profondeur
réglable, menu d'un élément (explorateur, chemin, propriétés, corbeille), emplacements exclus. Il remplace l'analyse
de l'espace de la phase 9. Fin de phase : version **v1.9.0**.

**Architecture :**
- **Moteur natif (C11)** : `fl_stat` gagne la place allouée (`alloc`), l'inode (`ino`) et le nombre de liens
  (`nlink`) pour ext4, FAT12/16/32, exFAT et NTFS ; la liste JSON d'un dossier (`fj_list`, `fj_stat`) les porte.
- **Kotlin, paquet `com.mawena.fluluks.analyzer`** : `FileSource.duList` (liste d'un dossier avec sa place réelle :
  `lstat` d'Android pour le téléphone et les cartes SD, moteur pour les disques et les coffres, taille apparente pour
  un dossier distant) ; `DuTree` (arbre compact en tableaux primitifs, borné) ; `Scanner` (parcours itératif, un seul
  pour toutes les sources) ; `Analyzer` (analyses gardées, progression, vues élaguées pour les graphiques, actions,
  exclusions). Il remplace `files/SpaceAnalysis.kt`.
- **Flutter, dossier `lib/src/analyzer/`** : `AnalyzerController` (état de l'écran), géométrie pure des anneaux et de la
  carte proportionnelle, graphiques dessinés par `CustomPainter`, arbre dépliable, écran de l'analyse, accueil de
  l'analyseur. Dart ne reçoit jamais l'arbre entier : seulement une vue de 1 500 nœuds au plus et des pages d'enfants.
  `lib/src/screens/space_screen.dart` disparaît.

**Tech Stack :** C11 (lwext4, FatFs, ntfs-3g : déjà présents), Kotlin, coroutines, Pigeon 27.3.0, Flutter 3.41
(`CustomPainter`, aucune bibliothèque de graphiques), Python 3 (juges `fatjuge.py`, `ntfsjuge.py`), `debugfs`
(e2fsprogs du PC, juge ext4), JUnit 4, AndroidX Test.

**Spec :** [docs/superpowers/specs/2026-10-17-fluluks-design.md](../specs/2026-10-17-fluluks-design.md), **§ 26** (et
§ 15 pour l'analyse de la phase 9 remplacée, § 18 pour les dossiers distants, § 19 pour l'interface et
l'accessibilité, § 22 pour les coffres).

## Global Constraints

- **Ordre :** la phase 16 commence après la fusion de la phase 15 (`feature/ia`, v1.8.0) dans `develop`. Branche
  `feature/analyseur` créée depuis `develop` à ce moment, dans l'arbre `../Portail-wt-analyseur` (sous-modules
  initialisés avec `--reference ../Portail/native/third_party/<n>`, `mbedtls/framework` compris ; `android/gradlew` et
  le jar du wrapper copiés).
- **Commits :** identité `mawena <gamligocharles@gmail.com>`, Conventional Commits en français, sans aucune
  attribution ni mention d'outil d'aide à l'écriture ; fichiers nommés (`git commit -- <fichiers>`, nouveaux fichiers
  ajoutés d'abord). Chaque tâche coche ses étapes ici et sa ligne dans la feuille de route, sur la branche **et**
  aussitôt sur `develop` (commit `docs(feuille-de-route): phase 16, Tn faite sur feature/analyseur`, qui ne nomme que
  la feuille de route, au texte identique à celui de la branche).
- **Version :** `v1.9.0`, pubspec `1.9.0+17` (la v1.7.0 porte `1.7.0+15`, la v1.8.0 de la phase 15 `1.8.0+16`).
- **Dépendances :** aucune nouvelle bibliothèque C, Java, Kotlin ni Dart. Graphiques par `CustomPainter`.
- **Architecture existante :** parcours, stockage de l'arbre et actions en Kotlin ; Dart n'affiche que ce que Kotlin
  lui donne, par Pigeon (`pigeons/fluluks_api.dart`, puis `dart run pigeon --input pigeons/fluluks_api.dart`) ; chaînes
  visibles dans `Fr` ; jetons et composants du design system (`ui/tokens.dart`, `ui/theme.dart`, `ui/widgets.dart`,
  `ui/sheets.dart`) ; écrans ajoutés au banc `test/screen_harness.dart`.
- **Langue :** toute chaîne visible en français, avec la typographie vérifiée par `test/strings_test.dart` (espace
  insécable U+00A0 avant « : » et dans les guillemets, espace fine insécable U+202F avant « ? ! ; » et « % ») ;
  tailles par `Fr.humanSize`, dates par `Fr.friendlyDate`, pluriels par `Fr.count`.
- **Lecture seule :** une analyse n'écrit rien nulle part ; seules les actions demandées (corbeille, suppression)
  écrivent, par le chemin existant `Files.delete` (mêmes refus : racine, fichier d'un coffre ouvert, lecture seule).
- **Valeurs fixées** *(décisions du planificateur, voir la fin du plan)* :
  - arbre : **500 000** nœuds au plus par analyse (`DuTree.MAX_NODES`), **1 000 000** pour toutes les analyses gardées ;
    les **20** plus gros fichiers de chaque dossier gardés comme nœuds (`FILES_PER_DIR`), les autres résumés par
    dossier (nombre, place) ; **500** plus gros fichiers de l'analyse gardés, **100** montrés pour un dossier ;
    profondeur **256** au plus (`WriteOps.MAX_DEPTH`), au-delà le contenu est résumé dans le dossier ;
  - analyses gardées en mémoire : **3** (la plus ancienne oubliée), une seule en cours ;
  - progression publiée toutes les **250 ms** au plus ; vue de l'écran rechargée pendant l'analyse toutes les
    **500 ms** au plus ; pourcentage sur la place occupée du stockage, borné à **99 %** avant la fin ;
  - vues des graphiques : **1 500** nœuds au plus, élément gardé s'il pèse au moins **0,2 %** de la racine de la vue,
    sinon fondu dans « Autres » ; profondeur des graphiques **4** par défaut, de **2** à **8** ; anneau central :
    **25 %** du rayon ; segment de moins de **0,01 rad** non dessiné ; pages d'enfants de l'arbre : **200** ;
  - part « hors analyse » montrée si elle dépasse **0,5 %** de la place occupée ;
  - taille apparente montrée à côté de la place occupée si elles diffèrent de plus de **10 %** ;
  - FAT12/16/32 et exFAT : un dossier occupe **un cluster** (zéro pour la racine fixe de FAT12/16).
- **Téléphone :** jamais de `flutter drive` sans `--keep-app-running`, jamais `connectedAndroidTest` ; essais
  instrumentés par `adb install -r -t` (application et APK de test),
  `adb shell am instrument -w -r -e class com.mawena.fluluks.<Classe> com.mawena.fluluks.test/androidx.test.runner.AndroidJUnitRunner`,
  puis désinstallation de `com.mawena.fluluks.test` seulement. APK de l'utilisateur sauvegardée avant, rendue après.
  Les essais n'écrivent que dans `/data/local/tmp/fluluks/` ou le dossier privé de l'application.
- **Tests :** à la fin de chaque tâche, `flutter analyze`, `flutter test` et
  `cd android && ./gradlew -q --offline :app:testDebugUnitTest` sont verts ; une tâche qui touche `native/` lance aussi
  `cmake -S native -B build/native -G Ninja -DCMAKE_BUILD_TYPE=Debug -DFL_TESTS=ON -DFL_SANITIZE=ON`,
  `cmake --build build/native` et `ctest --test-dir build/native --output-on-failure -LE lent` (ASan/UBSan propres),
  puis `tools/android/run_native_tests.sh <numéro-adb>`. Jamais `dart format` sur des dossiers entiers (le code n'est
  pas au format de `dart format`).

## Review Focus

1. **Très grands arbres** (un million de fichiers, un dossier de 100 000 entrées, 300 niveaux d'imbrication) :
   mémoire bornée, aucune récursion qui déborde la pile, Dart jamais noyé. → T3 : `millionFilesBounded`,
   `hugeDirectoryKeepsTopFiles`, `deepNesting300NoRecursion`, `nodeCapFoldsIntoAncestors` ; T4 :
   `viewNeverExceedsMaxNodes`.
2. **Tailles fausses** : lien physique compté deux fois, fichier creux compté à sa taille apparente, lien symbolique
   suivi (boucle), passage sur un autre système de fichiers, unités `huge_file` d'ext4, données résidentes NTFS. → T1 :
   `ext4AllocMatchesDebugfs`, `ext4SparseFileAllocSmall`, `ext4HugeFileFlagCountsBlocks`, `ntfsAllocMatchesJudge` ;
   T2 : `localOtherDeviceFlagged` ; T3 : `hardLinksCountedOnce`, `symlinkNotFollowed`, `otherFsNotEntered` ; T4 :
   `progressClampedTo99UntilDone`.
3. **Stockage qui change** pendant ou après l'analyse : élément supprimé entre la liste et son `lstat`, disque éjecté,
   verrouillé ou débranché, coffre fermé, suppression depuis l'analyseur. → T2 : `localVanishedEntrySkipped` ; T3 :
   `entryVanishingDuringScanSkipped` ; T4 : `closingVolumeDropsItsAnalyses`, `deleteUpdatesAncestors`,
   `trashMovesSizeToTrashNode`.
4. **Suppression par erreur** depuis le graphique : racine de l'analyse, part « hors analyse », « Autres », dossier
   inaccessible, fichier d'un coffre ouvert. → T4 : `deleteRefusesAnalysisRoot`, `deleteRefusesOpenVaultFile` ; T8 :
   `deleteAsksConfirmationWithNameAndSize`, `rootAndPseudoNodesHaveNoDestructiveActions`.
5. **Graphique illisible** pour TalkBack, par la seule couleur, en sombre ou à 200 % du texte. → T6 :
   `paletteContrastAtLeast3to1` ; T7 : `semanticsSummaryTopFive`, `paintsWithoutOverflowAt200Percent` ; T8 :
   `rowSemanticsComplete` et le banc d'accessibilité.

---

### Task 1 : place allouée, inode et liens dans le moteur

**Files :**
- Modify : `native/include/fluluks/fs.h` (`fl_stat`), `native/src/fs/ext4_glue.c` (`fill_stat` reçoit le numéro
  d'inode), `native/src/fs/fat_glue.c`, `native/src/fs/ntfs_glue.c`, `native/jni/handles.c` (`entry_json`),
  `native/CMakeLists.txt`, `tools/fixtures/make_fixtures.sh` (arbre `tree-du/`, image `ext4-du.img`, manifeste
  `ext4-du.alloc` tiré de `debugfs`), `tools/fixtures/fatjuge.py` et `tools/fixtures/ntfsjuge.py` (sous-commande
  `alloc <img>`), `tools/android/run_native_tests.sh`
- Create : `native/tests/test_fs_alloc.c`
- Test : `native/tests/test_fs_alloc.c`, `native/tests/test_handles.c` (cas ajouté)

**Interfaces :**
- Produces (C) : trois champs ajoutés **à la fin** de `fl_stat` :
  `uint64_t alloc;` (octets alloués sur le support ; 0 pour des données résidentes NTFS),
  `uint64_t ino;` (inode ext4, numéro d'enregistrement MFT NTFS, 0 sur FAT et exFAT),
  `uint32_t nlink;` (liens physiques ; 1 sur FAT et exFAT).
- Produces (JSON de `fj_list` et `fj_stat`) : clés `"alloc"`, `"ino"`, `"nlink"` après `"gid"`.

- [ ] **Step 1 : jeu d'essai.** Dans `make_fixtures.sh`, l'arbre `tree-du/` : `un-octet.bin` (1 o),
  `dix-mille.bin` (10 000 o), `vide.bin` (0 o), `creux.bin` (1 Gio apparent, 4 096 o écrits à 512 Mio par
  `truncate` puis `dd conv=notrunc`), `lien-a.bin` et `lien-b.bin` (un même fichier de 100 000 o, lien physique),
  `gros-dossier/` (300 fichiers de 1 o), `profond/` (40 niveaux) ; `ext4-du.img` par
  `mkfs.ext4 -q -F -T default -b 4096 -I 256 -O ^orphan_file,^metadata_csum_seed -d tree-du/` (8 Mio) ; manifeste
  `ext4-du.alloc` : une ligne `chemin<TAB>Blockcount×512<TAB>inode<TAB>liens` par entrée, tirée de
  `debugfs -R "stat <chemin>"`. `fatjuge.py alloc` (clusters de la chaîne × taille du cluster) et `ntfsjuge.py alloc`
  (taille allouée du `$DATA` non résident, 0 en résident, `$INDEX_ALLOCATION` pour un dossier) écrivent le même
  format.
- [ ] **Step 2 : tests en échec** (`test_fs_alloc`) : `ext4AllocMatchesDebugfs` (chaque entrée : `alloc`, `ino`,
  `nlink` égaux au manifeste), `ext4SparseFileAllocSmall` (`creux.bin` : `size` = 1 073 741 824, `alloc` ≤ 16 384),
  `ext4HardLinksShareIno` (`lien-a.bin` et `lien-b.bin` : même `ino`, `nlink` = 2 ; `un-octet.bin` : `nlink` = 1),
  `ext4HugeFileFlagCountsBlocks` (copie de l'image, `debugfs -w -R "sif /dix-mille.bin flags 0x40000"` : `alloc` =
  `i_blocks` × 4 096), `fatAllocClusterRounded` (FAT32 de `mkfs.vfat -F 32 -s 8`, l'arbre écrit par le moteur :
  1 o → 4 096, 10 000 o → 12 288, 0 o → 0, dossier → 4 096 ; égal à `fatjuge.py alloc`), `exfatAllocClusterRounded`
  (`mkfs.exfat -c 32K` : 1 o → 32 768 ; égal au juge), `ntfsAllocMatchesJudge` (petit fichier résident → 0,
  10 000 o → 12 288, `gros-dossier` → taille de son index ; égal à `ntfsjuge.py alloc`) ; `test_handles` :
  `listJsonHasAllocInoNlink`.

  Run : `cmake --build build/native && ctest --test-dir build/native --output-on-failure -R 'test_fs_alloc|test_handles'`
  Expected : FAIL (champs absents de `fl_stat`).
- [ ] **Step 3 : implémentation.** ext4 : `i_blocks` (bas 32 bits et `osd2.linux2.blocks_high`) en secteurs de
  512 o, en blocs du système si la fonction `huge_file` est active et l'inode porte `EXT4_INODE_FLAG_HUGE_FILE` ;
  `links_count`. FAT et exFAT : `alloc` = taille arrondie au cluster (`csize × SS`), un cluster par dossier, 0 pour la
  racine fixe de FAT12/16. NTFS : `$DATA` non résident → `compressed_size` s'il est compressé ou creux, sinon
  `allocated_size` ; dossier → `allocated_size` de `$INDEX_ALLOCATION:$I30` (0 sans) ; `ino` = `ni->mft_no` ;
  `nlink` = `link_count` de l'enregistrement. `test_fs_alloc` ajouté à `run_native_tests.sh` (images poussées avec
  les autres).
- [ ] **Step 4 : vérification.**

  Run : `ctest --test-dir build/native --output-on-failure -LE lent` puis `tools/android/run_native_tests.sh <numéro-adb>`
  Expected : tout vert, ASan/UBSan propres ; sur le Pixel, `test_fs_alloc` vert.
- [ ] **Step 5 : commit** `feat(moteur): place allouée, inode et liens physiques dans la liste d'un dossier`.

### Task 2 : liste d'un dossier avec sa place réelle (Kotlin)

**Files :**
- Create : `android/app/src/main/kotlin/com/mawena/fluluks/analyzer/DuEntry.kt`, `analyzer/Lstat.kt`
- Modify : `files/FileSource.kt`, `files/LocalSource.kt`, `files/DiskSource.kt`, `engine/EngineModels.kt`
  (`DirEntry`), `android/app/src/test/kotlin/com/mawena/fluluks/MemEngine.kt` (`alloc` = taille arrondie à 4 096,
  `ino` croissant, `nlink` 1)
- Test : `android/app/src/test/kotlin/com/mawena/fluluks/DuListTest.kt`

**Interfaces :**
- Consumes : JSON de T1 (`alloc`, `ino`, `nlink`).
- Produces :
  - `enum class SizeKind { ALLOCATED, APPARENT }` ;
  - `data class DuEntry(val name: String, val type: FileType, val size: Long, val alloc: Long, val mtime: Long, val dev: Long, val ino: Long, val nlink: Int, val otherDevice: Boolean = false)` ;
  - `data class RawStat(val mode: Int, val size: Long, val blocks: Long, val mtime: Long, val dev: Long, val ino: Long, val nlink: Int)` ;
    `fun interface Lstat { fun of(path: String): RawStat? }` (null : l'entrée a disparu) ; `object AndroidLstat : Lstat`
    (`android.system.Os.lstat`, `ErrnoException` ENOENT → null, autre → `FileNotFoundException`) ;
  - dans `FileSource` : `val sizeKind: SizeKind get() = SizeKind.APPARENT`,
    `fun duList(path: String): List<DuEntry>` (par défaut depuis `list()` : `alloc` = `size`, `dev` = `ino` = 0,
    `nlink` = 1) et `fun usedBytes(): Long? = null` ; `LocalSource` et `DiskSource` les redéfinissent
    (`ALLOCATED` ; `usedBytes` = `totalSpace − freeSpace` du téléphone, `total − free` du `statfs` d'un disque) ;
  - `LocalSource(…, lstat: Lstat = AndroidLstat)` (paramètre ajouté en dernier) ;
  - `DirEntry.alloc: Long`, `DirEntry.ino: Long`, `DirEntry.nlink: Int` (absents du JSON : `size`, 0, 1).

- [ ] **Step 1 : tests en échec** (`DuListTest`, `Lstat` factice) : `localAllocFromBlocks` (`blocks` = 8 → `alloc`
  4 096 pour 1 o), `localSparseUsesBlocks` (`size` 1 Gio, `blocks` 8 → 4 096), `localSymlinkIsLinkNotFollowed`
  (type `SYMLINK`, cible jamais lue), `localAndroidPrivateIsProtected` (`/Android/data` et `/Android/obb` →
  `ProtectedDirException`), `localOtherDeviceFlagged` (`dev` différent de celui de la racine → `otherDevice`),
  `localVanishedEntrySkipped` (`lstat` null → entrée absente, pas d'erreur), `diskListCarriesAllocInoNlink`
  (`MemEngine`), `diskListOldEngineFallsBack` (JSON sans les clés → `alloc` = `size`, `nlink` 1),
  `diskListCountsAsActivity` (`VolumeManager.noteActivity` appelé, comme `list`), `remoteDefaultIsApparent`
  (implémentation par défaut, `sizeKind` = `APPARENT`), `usedBytesPerSource`.

  Run : `cd android && ./gradlew -q --offline :app:testDebugUnitTest --tests 'com.mawena.fluluks.DuListTest'`
  Expected : FAIL (classes absentes).
- [ ] **Step 2 : implémentation.** `LocalSource.duList` : mêmes contrôles que `list` (accès, chemin, `Android/data`),
  noms par `File.list()`, **un seul** `lstat` par entrée (type par `S_ISDIR`/`S_ISREG`/`S_ISLNK` du mode, `alloc` =
  `blocks × 512`). `DiskSource.duList` : `engine.list` par `handle()` (activité du volume), comme `list`.
- [ ] **Step 3 :** Run : `cd android && ./gradlew -q --offline :app:testDebugUnitTest` — Expected : PASS.
- [ ] **Step 4 : commit** `feat(analyseur): liste d'un dossier avec la place réellement occupée`.

### Task 3 : arbre compact et parcours (Kotlin)

**Files :**
- Create : `android/app/src/main/kotlin/com/mawena/fluluks/analyzer/DuTree.kt`, `analyzer/Scanner.kt`
- Test : `android/app/src/test/kotlin/com/mawena/fluluks/DuTreeTest.kt`, `ScannerTest.kt` (lister factice
  `(String) -> List<DuEntry>` en mémoire, généré à la demande pour les gros arbres)

**Interfaces :**
- Consumes : `DuEntry` (T2).
- Produces :
  - `enum class NodeKind { DIR, FILE, INACCESSIBLE, EXCLUDED, OTHER_FS }` ;
  - `class DuTree(val maxNodes: Int = MAX_NODES)` (`MAX_NODES = 500_000`, `FILES_PER_DIR = 20`, `MAX_BIGGEST = 500`) :
    `val root: Int` ; `kind(n)`, `name(n)`, `parent(n)` (−1 pour la racine), `alloc(n)`, `apparent(n)`, `items(n)`
    (éléments sous lui), `mtime(n)` (le plus récent dessous), `complete(n)`, `others(n): Others`
    (`data class Others(val count: Long, val alloc: Long, val apparent: Long)` : fichiers non gardés et contenu
    résumé), `children(n): IntArray` (place décroissante, puis nom), `path(n): String`, `find(path): Int?`,
    `addDir(parent: Int, name: String): Int`, `remove(n)` et `addTo(n, alloc, apparent, items)` (les ancêtres
    suivent), `setKind(n, kind)`, `nodeCount`, `simplified`,
    `truncated`, `bytesEstimate(): Long` ;
  - `class Scanner(val list: (String) -> List<DuEntry>, val tree: DuTree, val excluded: Set<String>, val cancelled: () -> Boolean, val onProgress: (ScanCounters) -> Unit)` ;
    `fun run(start: String): ScanEnd` (`enum class ScanEnd { DONE, CANCELLED }` ; dossier de départ illisible :
    l'exception sort) ; `data class ScanCounters(val files: Long, val dirs: Long, val alloc: Long, val current: String, val inaccessible: Int)` ;
    `val biggest: List<Entry>` (500 plus gros fichiers, par place occupée).

- [ ] **Step 1 : tests en échec** (`DuTreeTest`) : `childrenSortedBySizeThenName`, `pathRebuiltFromParents`,
  `findByPath`, `removePropagatesToAncestors`, `addToPropagates`, `namesUtf8Pool` (« été ☀ », nom de 255 octets),
  `bytesEstimateUnder64BytesPerNode` (100 000 nœuds aux noms de 12 octets : `bytesEstimate()` < 6,4 Mo).
- [ ] **Step 2 : tests en échec** (`ScannerTest`) :
  - `sizesSumAllocAndApparent` (`a.bin` 100 o / 4 096 alloués, `D/b.bin`, `D/E/c.bin`, `.cache/x` caché compté,
    dossier vide : `alloc` et `apparent` de la racine = sommes ; `items` = 7) ;
  - `hardLinksCountedOnce` (deux entrées de même `dev`/`ino`, `nlink` 2, dans deux dossiers : comptées une fois, la
    seconde à 0) ; `symlinkNotFollowed` (le lister n'est jamais appelé sur un lien, compté pour son `alloc` propre) ;
    `otherFsNotEntered` (`otherDevice` → nœud `OTHER_FS`, jamais listé) ;
  - `inaccessibleDirShown` (`ProtectedDirException` sur `/Android/data` → nœud `INACCESSIBLE` de taille 0,
    `inaccessible` = 1, le reste continue) ; `startDirUnreadableThrows` ;
    `entryVanishingDuringScanSkipped` (`FileNotFoundException` sur un sous-dossier listé par son parent : ignoré) ;
    `excludedNotListed` (chemin de `excluded` → nœud `EXCLUDED`, jamais listé) ;
  - `topFilesPerDirAndOthers` (1 000 fichiers : 20 nœuds `FILE`, `others` = 980 et leur place, total exact) ;
    `hugeDirectoryKeepsTopFiles` (100 000 entrées dans un dossier) ; `biggestTop500Global` ; `mtimeIsNewestBelow` ;
  - `deepNesting300NoRecursion` (300 niveaux, dans un fil à pile de 256 Kio : pas de `StackOverflowError`, au-delà de
    256 résumé, `truncated`) ; `nodeCapFoldsIntoAncestors` (`maxNodes` = 50, 200 dossiers : `nodeCount` ≤ 50,
    `simplified`, total de la racine exact) ; `millionFilesBounded` (10 000 dossiers × 100 fichiers générés à la
    demande : `nodeCount` ≤ 210 001, `bytesEstimate()` < 32 Mio, total exact) ;
  - `cancelStopsAndKeepsPartial` (annulé après 5 listes : `CANCELLED`, dossiers finis `complete`, en cours non) ;
    `progressCounters` (croissants, `current` = dossier en cours).

  Run : `cd android && ./gradlew -q --offline :app:testDebugUnitTest --tests 'com.mawena.fluluks.DuTreeTest' --tests 'com.mawena.fluluks.ScannerTest'`
  Expected : FAIL (classes absentes).
- [ ] **Step 3 : implémentation de `DuTree`** : tableaux primitifs qui grandissent par doublement (`IntArray` parent,
  premier enfant, frère suivant, début du nom ; `LongArray` alloc, apparent, items, mtime, autres ; `ByteArray` des
  noms en UTF-8 ; `ByteArray` des drapeaux) ; enfants triés à la fin de chaque dossier.
- [ ] **Step 4 : implémentation de `Scanner`** — parcours en profondeur **itératif** :

```text
pile ← [cadre(racine, sous-dossiers à visiter)]
tant que pile non vide et non annulé :
  cadre ← sommet
  si cadre n'a pas encore été listé :
    entrées ← list(chemin) (Protected → INACCESSIBLE ; FileNotFound hors départ → ignoré)
    fichiers : liens physiques vus une fois (clé dev/ino si nlink > 1) ; 20 plus gros → nœuds FILE, le reste → others
    dossiers : exclus → EXCLUDED ; otherDevice → OTHER_FS ; sinon sous-dossiers à visiter (ordre des noms)
  si un sous-dossier reste : nœud créé (ou, plafond atteint / profondeur > 256 : rien, le contenu ira dans others
    de l'ancêtre gardé), cadre empilé
  sinon : dossier complete, ses totaux ajoutés au parent, cadre dépilé
```

  `onProgress` à chaque dossier ; `cancelled()` relu entre deux entrées.
- [ ] **Step 5 :** Run : `cd android && ./gradlew -q --offline :app:testDebugUnitTest` — Expected : PASS.
- [ ] **Step 6 : commit** `feat(analyseur): arbre compact et parcours itératif borné`.

### Task 4 : analyses gardées, vues, actions et exclusions (Kotlin)

**Files :**
- Create : `android/app/src/main/kotlin/com/mawena/fluluks/analyzer/Analyzer.kt`, `analyzer/AnalysisViews.kt`,
  `analyzer/AnalyzerPrefs.kt` (`analyzer.json` du dossier privé : exclusions ; temporaire puis renommage)
- Test : `android/app/src/test/kotlin/com/mawena/fluluks/AnalyzerTest.kt`, `AnalysisViewsTest.kt`,
  `AnalyzerPrefsTest.kt`

**Interfaces :**
- Consumes : `FileSource.duList`, `sizeKind`, `usedBytes` (T2) ; `DuTree`, `Scanner` (T3) ; `Files.source`,
  `Files.delete`, `Trash.DIR` ; `VolumeManager.volumes`.
- Produces :
  - `object Analyzer` : `val progress: StateFlow<AnalysisProgress?>` ; `fun start(sourceId: String, path: String): String`
    (identifiant d'analyse ; arrête celle en cours) ; `fun cancel()` ; `fun list(): List<AnalysisSummary>` ;
    `fun forget(scanId: String)` ; `fun view(scanId: String, node: Int, depth: Int, maxNodes: Int): AnalysisView` ;
    `fun children(scanId: String, node: Int, sort: String, offset: Int, limit: Int): List<ViewNode>` (`sort` ∈
    `size`, `name`, `items`, `date`) ; `fun biggest(scanId: String, node: Int): List<Entry>` ;
    `suspend fun delete(scanId: String, node: Int, permanent: Boolean)` ; `fun exclude(scanId: String, node: Int)` ;
    `fun exclusions(): List<Exclusion>` ; `fun removeExclusion(stableKey: String, path: String)` ;
    `fun resetForTests(dispatcher: CoroutineDispatcher, clock: () -> Long, dir: File)` ;
  - `data class AnalysisProgress(val scanId: String, val sourceId: String, val path: String, val running: Boolean, val cancelled: Boolean, val error: String?, val files: Long, val dirs: Long, val bytes: Long, val usedBytes: Long?, val current: String, val inaccessible: Int, val elapsedMs: Long)` ;
  - `data class AnalysisSummary(val scanId: String, val sourceId: String, val label: String, val path: String, val startedAtMs: Long, val finishedAtMs: Long?, val bytes: Long, val files: Long, val state: String, val sizeKind: SizeKind)`
    (`state` ∈ `running`, `done`, `cancelled`, `failed`) ;
  - `data class ViewNode(val id: Int, val parent: Int, val name: String, val path: String, val kind: String, val alloc: Long, val apparent: Long, val items: Long, val mtime: Long, val hasChildren: Boolean, val complete: Boolean, val depth: Int)` ;
    `kind` ∈ `dir`, `file`, `others`, `inaccessible`, `excluded`, `otherFs`, `unscanned`, `trash` ; nœuds virtuels
    (`others`, `unscanned`) d'identifiant négatif ;
  - `data class AnalysisView(val scanId: String, val root: Int, val rootLabel: String, val nodes: List<ViewNode>, val running: Boolean, val truncated: Boolean, val simplified: Boolean, val sizeKind: SizeKind)`
    (nœuds en largeur d'abord, la racine de la vue en premier, profondeur relative) ;
  - `data class Exclusion(val stableKey: String, val sourceLabel: String, val path: String)`.

- [ ] **Step 1 : tests en échec** (`AnalysisViewsTest`) : `viewDepthLimited` (profondeur 2 : petits-enfants absents,
  `hasChildren` vrai), `smallNodesMergedIntoOthers` (moins de 0,2 % de la racine de la vue → un `others` par parent,
  place exacte), `viewNeverExceedsMaxNodes` (arbre de 50 000 dossiers égaux, `maxNodes` 1 500 → ≤ 1 500),
  `foldedContentShownAsOthers` (`DuTree.others` d'un dossier ajouté à son `others`), `childrenPagedAndSorted` (200
  par page ; tri par place, nom, éléments, date), `biggestUnderNode` (100 au plus, sous le nœud seulement),
  `unscannedPartForWholeStorage` (analyse de `/` : `unscanned` = occupé − compté s'il dépasse 0,5 % ; libellé
  « Applications, système et dossiers protégés » pour le téléphone, « Réservé par le système de fichiers » sinon ;
  aucun pour un sous-dossier ni pour un dossier distant), `trashDirMarked` (`/.Portail-corbeille` → `trash`).
- [ ] **Step 2 : tests en échec** (`AnalyzerTest`, `Files.setResolverForTests`, horloge et répartiteur de test) :
  `drillDownNeverRelists` (une source qui compte ses listes : `view` et `children` n'en font aucune ; repris de
  `drillDownUsesCache`), `unreadableDirSkipped` et `cancelStops` (repris de la phase 9), `oneScanAtATime` (un
  `start` arrête le précédent, marqué `cancelled`), `threeAnalysesKept` (la quatrième fait oublier la plus ancienne ;
  plus de 1 000 000 nœuds au total : la plus ancienne aussi), `progressThrottled250ms`,
  `progressClampedTo99UntilDone` (liens physiques et compression : jamais plus de 99 % avant la fin, 100 % à la fin),
  `closingVolumeDropsItsAnalyses` (volume retiré de `VolumeManager.volumes` : analyse en cours arrêtée avec
  « Le stockage a été fermé pendant l'analyse », analyses gardées de ce volume oubliées),
  `deleteUpdatesAncestors` (définitif : nœud retiré, ancêtres diminués, `Files.delete(…, true)` appelé),
  `trashMovesSizeToTrashNode` (corbeille : place reportée sur le nœud `/.Portail-corbeille`, créé au besoin),
  `deleteRefusesAnalysisRoot` (« La racine de l'analyse ne peut pas être supprimée »), `deleteRefusesOpenVaultFile`
  (refus de `Files.delete` relayé, arbre intact), `excludeStoresAndMarksNode` (nœud `excluded`, ancêtres diminués,
  exclusion lue par l'analyse suivante), `remoteUsesApparentSizes` ; `AnalyzerPrefsTest` : `roundTrip`,
  `damagedFileGivesEmptyList`. Ces cas couvrent ceux de `SpaceAnalysisTest`, retiré avec `SpaceAnalysis.kt` en T9.

  Run : `cd android && ./gradlew -q --offline :app:testDebugUnitTest --tests 'com.mawena.fluluks.Analyzer*' --tests 'com.mawena.fluluks.AnalysisViewsTest'`
  Expected : FAIL (classes absentes).
- [ ] **Step 3 : implémentation.** `Analyzer` lance le `Scanner` sur un fil à part de priorité basse
  (`THREAD_PRIORITY_BACKGROUND`), sous un verrou lecture-écriture de l'arbre (les vues lisent pendant l'analyse) ;
  observe `VolumeManager.volumes` ; libellés français en constantes (`MSG_SOURCE_CLOSED`, `MSG_ROOT`, `UNSCANNED_PHONE`,
  `UNSCANNED_FS`) testées.
- [ ] **Step 4 :** Run : `cd android && ./gradlew -q --offline :app:testDebugUnitTest` — Expected : PASS.
- [ ] **Step 5 : commit** `feat(analyseur): analyses gardées, vues élaguées, corbeille et exclusions`.

### Task 5 : pont Pigeon et contrôleur de l'écran

**Files :**
- Modify : `pigeons/fluluks_api.dart` (+ générés), `bridge/HostApiImpl.kt`, `lib/src/state/host_api.dart`,
  `lib/src/state/app_state.dart` (`analysisProgress`), `test/fake_host_api.dart`, `test/demo_data.dart`
- Create : `lib/src/analyzer/analyzer_controller.dart`
- Test : `test/analyzer_controller_test.dart`, `android/app/src/test/kotlin/com/mawena/fluluks/AnalyzerMsgTest.kt`

**Interfaces :**
- Consumes : `Analyzer` (T4).
- Produces (Pigeon) : `AnalysisNodeMsg`, `AnalysisViewMsg`, `AnalysisProgressMsg` (`usedBytes` nullable),
  `AnalysisSummaryMsg`, `AnalysisExclusionMsg`, mêmes champs que les types Kotlin de T4 (`sizeKind` en chaîne
  `allocated` ou `apparent`) ; HostApi : `String startAnalysis(String sourceId, String path)`, `void cancelAnalysis()`
  (gardé), `List<AnalysisSummaryMsg> analyses()`, `void forgetAnalysis(String scanId)`,
  `@async AnalysisViewMsg analysisView(String scanId, int node, int depth, int maxNodes)`,
  `@async List<AnalysisNodeMsg> analysisChildren(String scanId, int node, String sort, int offset, int limit)`,
  `@async List<EntryMsg> analysisBiggest(String scanId, int node)`,
  `@async void analysisDelete(String scanId, int node, bool permanent)`, `void analysisExclude(String scanId, int node)`,
  `List<AnalysisExclusionMsg> analysisExclusions()`, `void removeAnalysisExclusion(String stableKey, String path)` ;
  événement `void onAnalysisProgress(AnalysisProgressMsg? progress)` ; `UiPrefsMsg.analyzerChart` (`rings`,
  `treemap`, `none`) et `UiPrefsMsg.analyzerDepth`, nullables. L'ancienne API (`analyzeSpace`, `spaceChildren`,
  `SpaceItemMsg`, `SpaceReportMsg`) reste jusqu'à T9.
- Produces (Dart) : `class AnalyzerController extends ChangeNotifier` : `AnalyzerController(AppState state, {Duration refresh = const Duration(milliseconds: 500)})` ;
  `Future<void> start(String sourceId, String path)`, `Future<void> open(String scanId)`, `AnalysisViewMsg? view`,
  `List<AnalysisNodeMsg> trail` (racine → nœud affiché), `Future<void> zoom(int node)`, `Future<void> up()`,
  `Future<void> goTo(int index)`, `int depth`, `void setDepth(int d)` (2 à 8), `ChartKind chart` (`rings`, `treemap`,
  `none`), `void setChart(ChartKind k)`, `int? selected`, `void select(int? node)`,
  `Future<List<AnalysisNodeMsg>> children(int node, {String sort = 'size', int offset = 0})`,
  `Future<void> delete(int node, {required bool permanent})`, `Future<void> exclude(int node)`, `Future<void> rescan()`,
  `void dispose()`.

- [ ] **Step 1 : tests en échec** (`analyzer_controller_test`, `FakeHostApi`) : `startShowsLiveViewThrottled`
  (événements toutes les 100 ms pendant 2 s : vue rechargée au plus toutes les 500 ms, puis une fois à la fin),
  `zoomAndUpKeepTrail`, `goToBreadcrumb`, `depthBounded2to8` (et mémorisée dans `UiPrefsMsg.analyzerDepth`),
  `chartKindRemembered`, `deleteRefreshesView`, `forgottenScanReturnsToHome` (analyse oubliée par Kotlin : erreur
  traduite, contrôleur vide), `progressEventUpdatesAppState` ; Kotlin `AnalyzerMsgTest` : `msgConversionKeepsFields`
  (`usedBytes` null, identifiants négatifs, `sizeKind`).

  Run : `flutter test test/analyzer_controller_test.dart`
  Expected : FAIL (contrôleur absent).
- [ ] **Step 2 : implémentation** ; `HostApiImpl` relaie `Analyzer.progress` comme `Transfers.state`
  (`events.onAnalysisProgress`) ; les appels `@async` passent par le répartiteur d'E/S. `cancelAnalysis` arrête
  désormais l'analyse de l'`Analyzer` comme celle de `SpaceAnalysis`.
- [ ] **Step 3 :** Run : `dart run pigeon --input pigeons/fluluks_api.dart && flutter analyze && flutter test && (cd android && ./gradlew -q --offline :app:testDebugUnitTest)`
  — Expected : tout vert.
- [ ] **Step 4 : commit** `feat(analyseur): pont Pigeon et contrôleur de l'écran d'analyse`.

### Task 6 : géométrie des anneaux et de la carte proportionnelle

**Files :**
- Create : `lib/src/analyzer/chart_layout.dart` (types communs), `lib/src/analyzer/sunburst_layout.dart`,
  `lib/src/analyzer/treemap_layout.dart`, `lib/src/analyzer/chart_palette.dart`
- Test : `test/chart_layout_test.dart`

**Interfaces :**
- Consumes : `AnalysisViewMsg` (T5).
- Produces :
  - `class RingSegment { final int id; final int depth; final double start, sweep, inner, outer; }` ;
    `List<RingSegment> layoutRings(AnalysisViewMsg v, {required double radius, double centerFraction = 0.25, double minSweep = 0.01})`
    (la racine de la vue au centre ; anneau `d` entre `r0 + (d−1)·w` et `r0 + d·w`, `w = (radius − r0) / profondeur`) ;
    `({bool center, int id})? hitRing(List<RingSegment> s, Offset fromCenter, double centerRadius)` (centre, segment,
    ou null hors du graphique ; les identifiants virtuels sont négatifs) ;
  - `class TreemapCell { final int id; final int depth; final Rect rect; final bool labelled; }` ;
    `List<TreemapCell> layoutTreemap(AnalysisViewMsg v, Rect bounds, {double header = 18, double pad = 1, double minSide = 2})`
    (algorithme « squarified » de Bruls, Huizing et van Wijk, imbriqué : un dossier assez haut garde une bande de
    titre de `header` dp, ses enfants dessous) ; `int? hitTreemap(List<TreemapCell> c, Offset p)` (la cellule la plus
    profonde) ;
  - `Color segmentColor(ColorScheme s, {required int topIndex, required int depth, required String kind})` : huit
    teintes pour les enfants directs de la racine de la vue, éclaircies (clair) ou assombries (sombre) avec la
    profondeur ; `file` en ton neutre de la même teinte, `others`, `unscanned`, `inaccessible` en gris
    (`surfaceContainerHighest`, `outline`).

- [ ] **Step 1 : tests en échec** : `ringsAnglesProportional` (balayages ∝ place ; chaque enfant dans la plage de son
  parent ; somme ≤ 2π), `ringsDepthRadii`, `ringsTinySegmentsDropped` (moins de 0,01 rad : non dessiné),
  `ringsHitTest` (angle et rayon → segment ; centre → `center` vrai ; dehors → null),
  `treemapAreasProportional` (aires ∝ place à 1 % près, à chaque niveau, bandes de titre déduites),
  `treemapSquarifiedAspect` (valeurs 6, 6, 4, 3, 2, 2, 1 dans 6 × 4 : pire rapport des côtés ≤ 3, comme l'article),
  `treemapNestedInsideParent`, `treemapHitDeepest`, `zeroSizeAndEmptyView` (aucun NaN, liste vide),
  `paletteContrastAtLeast3to1` (chaque teinte, profondeurs 0 à 3, contre `surface`, en clair et en sombre : contraste
  ≥ 3:1, règle des objets graphiques), `paletteTopLevelHuesDistinct`.

  Run : `flutter test test/chart_layout_test.dart`
  Expected : FAIL (fonctions absentes).
- [ ] **Step 2 : implémentation** (fonctions pures, sans widget). Squarified : lignes remplies tant que le pire
  rapport ne se dégrade pas, côté court d'abord.
- [ ] **Step 3 :** Run : `flutter test test/chart_layout_test.dart` — Expected : PASS.
- [ ] **Step 4 : commit** `feat(analyseur): géométrie des anneaux et de la carte proportionnelle`.

### Task 7 : graphiques à l'écran et gestes

**Files :**
- Create : `lib/src/analyzer/analysis_chart.dart`, `lib/src/analyzer/chart_info_strip.dart`
- Modify : `lib/src/strings_fr.dart`
- Test : `test/analysis_chart_test.dart`

**Interfaces :**
- Consumes : T5 (`AnalysisViewMsg`, `ChartKind`), T6 (mises en page, `hit*`, `segmentColor`).
- Produces : `AnalysisChart({required AnalysisViewMsg view, required ChartKind kind, int? selected, required ValueChanged<int> onZoom, required VoidCallback onUp, required ValueChanged<int?> onSelect, required ValueChanged<int> onMenu})` ;
  `ChartInfoStrip({required AnalysisNodeMsg? node, required AnalysisNodeMsg root, required String sizeKind})` ;
  `Fr.chartSummary(String kind, String root, List<(String name, int bytes, int pct)> top)`, `Fr.ofParent(int pct, String parent)`,
  `Fr.onDiskOfData(int alloc, int apparent)`, `Fr.analysisItems(int n)`.

- [ ] **Step 1 : tests en échec** : `tapDirZooms` (toucher un segment de dossier → `onZoom(id)`), `tapFileSelectsOnly`
  (fichier, `others`, `unscanned` → `onSelect`, jamais `onZoom`), `tapCenterGoesUp` (anneaux), `dragUpdatesInfoStrip`
  (glisser le doigt : la bande montre « Photos — 12,3 Go — 45 % de Téléphone — 1 234 éléments »),
  `apparentShownWhenDifferent` (« 4 Ko sur le disque (1 octet de données) »), `longPressOpensMenu` (`onMenu(id)`),
  `treemapSameGestures`, `selectedOutlined` (contour de 2 dp de couleur `primary`), `semanticsSummaryTopFive`
  (TalkBack lit « Graphique en anneaux de Téléphone : Photos, 12,3 Go, 45 % ; … » avec les cinq plus gros, et le
  dessin lui-même est exclu de l'arbre sémantique), `disabledAnimationsNoTransition` (`MediaQuery.disableAnimations` :
  aucun fondu au zoom), `paintsWithoutOverflowAt200Percent` (étiquettes de la carte tronquées, jamais débordantes).

  Run : `flutter test test/analysis_chart_test.dart`
  Expected : FAIL (widgets absents).
- [ ] **Step 2 : implémentation.** `CustomPainter` (segments séparés par un trait de 1 dp couleur `surface` ; noms
  dessinés dans les segments et cellules assez grands, en `onSurface` ou `surface` selon le contraste) ; gestes par un
  seul `GestureDetector` (`onTapUp`, `onLongPressStart`, `onPanStart/Update/End`) ; passage d'un zoom à l'autre en
  fondu de `Motion.medium`, coupé quand Android coupe les animations.
- [ ] **Step 3 :** Run : `flutter test test/analysis_chart_test.dart` — Expected : PASS.
- [ ] **Step 4 : commit** `feat(analyseur): anneaux et carte proportionnelle, au doigt et lus par TalkBack`.

### Task 8 : écran de l'analyse (graphique, arbre, actions)

**Files :**
- Create : `lib/src/analyzer/analyzer_screen.dart`, `lib/src/analyzer/analysis_tree.dart`,
  `lib/src/analyzer/node_actions.dart`, `lib/src/widgets/delete_dialog.dart` (dialogue de suppression extrait de
  l'explorateur)
- Modify : `lib/src/screens/explorer_screen.dart` (utilise `confirmDelete`), `lib/src/strings_fr.dart`,
  `test/screen_harness.dart` (écrans `analyzer`, `analyzerTreemap`), `test/accessibility_test.dart`,
  `test/goldens_test.dart` (`analyzer_light`, `analyzer_dark`), `test/demo_data.dart`
- Test : `test/analyzer_screen_test.dart`, `test/explorer_screen_test.dart` (inchangé, doit rester vert)

**Interfaces :**
- Consumes : T5 (`AnalyzerController`), T7 (`AnalysisChart`, `ChartInfoStrip`) ; `showActionSheet`, `showProperties`,
  `openExplorer`, `openTrash`, `showMessage`, `Breadcrumbs`, `DelayedProgress`, `StatusBanner`.
- Produces : `Future<void> openAnalysis(BuildContext context, AppState state, {String? scanId, String? sourceId, String path = '/'})`
  (avec `sourceId` : lance l'analyse ; avec `scanId` : rouvre une analyse gardée) ;
  `Future<bool?> confirmDelete(BuildContext context, {required String title, required String body, required bool trashOffered})`
  (null : annulé ; vrai : définitif).

- [ ] **Step 1 : tests en échec** :
  - `progressShownThenLiveResults` (barre déterminée quand `usedBytes` est connu, sinon indéterminée ;
    « 12 345 fichiers · 4,2 Go », dossier en cours ; **Annuler** → `cancelAnalysis` ; bandeau « Résultats partiels :
    analyse arrêtée » et **Réanalyser**) ;
  - `treeSortedBySizeWithColumns` (nom, taille, « 1 234 éléments », `Fr.friendlyDate`, barre = part du parent,
    pourcentage) ; `expandRowLoadsChildrenPaged` (200 par page, « Afficher plus ») ; `sortMenuChangesOrder` ;
    `biggestFilesTab` (100 plus gros fichiers du dossier affiché, avec leur dossier ; repris de la phase 9) ;
  - `tapRowZoomsChartAndBreadcrumb` (arbre et graphique synchronisés, fil d'Ariane, **Dossier parent** ; Retour
    remonte d'un niveau, puis quitte) ; `depthButtonsBounded` (« Moins de niveaux » / « Plus de niveaux » grisés aux
    bornes) ; `chartToggleRingsTreemapHidden` ;
  - `menuActions` (appui long sur une ligne ou un segment : **Afficher dans l'explorateur** — un dossier s'ouvre
    lui-même, un fichier son dossier ; **Copier le chemin** → presse-papiers « /DCIM/Camera » et message ;
    **Propriétés** ; **Exclure des analyses**) ;
  - `deleteAsksConfirmationWithNameAndSize` (même dialogue que l'explorateur, titre avec le nom et la taille ;
    corbeille → « Mis à la corbeille : la place sera libérée quand la corbeille sera vidée » et **Ouvrir la
    corbeille** ; définitif ; dossier distant : définitif seulement) ;
    `rootAndPseudoNodesHaveNoDestructiveActions` (racine, `others`, `unscanned`, `inaccessible`, `otherFs` : ni
    corbeille ni suppression ; `trash` : **Ouvrir la corbeille**) ;
  - `inaccessibleExplained` (« Accès refusé par Android »), `remoteShowsApparentNotice` (« Dossier distant : tailles
    annoncées par le serveur »), `simplifiedBanner` (« Trop d'éléments : le détail des plus petits dossiers est
    résumé ») ;
  - `wideLayoutSideBySide` (≥ 840 dp : graphique à gauche, arbre à droite) ; `rowSemanticsComplete` (« Photos,
    dossier, 12,3 Go, 45 % de Téléphone, 1 234 éléments, modifié hier », actions TalkBack « Ouvrir », « Développer »,
    « Actions »).

  Run : `flutter test test/analyzer_screen_test.dart`
  Expected : FAIL (écran absent).
- [ ] **Step 2 : implémentation.** Portrait : graphique carré en haut (45 % de la hauteur au plus), bande
  d'information, arbre dessous ; barre de titre : nom de l'emplacement, **Réanalyser**, choix du graphique, menu (tri,
  profondeur, plus gros fichiers). Lignes de l'arbre en deux lignes (nom et taille ; barre, pourcentage, éléments,
  date), retrait de 16 dp par niveau, 4 niveaux de retrait au plus. Écrans au banc d'accessibilité (48 dp, contraste,
  200 %, TalkBack, pas de texte sous la barre de navigation) ; images de référence clair et sombre.
- [ ] **Step 3 :** Run : `flutter test test/analyzer_screen_test.dart test/explorer_screen_test.dart test/accessibility_test.dart && flutter test --update-goldens test/goldens_test.dart`
  — Expected : PASS ; les deux nouvelles images regardées une à une avant d'être gardées.
- [ ] **Step 4 : commit** `feat(analyseur): écran de l'analyse, arbre synchronisé et actions`.

### Task 9 : accueil de l'analyseur, points d'entrée, exclusions ; fin de l'ancienne analyse

**Files :**
- Create : `lib/src/analyzer/analyzer_home_screen.dart`
- Modify : `lib/src/screens/home_screen.dart` (bouton **Analyseur de stockage** dans la barre de titre),
  `lib/src/widgets/source_tile.dart`, `lib/src/widgets/partition_tile.dart`, `lib/src/widgets/vault_tile.dart` (menu
  **Analyser**), `lib/src/screens/explorer_screen.dart` (**Analyser ce dossier** dans tout dossier ; avertissement pour
  un dossier distant), `lib/src/screens/settings_screen.dart` (Fichiers → **Emplacements exclus de l'analyse**),
  `lib/src/strings_fr.dart` (`spaceAnalysis`, `spaceFolders`, `spaceTruncated`, `spaceTotal`, `spaceOthers` retirés),
  `test/screen_harness.dart` et `test/accessibility_test.dart` (`space` remplacé par `analyzerHome`),
  `test/home_screen_test.dart`, `test/filters_test.dart`, `test/settings_screen_test.dart`
- Delete : `lib/src/screens/space_screen.dart`, `test/space_test.dart`, `files/SpaceAnalysis.kt`,
  `android/app/src/test/kotlin/com/mawena/fluluks/SpaceAnalysisTest.kt` ; dans `pigeons/fluluks_api.dart` (+ générés),
  `HostApiImpl.kt`, `host_api.dart` et `fake_host_api.dart` : `analyzeSpace`, `spaceChildren`, `SpaceItemMsg`,
  `SpaceReportMsg`
- Test : `test/analyzer_home_test.dart`

**Interfaces :**
- Consumes : T5 (`analyses`, `startAnalysis`, `analysisExclusions`, `removeAnalysisExclusion`), T8 (`openAnalysis`),
  `pickFolder`, `state.sources`.
- Produces : `Future<void> openAnalyzerHome(BuildContext context, AppState state)`.

- [ ] **Step 1 : tests en échec** : `listsLocationsWithUsage` (téléphone, cartes SD, volumes ouverts, coffres ouverts,
  avec leur jauge ; ni dossier distant ni fichier déchiffré), `analyzeFolderUsesPicker` (**Analyser un dossier…** →
  `pickFolder` ; dossier distant → avertissement « L'analyse lit chaque dossier par le réseau : elle peut être longue.
  Les tailles sont celles annoncées par le serveur. »), `keptAnalysesListed` (date, taille, **Ouvrir**,
  **Réanalyser**, **Oublier**), `runningAnalysisCard` (analyse en cours avec sa progression, touchée → écran de
  l'analyse), `startWhileRunningAsks` (« Arrêter l'analyse de Téléphone ? »), `entryPointsOpenAnalysis` (tuile de
  stockage, tuile de partition, tuile de coffre, explorateur dans `/DCIM` → `startAnalysis(id, '/DCIM')`),
  `exclusionsListedAndRemovable` (Réglages), `noOldSpaceApiLeft` (test de source, comme `source_rules_test` : ni
  `analyzeSpace` ni `SpaceReportMsg` dans `lib/`).

  Run : `flutter test test/analyzer_home_test.dart`
  Expected : FAIL (écran absent).
- [ ] **Step 2 : implémentation** ; écran ajouté au banc d'accessibilité ; libellés : « Analyser le stockage » (tuiles,
  racine de l'explorateur), « Analyser ce dossier » (sous-dossier).
- [ ] **Step 3 :** Run : `dart run pigeon --input pigeons/fluluks_api.dart && flutter analyze && flutter test && (cd android && ./gradlew -q --offline :app:testDebugUnitTest)`
  — Expected : tout vert, aucune référence à `space_screen.dart` ni à `SpaceAnalysis`.
- [ ] **Step 4 : commit** `feat(analyseur): accueil de l'analyseur, points d'entrée et emplacements exclus`.

### Task 10 : documentation

- [ ] README : section « Analyseur de stockage (nouveau en 1.9.0) » à la place de « Analyse de l'espace » (emplacements,
  tailles réelles et liens physiques, anneaux et carte, gestes, actions, exclusions, part « hors analyse »,
  `Android/data`, dossiers distants) ; phrase d'introduction et « Liste ou grille partout » mises à jour ; limites (taille
  des applications non comptée, pas de cache sur le stockage, dossiers d'un cluster sur FAT) ; commande du jeu
  `ext4-du.img` dans « Tests ».
- [ ] Aide : « Qu'est-ce qui remplit mon téléphone ? » et « Pourquoi l'analyse ne compte pas tout ? » (applications et
  système, `Android/data`, corbeille) ; strings testées.
- [ ] Fiche d'essai `docs/superpowers/research/<AAAA-MM-JJ>-essais-phase16/essais.md` (T12), copiée sur `develop` et
  sur le téléphone (`Download/portail-tests/phase16/`).
- [ ] **Commit** `docs: analyseur de stockage`.

### Task 11 : essais instrumentés sur le Pixel

**Files :** Create `android/app/src/androidTest/kotlin/com/mawena/fluluks/AnalyzerInstrumentedTest.kt` ; Modify
`Fixtures.kt`

- [ ] **Step 1 : essais** (dossier privé de l'application et `/data/local/tmp/fluluks/`) : `phoneLstatAllocated` (1 o
  → au moins 4 096 alloués ; fichier creux de 64 Mio par `RandomAccessFile.setLength` → moins de 1 Mio ; lien
  physique par `Os.link` compté une fois), `sharedStorageScanTimed` (stockage partagé entier : durée, fichiers, nœuds,
  mémoire Java et native notées ; `Android/data` « inaccessible » ; part « hors analyse » présente),
  `diskImageAllocMatchesJudge` (`ext4-du.img` ouverte par le moteur comme dans `EngineTest` : totaux et nœuds égaux
  au manifeste `ext4-du.alloc`), `fiftyThousandFilesBounded` (50 000 fichiers dans 500 dossiers : durée, mémoire Java
  gagnée < 64 Mio), `trashFromAnalysisMovesSize` (source locale sur le dossier privé).
- [ ] **Step 2 :** `adb install -r -t` des deux APK puis
  `adb shell am instrument -w -r -e class com.mawena.fluluks.AnalyzerInstrumentedTest com.mawena.fluluks.test/androidx.test.runner.AndroidJUnitRunner`
  (jamais `connectedAndroidTest`) ; journal `docs/superpowers/research/<date>-essais-phase16/instrumentes-<horodatage>.txt` ;
  Expected : `OK (5 tests)`, durées et mémoire notées dans la feuille de route.
- [ ] **Step 3 : commit** `test(analyseur): essais instrumentés sur le Pixel`.

### Task 12 *(utilisateur)* : essais sur le Pixel

- [ ] Construire et installer l'APK sur le Pixel **avant** de demander l'essai (`adb install -r`, APK de
  l'utilisateur sauvegardée).
- [ ] Fiche remplie : analyse du téléphone (durée, total comparé à Paramètres → Stockage d'Android, part « hors
  analyse ») ; analyse du disque USB LUKS, puis du **même disque sous Ubuntu par Baobab** : totaux des cinq plus gros
  dossiers égaux à 1 % près ; anneaux et carte : toucher pour entrer, centre et fil d'Ariane pour remonter, glisser le
  doigt, profondeur ; arbre trié, déplié, trié autrement ; appui long : explorateur, copier le chemin, corbeille (place
  reportée sur la corbeille), exclusion puis réanalyse ; annulation en cours d'analyse ; éjection du disque pendant une
  analyse ; coffre ouvert analysé ; dossier distant SFTP ; TalkBack sur l'arbre et le graphique ; thème sombre ;
  paysage ; texte à 200 %.

### Fin de phase

- [ ] Relecture finale de toute la branche.
- [ ] Fusion `feature/analyseur` → `develop`, puis `release/1.9.0` (pubspec `1.9.0+17`), `main`, étiquette signée
  `v1.9.0`. Pas de push sans l'accord de l'utilisateur.

---

## Décisions du planificateur

Prises en l'absence de l'utilisateur ; chacune se change à faible coût si l'essai la contredit.

1. **L'analyseur remplace l'analyse de la phase 9** (Kotlin, écran, API Pigeon) au lieu de la doubler ; ses cas de
   test sont repris, ses points d'entrée gardés et étendus à tout dossier de l'explorateur. *Coût si faux : aucun
   retour en arrière utile, l'analyseur fait tout ce qu'elle faisait.*
2. **Stockages analysables** : téléphone, cartes SD, volumes ouverts des disques USB et coffres ouverts, avec les
   tailles réelles. **Dossiers distants** depuis l'explorateur seulement, après avertissement, en tailles apparentes :
   chaque dossier coûte un aller-retour réseau et SFTP ou FTP ne donnent pas la place allouée ; la phase 9 les
   permettait déjà. Pas de fichier déchiffré (un seul fichier). *Coût si faux : retirer l'entrée distante (une
   ligne), ou l'ajouter à l'accueil de l'analyseur.*
3. **Place occupée par défaut** (blocs alloués, liens physiques comptés une fois), comme Baobab et `du` ; la taille
   apparente reste dans la bande d'information et les propriétés. *Coût si faux : un réglage qui choisit le champ
   lu, les deux sont déjà gardés dans l'arbre.*
4. **Parcours en Kotlin, dossier par dossier, sur `FileSource.duList`** ; le moteur ne fait qu'ajouter `alloc`,
   `ino` et `nlink` à sa liste. Un seul parcours pour toutes les sources, testé en JVM, comme la recherche de la
   phase 11 (un appel JNI par dossier). *Coût si faux (trop lent sur un disque) : un parcours natif `fl_du` qui rend
   les dossiers par lots binaires, derrière la même interface `duList`.*
5. **Arbre compact en tableaux primitifs Kotlin, borné** (500 000 nœuds, 20 fichiers par dossier, résumé au-delà) ;
   Dart ne reçoit que des vues de 1 500 nœuds et des pages de 200 enfants. Environ 60 octets par nœud, soit 30 Mio
   au pire. *Coût si faux : des constantes.*
6. **FAT et exFAT : un cluster par dossier**, sans suivre la chaîne du dossier : l'écart est de quelques clusters par
   gros dossier. *Coût si faux : suivre la chaîne dans `fat_glue.c`, une étape de T1.*
7. **Part « hors analyse »** quand tout un stockage est analysé : sur un téléphone, les applications et le système
   occupent souvent plus que les fichiers visibles, et l'utilisateur doit voir pourquoi le total ne correspond pas à
   Android. *Coût si faux : la retirer de `AnalysisViews`.*
8. **Gestes au doigt** : toucher = entrer (zoom de Baobab), glisser = bande d'information (à la place du survol),
   appui long = menu, centre des anneaux, fil d'Ariane et Retour = remonter ; profondeur par boutons, 4 niveaux par
   défaut, de 2 à 8. Pas de pincement : il entrerait en conflit avec le défilement de l'arbre. *Coût si faux : des
   constantes et un geste de plus.*
9. **Graphiques dessinés par Portail** (`CustomPainter`) : aucune bibliothèque Flutter libre ne fait à la fois les
   anneaux à plusieurs niveaux et la carte proportionnelle avec le test de toucher voulu, et la géométrie pure se
   teste sans widget. *Coût si faux : aucun, la géométrie resterait.*
10. **Résultats en mémoire seulement, trois analyses** : un arbre de 30 Mio écrit à chaque analyse userait la mémoire
    flash pour un gain faible (une réanalyse du téléphone se compte en dizaines de secondes, à mesurer en T11).
    *Coût si faux : sérialiser les tableaux de `DuTree` dans le dossier privé, une tâche.*
11. **Une analyse à la fois**, qui continue si l'on quitte l'écran, sans service au premier plan : elle s'arrête si
    Android ferme Portail. *Coût si faux : la rattacher au `VolumeService` comme les copies.*
12. **Fichiers cachés toujours comptés**, sans réglage (ils occupent la place) ; **aucun emplacement exclu par
    défaut** ; `Android/data` et `Android/obb` montrés « accès refusé par Android » plutôt que tus ; pas de passage sur
    un autre système de fichiers (`st_dev`). *Coût si faux : un réglage.*
13. **Corbeille et suppression par le chemin de l'explorateur** (`Files.delete`, dialogue extrait et partagé) ;
    l'arbre est mis à jour sans réanalyse, la place mise à la corbeille reportée sur `.Portail-corbeille` puisqu'elle
    n'est pas libérée. *Coût si faux : réanalyser après chaque action.*
14. **Couleurs** : huit teintes contrastées (≥ 3:1 contre le fond, en clair et en sombre), éclaircies avec la
    profondeur, gris pour ce qui n'est pas un dossier ou un fichier ; noms, tailles et pourcentages toujours écrits,
    l'arbre servant d'alternative complète à TalkBack.
15. **Non retenus en phase 16** : taille des applications (permission « accès aux données d'utilisation » d'Android,
    `StorageStatsManager`), recherche de doublons, comparaison de deux analyses, capture du graphique (Baobab sait
    l'enregistrer), analyse planifiée. *Coût si faux : chacun une tâche d'une phase suivante.*
16. **Numérotation** : l'analyseur prend la phase 16 (v1.9.0) à la demande de l'utilisateur ; les partitions passent
    en phase 17 (v1.10.0) et la réparation en phase 18 (v1.11.0), sans autre changement de leur contenu (spec § 26).

### Réponses de l'utilisateur (2026-10-25)

1. **Ordre** : la phase 16 commence après la fusion de la phase 15 (`feature/ia`, v1.8.0), pas en parallèle.
2. **Dossiers distants** : gardés dans l'analyseur (décision 2 inchangée : depuis l'explorateur, en taille apparente).
3. **Résultats** : en mémoire seulement (décision 10 inchangée).
4. **Taille des applications** : à prévoir dans une phase suivante, avec la permission « accès aux données
   d'utilisation » ; hors de la phase 16.

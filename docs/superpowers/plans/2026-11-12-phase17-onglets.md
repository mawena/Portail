# Portail — Phase 17 : onglets dans le module Fichiers — Plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal :** le module **Fichiers** reçoit des **onglets**, comme un navigateur : chaque onglet garde sa pile de pages
(accueil de Fichiers, explorateur, coffre ouvert dedans…), sa sélection et sa position ; une barre d'onglets apparaît en
haut dès deux onglets ; « Ouvrir dans un nouvel onglet » sur un dossier, « Nouvel onglet » et **+** ouvrent un onglet.
Fin de phase : version **v1.10.0**.

**Architecture :**
- **Modèle (T1)** : `FilesTabs` (`lib/src/state/files_tabs.dart`), un `ChangeNotifier` pur : liste des onglets, onglet
  affiché, ordre d'affichage passé (pour revenir à l'onglet d'avant), 8 au plus, et l'emplacement que montre chaque
  onglet (pile des explorateurs ouverts dedans).
- **Coquille (T2)** : `ModuleShellState` remplace le navigateur unique du module Fichiers par **un navigateur par
  onglet** (chacun masqué, sans animation ni focus quand il n'est pas affiché, avec son `HeroControllerScope`). `push`,
  Retour, le toucher du module et `moduleOf` passent par l'onglet affiché. `openInNewTab` ouvre un onglet.
- **Barre (T3)** : `FileTabBar` (`lib/src/widgets/file_tab_bar.dart`), au-dessus des pages, dès deux onglets.
- **Explorateur (T3, T4)** : il signale à son onglet le dossier qu'il montre (`FilesTabScope`), propose « Ouvrir dans un
  nouvel onglet » et « Nouvel onglet ». Un stockage qui disparaît ramène **chaque** onglet qui le montrait à son
  accueil, avec un seul message.

**Tech Stack :** Flutter 3.41, Material 3, `flutter_test` (tests d'écran avec `FakeHostApi`, images de référence).
Aucun code Kotlin, natif ni Pigeon.

**Spec :** [docs/superpowers/specs/2026-10-17-fluluks-design.md](../specs/2026-10-17-fluluks-design.md), **§ 29** (et
§ 27 pour la barre de navigation, § 19 pour l'interface et l'accessibilité).

## Global Constraints

- **Branche :** `feature/onglets`, depuis `develop` (après la v1.9.0), dans l'arbre principal. `feature/partitions`
  (devenue phase 18) reste en pause.
- **Commits :** identité `mawena <gamligocharles@gmail.com>`, Conventional Commits en français, sans aucune
  attribution ni mention d'outil d'aide à l'écriture. Chaque tâche coche ses étapes ici et sa ligne dans la feuille de
  route, dans le même commit.
- **Version :** `v1.10.0`, pubspec `1.10.0+18`.
- **Dépendances :** aucune nouvelle.
- **Code :** chaînes visibles dans `Fr` (typographie de `test/strings_test.dart` : U+00A0 avant « : », U+202F avant
  « ? ! ; ») ; jetons et composants du design system (`ui/tokens.dart`, `ui/widgets.dart`, `ui/sheets.dart`) ; jamais
  `dart format` sur `lib/` ni `test/`.
- **Valeurs fixées** *(décisions du planificateur, spec § 29)* : 8 onglets au plus ; barre dès deux onglets ; onglets
  gardés le temps de la session ; nouvel onglet sans dossier = accueil de Fichiers.
- **Tests :** `flutter test` entier vert à chaque tâche (904 tests au départ), par la file Gagarine
  (`gagarine file "portail-flutter-test" 3 4 -- flutter test`).

## Review Focus

1. **Deux onglets sur le même disque, débranché** : les deux reviennent à leur accueil, un seul message ; aucun
   explorateur ne reste sur un stockage disparu (l'explorateur actuel quitte sans dépiler quand un autre a déjà montré
   le message).
2. **Onglet masqué** : ni dessiné, ni touché, ni lu par TalkBack, ni animé ; son bouton flottant (`heroTag: null`) et
   ses `Hero` ne se mêlent pas à ceux de l'onglet affiché.
3. **Retour** : à l'accueil d'un onglet parmi plusieurs, Retour ferme l'onglet et montre celui d'avant ; jamais il ne
   quitte Portail tant qu'il reste un autre onglet.
4. **Pages plein écran** (visionneuse ouverte depuis un onglet) : elles restent au-dessus de la barre d'onglets ; un
   stockage qui disparaît ne ferme la visionneuse que si son onglet est l'onglet affiché du module à l'écran.
5. **Emplacement d'un onglet** : après la fermeture d'un coffre ouvert dans un onglet (pile explorateur du disque →
   explorateur du coffre), le libellé revient au dossier du disque, pas à « Fichiers ».

---

### Task 1 : modèle des onglets

**Files :**
- Create : `lib/src/state/files_tabs.dart`
- Test : `test/files_tabs_test.dart`

**Interfaces :**
- Produces :
  - `class TabPlace { final String sourceId; String path; }`
  - `class FileTab { final int id; final TabPlace? initial; TabPlace? get place; }` (`place` : dernier emplacement
    signalé, null sur l'accueil)
  - `class FilesTabs extends ChangeNotifier` : `static const max = 8` ; `List<FileTab> get tabs` ;
    `FileTab get active` ; `int get activeIndex` ; `bool get canOpen` ; `FileTab? open({TabPlace? at})` (null si
    plein ; l'onglet ouvert devient l'affiché) ; `void activate(FileTab t)` ; `void close(FileTab t)` (sans effet sur
    le dernier onglet ; l'affiché fermé laisse la place au précédent affiché) ; `void closeOthers(FileTab keep)` ;
    `TabPlace enter(FileTab t, String sourceId, String path)` ; `void moved(TabPlace p, String path)` ;
    `void leave(FileTab t, TabPlace p)`.
  - `enter` et `leave` sont appelés depuis `initState` et `dispose` : ils préviennent les auditeurs après l'image en
    cours (microtâche), jamais pendant la construction.

- [x] **Étape 1 : tests** — `files_tabs_test.dart` : un onglet au départ, affiché ; `open` ajoute à la fin et affiche ;
  `close` de l'affiché montre le précédent affiché (ouvrir A, B, C ; afficher A ; fermer A → C ; fermer C → B) ;
  `close` du dernier sans effet ; 8 au plus (`open` rend null, `canOpen` faux) ; `closeOthers` ; `enter`/`moved`/
  `leave` donnent `place` (pile : disque puis coffre, quitter le coffre rend le disque) ; auditeurs prévenus après
  `pump` pour `enter`/`leave`, aussitôt pour `open`/`close`/`moved`.
- [x] **Étape 2 : les voir échouer** — `flutter test test/files_tabs_test.dart` : fichier introuvable.
- [x] **Étape 3 : `FilesTabs`.**
- [x] **Étape 4 : les voir passer**, puis la suite entière.
- [x] **Étape 5 : commit** `feat(onglets): modèle des onglets du module Fichiers`.

### Task 2 : coquille, une pile de pages par onglet

**Files :**
- Modify : `lib/src/screens/module_shell.dart`
- Create : `lib/src/screens/files_tab_scope.dart` (`FilesTabScope`, `InheritedWidget` qui donne l'onglet et le modèle
  aux pages)
- Test : `test/file_tabs_test.dart`

**Interfaces :**
- Consumes : `FilesTabs`, `FileTab`, `TabPlace` (T1).
- Produces :
  - `ModuleShellState.tabs` (`FilesTabs`) ; `Future<void> openInNewTab({String? sourceId, String path = '/'})` (montre
    Fichiers ; message `Fr.tabsFull` si 8 onglets) ; `bool isShown(BuildContext context)` (vrai si la page est dans le
    module à l'écran et, pour Fichiers, dans l'onglet affiché).
  - `FilesTabScope.maybeOf(BuildContext) → FilesTabScope?` avec `tab` et `tabs`, lisible depuis `initState`.

- [x] **Étape 1 : tests** (`file_tabs_test.dart`, appli entière comme `module_shell_test.dart`) : `openInNewTab` du
  disque `/Films` → deuxième onglet affiché sur l'explorateur de `/Films`, le premier garde son dossier et sa
  sélection ; Retour à l'accueil d'un onglet parmi deux le ferme et montre l'autre ; Retour au dernier onglet garde le
  § 27 ; toucher Fichiers ramène l'onglet affiché à son accueil sans toucher l'autre ; onglet masqué hors de l'arbre
  sémantique et sans `Ticker` actif ; depuis Coffres, `openInNewTab` montre Fichiers ; neuvième onglet refusé avec le
  message.
- [x] **Étape 2 : les voir échouer.**
- [x] **Étape 3 : un `Navigator` par onglet** (clés et `HeroController` par identifiant d'onglet, oubliés à la
  fermeture ; `onGenerateInitialRoutes` : accueil, puis l'explorateur de `initial` s'il y en a un) ; `push`, `_tap`,
  `_back`, `moduleOf`, `isShown`.
- [x] **Étape 4 : les voir passer**, puis la suite entière (`module_shell_test.dart` inchangé).
- [x] **Étape 5 : commit** `feat(onglets): une pile de pages par onglet dans le module Fichiers`.

### Task 3 : barre d'onglets

**Files :**
- Create : `lib/src/widgets/file_tab_bar.dart`
- Modify : `lib/src/screens/module_shell.dart` (barre au-dessus des pages de Fichiers, marge du haut prise par elle),
  `lib/src/screens/explorer_screen.dart` (`enter`/`moved`/`leave`), `lib/src/strings_fr.dart`,
  `test/screen_harness.dart`, `test/goldens_test.dart`
- Test : `test/file_tabs_test.dart`, images `test/goldens/file_tabs_light.png` et `file_tabs_dark.png`

**Interfaces :**
- Consumes : `FilesTabs`, `FilesTabScope` (T1, T2), `sourceIcon(kind)` (`widgets/source_tile.dart`).
- Produces : `FileTabBar({required AppState state, required FilesTabs tabs, required VoidCallback onNew})` ;
  `Fr.newTab`, `Fr.openInNewTab`, `Fr.openFolderInNewTab`, `Fr.closeTab`, `Fr.closeOtherTabs`,
  `Fr.closeTabNamed(String)`, `Fr.tabLabel(int i, int n, String name)`, `Fr.tabsFull`.

- [x] **Étape 1 : tests** : un seul onglet, pas de barre ; deux onglets, barre au-dessus de la barre de titre ; libellé
  = nom du dossier, nom du stockage à sa racine, « Fichiers » à l'accueil, suit la navigation dans l'explorateur et
  revient au dossier du disque après la fermeture d'un coffre ouvert dedans ; toucher un onglet l'affiche ; croix ;
  **+** ouvre l'accueil, grisé à 8 ; appui long : Fermer l'onglet, Fermer les autres onglets ; TalkBack « Onglet 2
  sur 3, Films », sélectionné ; croix « Fermer l'onglet Films » ; cibles ≥ 48 dp ; texte à 200 % sans débordement ;
  images de référence en clair et en sombre ; chaînes au banc typographique.
- [x] **Étape 2 : les voir échouer.**
- [x] **Étape 3 : `FileTabBar`** (liste horizontale défilante, l'onglet affiché ramené en vue), signalement de
  l'emplacement par l'explorateur.
- [x] **Étape 4 : les voir passer**, images de référence générées puis relues, suite entière.
- [x] **Étape 5 : commit** `feat(onglets): barre d'onglets du module Fichiers`.

### Task 4 : points d'entrée et stockage qui disparaît

**Files :**
- Modify : `lib/src/screens/explorer_screen.dart`, `lib/src/widgets/found_entries.dart`
- Test : `test/file_tabs_test.dart`, `test/explorer_screen_test.dart`

**Interfaces :**
- Consumes : `ModuleShellState.openInNewTab`, `isShown` (T2), chaînes de T3.

- [x] **Étape 1 : tests** : menu ⋮ d'un dossier → « Ouvrir dans un nouvel onglet » (absent pour un fichier et hors de
  la coquille) ; menu de l'explorateur → « Nouvel onglet » (accueil) ; feuille d'un résultat de recherche → dossier
  ouvert dans un nouvel onglet (le dossier qui contient un fichier) ; deux onglets sur le même disque, disque retiré →
  les deux à leur accueil, un seul message ; visionneuse ouverte depuis l'onglet affiché fermée, pas celle d'un autre
  module.
- [x] **Étape 2 : les voir échouer.**
- [x] **Étape 3 : actions et `_onState`** : chaque explorateur dépile son propre navigateur ; le message reste unique
  (`takeClosedNotice`) ; la visionneuse n'est fermée que si `isShown(context)`.
- [x] **Étape 4 : les voir passer**, suite entière.
- [x] **Étape 5 : commit** `feat(onglets): ouvrir un dossier dans un nouvel onglet`.

### Task 5 : documentation

- [x] README : section « Onglets (nouveau en 1.10.0) », état actuel ; aide : une question ; CHANGELOG (section 1.10.0
  à la version) ; fiche d'essai `docs/superpowers/research/2026-11-12-essais-phase17/essais.md`, copiée sur le
  téléphone.
- [x] Commit `docs(onglets): README, aide et fiche d'essai de la phase 17`.

### Task 6 *(utilisateur)* : essais sur le Pixel

- [x] APK installé (sauvegarde de l'APK en place d'abord), fiche suivie : copie d'un dossier du téléphone vers un
  disque USB par deux onglets, coffre ouvert dans un onglet, débranchement avec deux onglets sur le disque, TalkBack,
  texte à 200 %, paysage (rail).

### Fin de phase

- [x] Relecture finale de toute la branche.
- [ ] Fusion `feature/onglets` → `develop`, puis `release/1.10.0` (pubspec `1.10.0+18`), `main`, étiquette signée
  `v1.10.0`, push de `main`, `develop` et des étiquettes, release GitHub avec l'APK et son `.sha256`.

## Décisions du planificateur

1. **Un navigateur par onglet, à l'intérieur du module Fichiers**, plutôt que des onglets dans l'explorateur : tout ce
   qui s'ouvre dans Fichiers (accueil, explorateur, coffre ouvert dedans, recherche, corbeille) appartient à un onglet,
   et un nouvel onglet commence à l'accueil comme la page d'accueil d'un navigateur. *Coût si faux : la barre se
   déplace dans l'explorateur, le modèle reste.*
2. **Barre en haut, au-dessus de la barre de titre**, comme les onglets d'un navigateur de bureau, et seulement dès
   deux onglets. *Coût si faux : déplacer un widget.*
3. **8 onglets au plus** : chaque explorateur garde sa liste et son cache de vignettes en mémoire. *Coût si faux : une
   constante.*
4. **Pas d'onglets rouverts au démarrage** : disques et coffres demanderaient d'être rebranchés ou déverrouillés.
   *Coût si faux : sauver les emplacements du téléphone et des cartes SD dans les réglages.*

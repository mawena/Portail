
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';

import '../bridge/fluluks_api.g.dart';
import '../strings_fr.dart';
import '../terminal/terminal_hub.dart';
import 'host_api.dart';

/// État de l'interface : copie de ce que le côté Kotlin publie. Ne contient jamais de phrase de passe.
class AppState extends ChangeNotifier implements FluLuksEventsApi {
  /// [api] : l'API hôte (ou un faux dans les tests).
  AppState(this.api);

  final HostApi api;

  /// Terminaux SSH ouverts (phase 13), gardés hors des écrans.
  late final terminals = TerminalHub(api, onBell: _bell);

  void _bell() {
    if (uiPrefs.haptics) HapticFeedback.vibrate();
  }

  List<DiskMsg> _disks = const [];
  List<VolumeMsg> _volumes = const [];
  String? _lastError;
  bool _readOnlyPreference = false;
  int _autoLockMinutes = 0;
  bool _ejecting = false;
  String? _ejectError;
  List<SourceMsg> _sources = const [];
  List<VaultMsg> _vaults = const [];
  String? _biometricUnavailable;
  List<RemoteServerMsg> _servers = const [];
  bool _allFilesAccess = false;
  TransferMsg? _transfer;
  int? _formatProgress;
  int? _hashProgress;
  PlayerMsg? _player;
  String? _playerMessage;
  ViewPrefsMsg _viewPrefs = ViewPrefsMsg(sort: 'name', ascending: true, grid: false, showHidden: false, builtInViewers: true);
  final _uiPrefs = ValueNotifier(UiPrefsMsg(theme: 'system', haptics: true, welcomeSeen: false));
  List<FavoriteMsg> _favorites = const [];
  ClipboardItems? _clipboard;
  PendingExtract? _pendingExtract;
  final _closedNoticed = <String>{}; // stockages disparus dont la fermeture a déjà été annoncée
  (String, String)? _transferDestination;

  /// Vues déchiffrées ouvertes (phase 14) et le stockage de leur fichier chiffré.
  final _decrypted = <String, (SourceMsg, String)>{};

  /// Écrans qui demandent FLAG_SECURE (terminal masqué, coffre parcouru avec le réglage) ; [_secureApplied] : état
  /// demandé à Android.
  int _secureHolds = 0;
  bool _secureApplied = false;
  ({String dstId, String dstDir, String format, bool single})? _lastEncrypt;

  List<DiskMsg> get disks => _disks;
  List<VolumeMsg> get volumes => _volumes;

  /// Stockages du gestionnaire de fichiers : téléphone, cartes SD, volumes ouverts.
  List<SourceMsg> get sources => _sources;

  /// Coffres connus (phase 14) : fermés, ouverts ou indisponibles.
  List<VaultMsg> get vaults => _vaults;

  /// Raison pour laquelle la biométrie forte n'est pas utilisable (null : elle l'est).
  String? get biometricUnavailable => _biometricUnavailable;

  /// Serveurs distants enregistrés (phase 10).
  List<RemoteServerMsg> get servers => _servers;

  /// Tri, grille et fichiers cachés (persistés côté Kotlin).
  ViewPrefsMsg get viewPrefs => _viewPrefs;

  /// Thème, retours haptiques et bienvenue vue (phase 11, persistés côté Kotlin).
  UiPrefsMsg get uiPrefs => _uiPrefs.value;

  /// Prévient seulement des changements de [uiPrefs] : la racine de l'application ne se reconstruit pas à chaque
  /// progression de copie.
  ValueListenable<UiPrefsMsg> get uiPrefsListenable => _uiPrefs;

  /// Favoris, résolus vers les stockages ouverts (`sourceId` null sinon).
  List<FavoriteMsg> get favorites => _favorites;

  FavoriteMsg? favoriteFor(String sourceId, String path) {
    final key = sourceById(sourceId)?.stableKey;
    for (final f in _favorites) {
      if (f.key == key && f.path == path) return f;
    }
    return null;
  }

  /// Éléments copiés ou coupés, en attente de « Coller ici » ; null si vide.
  ClipboardItems? get clipboard => _clipboard;

  void setClipboard(String sourceId, List<String> paths, {required bool move}) {
    _clipboard = ClipboardItems(sourceId, List.unmodifiable(paths), move);
    _pendingExtract = null; // une seule action en attente dans la barre
    notifyListeners();
  }

  void clearClipboard() {
    _clipboard = null;
    notifyListeners();
  }

  /// Archive en attente d'un dossier de destination (« Extraire vers… ») ; null sinon.
  PendingExtract? get pendingExtract => _pendingExtract;

  void setPendingExtract(String sourceId, String path) {
    _pendingExtract = PendingExtract(sourceId, path);
    _clipboard = null;
    notifyListeners();
  }

  void clearPendingExtract() {
    _pendingExtract = null;
    notifyListeners();
  }

  /// (source, dossier) où écrit la dernière copie lancée : l'explorateur qui l'affiche se rafraîchit.
  (String, String)? get transferDestination => _transferDestination;

  /// Copie ou déplacement en cours, ou le dernier terminé ; null si aucun.
  TransferMsg? get transfer => _transfer;

  /// Pourcentage du formatage en cours (null sinon).
  int? get formatProgress => _formatProgress;

  /// Pourcentage du calcul d'empreinte SHA-256 en cours (null sinon).
  int? get hashProgress => _hashProgress;

  /// Le résultat d'une opération finie a été montré : plus aucun écran ne le réaffiche.
  void transferResultSeen() {
    if (_transfer?.finished != true) return;
    _transfer = null;
    notifyListeners();
  }

  /// Accès à tous les fichiers du téléphone accordé.
  bool get allFilesAccess => _allFilesAccess;

  SourceMsg? sourceById(String id) {
    for (final s in _sources) {
      if (s.id == id) return s;
    }
    return _decrypted[id]?.$1;
  }

  /// « Ouvrir les disques en lecture seule » : tout nouveau montage se fait alors sans écriture.
  bool get readOnlyPreference => _readOnlyPreference;

  /// Verrouillage automatique des disques chiffrés, en minutes (0 = jamais).
  int get autoLockMinutes => _autoLockMinutes;

  /// Éjection en cours (données en attente écrites, démontage) : les boutons sont désactivés.
  bool get ejecting => _ejecting;

  /// « Éjection impossible : … », ou null.
  String? get ejectError => _ejectError;

  /// Dernière erreur d'action (affichée en bandeau), ou null.
  String? get lastError => _lastError;

  void clearError() {
    _lastError = null;
    notifyListeners();
  }

  VolumeMsg? volumeById(String id) {
    for (final v in _volumes) {
      if (v.id == id) return v;
    }
    return null;
  }

  /// Préférences d'interface seules, lues avant le premier rendu : thème et bienvenue justes dès la première image.
  /// Un échec garde les valeurs par défaut ; [refresh] relit tout ensuite.
  Future<void> loadUiPrefs() async {
    try {
      _uiPrefs.value = await api.getUiPrefs();
    } on PlatformException {
      // valeurs par défaut
    }
  }

  /// Version de Portail et appareil, pour « À propos ».
  Future<AppInfoMsg> appInfo() => api.getAppInfo();

  /// Chargement initial (Kotlin pousse ensuite chaque changement via [onStateChanged]).
  Future<void> refresh() async {
    try {
      _disks = await api.listDisks();
      _volumes = await api.listVolumes();
      _readOnlyPreference = await api.getReadOnlyPreference();
      _autoLockMinutes = await api.getAutoLockMinutes();
      _sources = await api.listSources();
      _allFilesAccess = await api.hasAllFilesAccess();
      _viewPrefs = await api.getViewPrefs();
      _uiPrefs.value = await api.getUiPrefs();
      _favorites = await api.listFavorites();
      _servers = await api.listServers();
      _vaults = await api.listVaults();
      _biometricUnavailable = await api.biometricUnavailable();
      notifyListeners();
      await terminals.restore(); // sessions gardées par le service pendant que l'application était fermée
    } on PlatformException catch (e) {
      _fail(e);
    }
  }

  /// Connecte un serveur distant (erreurs `auth`, `hostkey-unknown`, `hostkey-changed` rendues telles quelles) ;
  /// rend sa source.
  Future<SourceMsg> connectServer(String id, Uint8List? password) async {
    final s = await api.connectServer(id, password);
    await refreshSources();
    return s;
  }

  Future<void> disconnectServer(String id) async {
    await api.disconnectServer(id);
    await refreshSources();
  }

  Future<RemoteServerMsg> saveServer(RemoteServerMsg s, Uint8List? password, {Uint8List? keyPassphrase}) async {
    final saved = await api.saveServer(s, password, keyPassphrase);
    await refreshSources();
    return saved;
  }

  Future<void> deleteServer(String id) async {
    await api.deleteServer(id);
    await refreshSources();
  }

  Future<void> trustHostKey(String id, String fingerprint) => api.trustHostKey(id, fingerprint);

  /// « Tester la connexion » (phase 13) : mêmes erreurs que [connectServer] ; rend le journal de la tentative.
  Future<List<String>> testServer(String id, Uint8List? password) => api.testServer(id, password);

  /// Journal de la dernière tentative de connexion de [id], pour « Détails ».
  Future<List<String>> lastAttemptLog(String id) => api.lastAttemptLog(id);

  Future<void> forgetHostKey(String id) async {
    await api.forgetHostKey(id);
    await refreshSources();
  }

  /// Clé privée choisie dans le sélecteur d'Android ; sa description, ou null si rien n'a été choisi.
  Future<String?> importPrivateKey(String id) async {
    final info = await api.importPrivateKey(id);
    if (info != null) await refreshSources();
    return info;
  }

  Future<void> forgetPrivateKey(String id) async {
    await api.forgetPrivateKey(id);
    await refreshSources();
  }

  /// Phase 13 : le serveur [serverId] utilise la clé [keyId] du trousseau (null : aucune).
  Future<void> setServerKey(String serverId, String? keyId) async {
    await api.setServerKey(serverId, keyId);
    await refreshSources();
  }

  @override
  void onStateChanged(List<DiskMsg> disks, List<VolumeMsg> volumes, List<VaultMsg> vaults) {
    _disks = disks;
    _volumes = volumes;
    _vaults = vaults;
    notifyListeners();
    refreshSources(); // un volume ouvert ou fermé ajoute ou retire un stockage
  }

  /// Vrai la première fois seulement qu'on annonce la disparition de [sourceId] (un message, même avec
  /// plusieurs explorateurs ouverts dessus).
  bool takeClosedNotice(String sourceId) => _closedNoticed.add(sourceId);

  /// Relit les stockages, l'accès aux fichiers et les favoris (changement d'état, retour au premier plan).
  /// Un stockage disparu vide le presse-papiers qui le désigne et le cache d'images décodées (vignettes).
  Future<void> refreshSources() async {
    try {
      final before = _sources.map((s) => s.id).toSet();
      _sources = await api.listSources();
      final now = _sources.map((s) => s.id).toSet();
      _closedNoticed.removeAll(now);
      if (before.difference(now).isNotEmpty) {
        if (_clipboard != null && !now.contains(_clipboard!.sourceId)) _clipboard = null;
        if (_pendingExtract != null && !now.contains(_pendingExtract!.sourceId)) _pendingExtract = null;
        _decrypted.removeWhere((_, v) => !now.contains(v.$2)); // retirées côté Kotlin avec leur stockage
        _applySecure();
        PaintingBinding.instance.imageCache.clear();
      }
      _allFilesAccess = await api.hasAllFilesAccess();
      _favorites = await api.listFavorites();
      _servers = await api.listServers();
      _vaults = await api.listVaults();
      notifyListeners();
    } on PlatformException catch (e) {
      _fail(e);
    }
  }

  Future<void> requestAllFilesAccess() => _guard(() => api.requestAllFilesAccess());

  @override
  void onEjectStateChanged(bool ejecting, String? error) {
    _ejecting = ejecting;
    _ejectError = error;
    notifyListeners();
  }

  @override
  void onFormatProgress(int? pct) {
    _formatProgress = pct;
    notifyListeners();
  }

  @override
  void onHashProgress(int? pct) {
    _hashProgress = pct;
    notifyListeners();
  }

  int _editorHolds = 0;

  /// Un éditeur ouvert avec des modifications retient le retour à l'accueil des explorateurs d'un stockage disparu :
  /// le texte reste à l'écran jusqu'à ce qu'on le quitte.
  bool get editorHolding => _editorHolds > 0;

  void holdForEditor() => _editorHolds++;

  void releaseEditor() {
    _editorHolds--;
    notifyListeners();
  }

  /// Musique en cours (phase 10), ou null.
  PlayerMsg? get player => _player;

  /// Invites keyboard-interactive des serveurs SSH en attente (phase 13), posées une à une par le cadre de
  /// l'application.
  final _sshPrompts = <SshPromptMsg>[];

  /// Prochaine invite à poser, rendue une seule fois.
  SshPromptMsg? takeSshPrompt() => _sshPrompts.isEmpty ? null : _sshPrompts.removeAt(0);

  @override
  void onSshPrompt(SshPromptMsg prompt) {
    _sshPrompts.add(prompt);
    notifyListeners();
  }

  /// Sortie et états des terminaux SSH (phase 13), confiés au hub des terminaux.
  @override
  void onTerminalOutput(String sessionId, Uint8List data) => terminals.onOutput(sessionId, data);

  @override
  void onTerminalChanged(TerminalSessionMsg session) => terminals.onChanged(session);

  /// Réponses à l'invite [requestId] (null : refusée) ; remises à zéro ici après l'envoi.
  Future<void> answerSshPrompt(String requestId, List<Uint8List>? answers) async {
    try {
      await api.answerSshPrompt(requestId, answers);
    } finally {
      for (final a in answers ?? const <Uint8List>[]) {
        a.fillRange(0, a.length, 0);
      }
    }
  }

  /// Raison du dernier arrêt subi de la musique, rendue une seule fois.
  String? takePlayerMessage() {
    final m = _playerMessage;
    _playerMessage = null;
    return m;
  }

  @override
  void onPlayerChanged(PlayerMsg? player, String? message) {
    _player = player;
    if (message != null) _playerMessage = message;
    notifyListeners();
  }

  /// Lit les sons de [paths] (le dossier dans l'ordre affiché), à partir de `paths[startIndex]`.
  Future<void> playAudio(String sourceId, List<String> paths, int startIndex) =>
      _guard(() => api.playAudio(sourceId, paths, startIndex));

  /// `play`, `pause`, `next`, `previous`, `back`, `forward`, `seek` ([positionMs]) ou `stop`.
  Future<void> playerCommand(String command, {int? positionMs}) => _guard(() => api.playerCommand(command, positionMs));

  @override
  void onTransferChanged(TransferMsg? transfer) {
    _transfer = transfer;
    notifyListeners();
  }

  Future<void> startTransfer(String srcId, List<String> paths, String dstId, String dstDir, {required bool move}) =>
      _guard(() async {
        await api.startTransfer(srcId, paths, dstId, dstDir, move);
        _transferDestination = (dstId, dstDir);
      });

  /// Compresse [paths] dans le ZIP [name] sous [dstDir] du même stockage.
  Future<void> startCompress(String srcId, List<String> paths, String dstDir, String name) => _guard(() async {
        await api.startCompress(srcId, paths, dstDir, name);
        _transferDestination = (srcId, dstDir);
      });

  /// Extrait [archive] sous [dstDir] de [dstId], dans un nouveau dossier au nom de l'archive si [intoNewFolder] ;
  /// [password] pour une archive protégée (mis à zéro par l'appelant).
  Future<void> startExtract(String srcId, String archive, String dstId, String dstDir,
          {required bool intoNewFolder, Uint8List? password}) =>
      _guard(() async {
        await api.startExtract(srcId, archive, dstId, dstDir, intoNewFolder, password: password);
        _transferDestination = (dstId, dstDir);
      });

  // ---------------------------------------------------------------- chiffrement (phase 14)

  /// Dernier chiffrement lancé : où il écrit, son format, et s'il produit un seul fichier (à partager ensuite).
  ({String dstId, String dstDir, String format, bool single})? get lastEncrypt => _lastEncrypt;

  /// Chiffre [paths] (format `age` ou `zip`) ; [password] est mis à zéro par l'appelant.
  Future<void> startEncrypt(String srcId, List<String> paths, String dstId, String dstDir,
          {required String format, required bool together, String? name, required bool deleteOriginal,
          required Uint8List password}) =>
      _guard(() async {
        await api.startEncrypt(srcId, paths, dstId, dstDir, format, together, name, deleteOriginal, password);
        _transferDestination = (dstId, dstDir);
        _lastEncrypt = (dstId: dstId, dstDir: dstDir, format: format, single: together || paths.length == 1);
      });

  Future<void> startDecrypt(String srcId, String path, String dstId, String dstDir,
          {required bool extractFolder, required Uint8List password}) =>
      _guard(() async {
        await api.startDecrypt(srcId, path, dstId, dstDir, extractFolder, password);
        _transferDestination = (dstId, dstDir);
      });

  Future<void> startVerify(String srcId, String path, Uint8List password) =>
      _guard(() => api.startVerify(srcId, path, password));

  /// Change le mot de passe d'un fichier `.age` ; erreur `badPassword` rendue telle quelle.
  Future<void> changeFilePassword(String srcId, String path, Uint8List oldPassword, Uint8List newPassword) =>
      api.changeFilePassword(srcId, path, oldPassword, newPassword);

  /// Ouvre une vue déchiffrée de [path] ; erreur `badPassword` rendue telle quelle.
  Future<SourceMsg> openDecrypted(String srcId, String path, Uint8List password) async {
    final s = await api.openDecrypted(srcId, path, password);
    _decrypted[s.id] = (s, srcId);
    _applySecure();
    return s;
  }

  Future<void> closeDecrypted(String id) async {
    if (_decrypted.remove(id) == null) return;
    _applySecure();
    try {
      await api.closeDecrypted(id);
    } on PlatformException {
      // déjà fermée avec son stockage
    }
  }

  VaultMsg? vaultById(String id) {
    for (final v in _vaults) {
      if (v.id == id) return v;
    }
    return null;
  }

  /// Crée un coffre (progression par [transfer], type `vault`) ; lève [PlatformException] en cas d'échec ou
  /// d'annulation. [password] est mis à zéro après l'appel, sur tous les chemins.
  Future<VaultMsg> createVault(String srcId, String dir, String name, int sizeBytes, String fs, Uint8List password) async {
    try {
      _transferDestination = (srcId, dir);
      final v = await api.createVault(srcId, dir, name, sizeBytes, fs, password);
      await refreshSources();
      return v;
    } finally {
      password.fillRange(0, password.length, 0);
    }
  }

  /// Ouvre un coffre connu ([vaultId]) ou le fichier [path] de [srcId] ; rend son volume (le stockage du coffre a
  /// le même identifiant). Erreur `badPassword` rendue telle quelle ; [password] mis à zéro après l'appel.
  Future<VolumeMsg> openVault({String? vaultId, String? srcId, String? path, required Uint8List password,
      required bool writable, bool recovery = false}) async {
    try {
      final v = await api.openVault(vaultId, srcId, path, password, writable, recovery: recovery);
      await refresh();
      return v;
    } finally {
      password.fillRange(0, password.length, 0);
    }
  }

  /// Change le mot de passe d'un coffre fermé ([oldPassword] : mot de passe ou clé de secours). Lève
  /// [PlatformException] ; les deux tableaux sont mis à zéro après l'appel.
  Future<void> changeVaultPassword(String id, Uint8List oldPassword, Uint8List newPassword) async {
    try {
      await api.changeVaultPassword(id, oldPassword, newPassword);
    } finally {
      oldPassword.fillRange(0, oldPassword.length, 0);
      newPassword.fillRange(0, newPassword.length, 0);
    }
  }

  /// Crée la clé de secours d'un coffre fermé et la rend (l'appelant la montre une fois, puis la met à zéro).
  Future<Uint8List> addRecoveryKey(String id, Uint8List password) async {
    try {
      final k = await api.addRecoveryKey(id, password);
      await refreshSources();
      return k;
    } finally {
      password.fillRange(0, password.length, 0);
    }
  }

  Future<void> removeRecoveryKey(String id, Uint8List password) async {
    try {
      await api.removeRecoveryKey(id, password);
      await refreshSources();
    } finally {
      password.fillRange(0, password.length, 0);
    }
  }

  /// Active le déverrouillage biométrique (invite biométrique côté Android) ; erreur `biometricCancelled` si elle est
  /// annulée. [password] est mis à zéro.
  Future<void> enableBiometric(String id, Uint8List password) async {
    try {
      await api.enableBiometric(id, password);
      await refreshSources();
    } finally {
      password.fillRange(0, password.length, 0);
    }
  }

  /// Ouvre le coffre par la biométrie ; erreurs `biometricCancelled` et `biometricInvalidated` rendues telles quelles.
  Future<VolumeMsg> openVaultBiometric(String id, {required bool writable}) async {
    try {
      final v = await api.openVaultBiometric(id, writable);
      await refresh();
      return v;
    } on PlatformException {
      await refreshSources(); // biométrie peut-être désactivée
      rethrow;
    }
  }

  Future<void> disableBiometric(String id, Uint8List? password) async {
    try {
      await api.disableBiometric(id, password);
      await refreshSources();
    } finally {
      password?.fillRange(0, password.length, 0);
    }
  }

  /// Ferme le coffre (synchronisé, démonté, clé effacée).
  Future<void> closeVault(String id) => _guard(() async {
        await api.closeVault(id);
        await refresh();
      });

  /// Retire le coffre de la liste ; son fichier n'est pas touché.
  Future<void> forgetVault(String id) => _guard(() async {
        await api.forgetVault(id);
        await refresh();
      });

  Future<void> cancelTransfer() => _guard(() => api.cancelTransfer());

  Future<void> setViewPrefs(ViewPrefsMsg prefs) => _guard(() async {
        await api.setViewPrefs(prefs);
        _viewPrefs = prefs;
        notifyListeners();
      });

  Future<void> setUiPrefs(UiPrefsMsg prefs) => _guard(() async {
        await api.setUiPrefs(prefs);
        _uiPrefs.value = prefs;
        _applySecure();
        notifyListeners();
      });

  /// Réglage « Masquer les coffres et les fichiers déchiffrés » (phase 14).
  bool get hideVaults => uiPrefs.hideVaults ?? false;

  /// Masque l'application dans les captures et les applications récentes tant que [releaseSecure] n'a pas été
  /// appelé autant de fois (terminal masqué, coffre parcouru) ; une vue déchiffrée ouverte masque aussi, si
  /// [hideVaults].
  void holdSecure() {
    _secureHolds++;
    _applySecure();
  }

  void releaseSecure() {
    if (_secureHolds > 0) _secureHolds--;
    _applySecure();
  }

  void _applySecure() {
    final want = _secureHolds > 0 || (hideVaults && _decrypted.isNotEmpty);
    if (want == _secureApplied) return;
    _secureApplied = want;
    api.setSecureScreen(want).catchError((_) {}); // sans activité (tests, arrière-plan) : rien à masquer
  }

  Future<void> addFavorite(String sourceId, String path, String label) => _guard(() async {
        await api.addFavorite(sourceId, path, label);
        _favorites = await api.listFavorites();
        notifyListeners();
      });

  Future<void> removeFavorite(String key, String path) => _guard(() async {
        await api.removeFavorite(key, path);
        _favorites = await api.listFavorites();
        notifyListeners();
      });

  Future<void> setAutoLockMinutes(int minutes) => _guard(() async {
        await api.setAutoLockMinutes(minutes);
        _autoLockMinutes = minutes;
        notifyListeners();
      });

  Future<void> setReadOnlyPreference(bool value) => _guard(() async {
        await api.setReadOnlyPreference(value);
        _readOnlyPreference = value;
        notifyListeners();
      });

  Future<void> requestPermission(String diskId) => _guard(() => api.requestPermission(diskId));

  Future<void> mountPlain(String diskId, int partIndex) =>
      _guard(() async {
        await api.mountPlain(diskId, partIndex, !_readOnlyPreference);
        await refresh();
      });

  Future<void> eject(String volumeId) => _guard(() => api.eject(volumeId));

  Future<void> openInFiles(String volumeId) => _guard(() => api.openInFiles(volumeId));

  /// Lève [PlatformException] en cas d'échec (message français, jamais de phrase de passe).
  /// L'appelant garde la responsabilité de mettre [passphrase] à zéro. [writable] : écriture demandée
  /// (le moteur peut la refuser : le volume dit alors pourquoi il est en lecture seule).
  Future<void> unlock(String diskId, int partIndex, Uint8List passphrase, {required bool writable}) async {
    await api.unlock(diskId, partIndex, passphrase, writable);
    await refresh();
  }

  /// Formate tout le disque ; rend null, ou le message d'erreur (affiché par l'écran de formatage). La
  /// phrase de passe est mise à zéro après l'appel, sur tous les chemins.
  Future<String?> formatDisk(String diskId, String fs, bool encrypted, String label, Uint8List? passphrase) async {
    try {
      await api.formatDisk(diskId, fs, encrypted, label, passphrase);
      await refresh();
      return null;
    } on PlatformException catch (e) {
      return e.message ?? Fr.genericError;
    } finally {
      passphrase?.fillRange(0, passphrase.length, 0);
    }
  }

  Future<void> _guard(Future<void> Function() action) async {
    try {
      _lastError = null;
      await action();
    } on PlatformException catch (e) {
      _fail(e);
    }
  }

  void _fail(PlatformException e) {
    _lastError = e.message ?? Fr.genericError;
    notifyListeners();
  }
}

/// Archive choisie par « Extraire vers… », extraite par « Extraire ici » dans le dossier ouvert ensuite.
class PendingExtract {
  const PendingExtract(this.sourceId, this.path);

  final String sourceId;
  final String path;
}

/// Contenu du presse-papiers de l'explorateur.
class ClipboardItems {
  const ClipboardItems(this.sourceId, this.paths, this.move);

  final String sourceId;
  final List<String> paths;
  final bool move;
}

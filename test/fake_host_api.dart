import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:fluluks/src/bridge/fluluks_api.g.dart';
import 'package:fluluks/src/state/host_api.dart';

PartitionMsg part({
  int index = 1,
  int size = 2000000000,
  String content = 'LUKS2',
  String label = '',
  bool supported = true,
  bool encrypted = true,
  String? volumeId,
}) =>
    PartitionMsg(
      index: index,
      sizeBytes: size,
      content: content,
      label: label,
      supported: supported,
      encrypted: encrypted,
      volumeId: volumeId,
    );

DiskMsg disk(List<PartitionMsg> parts, {String id = 'd1'}) => DiskMsg(
      id: id,
      name: 'Disque USB',
      sizeBytes: 4000000000,
      hasPermission: true,
      partitions: parts,
    );

VolumeMsg volume({String id = 'v1', bool readOnly = false, String roReason = ''}) => VolumeMsg(
      id: id,
      diskId: 'd1',
      partIndex: 1,
      title: 'Données',
      totalBytes: 1000,
      freeBytes: 500,
      needsRecovery: false,
      roReason: roReason,
      readOnly: readOnly,
    );

/// Faux pont : enregistre les appels. Les octets de phrase de passe sont copiés à l'appel, et la
/// référence d'origine est gardée pour vérifier qu'elle est mise à zéro ensuite.
class FakeHostApi implements HostApi {
  List<DiskMsg> disks = [];
  List<VolumeMsg> volumes = [];
  final ejected = <String>[];
  final mounted = <(String, int, bool)>[];
  final unlockWritable = <bool>[];
  bool readOnlyPreference = false;
  final permissionRequests = <String>[];
  Uint8List? passphraseRef;
  List<int>? passphraseCopy;

  /// Formatages demandés : (disque, fs, chiffré, étiquette, phrase copiée).
  final formats = <(String, String, bool, String, String?)>[];
  Uint8List? formatPassRef;
  String? formatError;
  Completer<void>? formatGate;

  @override
  Future<void> formatDisk(String diskId, String fs, bool encrypted, String label, Uint8List? passphrase) async {
    formatPassRef = passphrase;
    formats.add((diskId, fs, encrypted, label, passphrase == null ? null : utf8.decode(List<int>.of(passphrase))));
    if (formatGate != null) await formatGate!.future;
    if (formatError != null) throw PlatformException(code: '-14', message: formatError);
  }

  /// Si non nul, unlock attend ce completer (test de l'état « en cours »).
  Completer<void>? gate;
  String correctPassphrase = 'bonne';

  @override
  Future<List<DiskMsg>> listDisks() async => disks;

  @override
  Future<List<VolumeMsg>> listVolumes() async => volumes;

  @override
  Future<void> requestPermission(String diskId) async => permissionRequests.add(diskId);

  @override
  Future<VolumeMsg> unlock(String diskId, int partIndex, Uint8List passphrase, bool writable) async {
    unlockWritable.add(writable);
    passphraseRef = passphrase;
    passphraseCopy = List<int>.of(passphrase);
    if (gate != null) await gate!.future;
    if (utf8.decode(passphraseCopy!) != correctPassphrase) {
      throw PlatformException(code: '-5', message: 'phrase de passe incorrecte');
    }
    return volume();
  }

  @override
  Future<VolumeMsg> mountPlain(String diskId, int partIndex, bool writable) async {
    mounted.add((diskId, partIndex, writable));
    return volume();
  }

  @override
  Future<void> eject(String volumeId) async => ejected.add(volumeId);

  @override
  Future<void> openInFiles(String volumeId) async => calls.add('openInFiles $volumeId');

  @override
  Future<bool> getReadOnlyPreference() async => readOnlyPreference;

  @override
  Future<void> setReadOnlyPreference(bool value) async => readOnlyPreference = value;

  int autoLockMinutes = 0;
  @override
  Future<int> getAutoLockMinutes() async => autoLockMinutes;
  @override
  Future<void> setAutoLockMinutes(int minutes) async => autoLockMinutes = minutes;

  List<SourceMsg> sources = [];
  bool allFilesAccess = true;
  int accessRequests = 0;

  @override
  Future<List<SourceMsg>> listSources() async => sources;

  @override
  Future<bool> hasAllFilesAccess() async => allFilesAccess;

  @override
  Future<void> requestAllFilesAccess() async => accessRequests++;

  /// Contenu des dossiers, par `sourceId` puis chemin ; un chemin dans [protectedDirs] est refusé.
  final dirs = <String, Map<String, List<EntryMsg>>>{};
  final protectedDirs = <String>{};
  final calls = <String>[];

  @override
  Future<List<EntryMsg>> listDir(String sourceId, String path, bool showHidden) async {
    calls.add('listDir $sourceId $path $showHidden');
    if (protectedDirs.contains(path)) {
      throw PlatformException(code: '-1', message: 'Dossier protégé par Android');
    }
    final l = dirs[sourceId]?[path] ?? const <EntryMsg>[];
    return showHidden ? l : l.where((e) => !e.name.startsWith('.')).toList();
  }

  @override
  Future<String> createFolder(String sourceId, String parent, String name) async {
    calls.add('createFolder $sourceId $parent $name');
    return parent == '/' ? '/$name' : '$parent/$name';
  }

  @override
  Future<String> rename(String sourceId, String path, String newName) async {
    calls.add('rename $sourceId $path $newName');
    return '${path.substring(0, path.lastIndexOf('/'))}/$newName';
  }

  /// « delete … » : définitif ; « trash … » : mis à la corbeille.
  @override
  Future<void> deleteEntries(String sourceId, List<String> paths, bool permanent) async =>
      calls.add('${permanent ? 'delete' : 'trash'} $sourceId ${paths.join(',')}');

  /// Analyses de l'espace par dossier ; [spaceFuture] remplace la réponse de analyzeSpace (analyse en cours).
  final space = <String, SpaceReportMsg>{};
  Future<SpaceReportMsg>? spaceFuture;

  @override
  Future<SpaceReportMsg> analyzeSpace(String sourceId, String path) async {
    calls.add('analyzeSpace $sourceId $path');
    return spaceFuture ?? space[path]!;
  }

  @override
  Future<SpaceReportMsg> spaceChildren(String sourceId, String path) async {
    calls.add('spaceChildren $sourceId $path');
    return space[path]!;
  }

  @override
  Future<void> cancelAnalysis() async => calls.add('cancelAnalysis');

  /// Propriétés par chemin ; taille des dossiers ; réponse de sha256 (null : annulé).
  final detailsByPath = <String, DetailsMsg>{};
  final folderSizes = <String, FolderSizeMsg>{};
  Future<String?>? sha256Future;
  int hashCancels = 0;

  @override
  Future<DetailsMsg> details(String sourceId, String path) async {
    calls.add('details $sourceId $path');
    return detailsByPath[path]!;
  }

  @override
  Future<FolderSizeMsg> folderSize(String sourceId, String path) async {
    calls.add('folderSize $sourceId $path');
    return folderSizes[path]!;
  }

  @override
  Future<String?> sha256(String sourceId, String path) async {
    calls.add('sha256 $sourceId $path');
    return sha256Future ?? 'f' * 64;
  }

  @override
  Future<void> cancelHash() async => hashCancels++;

  /// Serveurs distants ; enregistrements reçus (fiche, mot de passe décodé) ; réponse de connectServer (défaut :
  /// la source distante) et mots de passe reçus ; rappel de trustHostKey.
  List<RemoteServerMsg> servers = [];
  final savedServers = <(RemoteServerMsg, String?)>[];
  SourceMsg Function(String id, Uint8List? password)? connect;
  final connectPasswords = <String?>[];
  void Function(String id, String fingerprint)? onTrust;

  @override
  Future<List<RemoteServerMsg>> listServers() async => List.of(servers);

  @override
  Future<RemoteServerMsg> saveServer(RemoteServerMsg server, Uint8List? password, Uint8List? keyPassphrase) async {
    savedServers.add((server, password == null ? null : utf8.decode(List<int>.of(password))));
    final saved = RemoteServerMsg(
      id: server.id.isEmpty ? 'nouveau' : server.id,
      protocol: server.protocol,
      name: server.name.isEmpty ? server.host : server.name,
      host: server.host,
      port: server.port,
      user: server.user,
      startPath: server.startPath,
      remember: server.remember,
      hostKey: server.hostKey,
      keyInfo: server.keyInfo,
      hasPassword: server.remember && password != null,
      connected: false,
    );
    servers = [...servers.where((s) => s.id != saved.id), saved];
    return saved;
  }

  @override
  Future<void> deleteServer(String serverId) async {
    calls.add('deleteServer $serverId');
    servers = servers.where((s) => s.id != serverId).toList();
  }

  @override
  Future<SourceMsg> connectServer(String serverId, Uint8List? password) async {
    connectPasswords.add(password == null ? null : utf8.decode(List<int>.of(password)));
    final s = connect?.call(serverId, password) ??
        SourceMsg(
          id: 'remote:$serverId',
          stableKey: 'remote:$serverId',
          kind: 'remote',
          label: serverId,
          totalBytes: -1,
          freeBytes: -1,
          readOnly: false,
          roReason: '',
          encrypted: false,
        );
    if (!sources.any((x) => x.id == s.id)) sources = [...sources, s];
    return s;
  }

  @override
  Future<void> disconnectServer(String serverId) async {
    calls.add('disconnectServer $serverId');
    sources = sources.where((s) => s.id != 'remote:$serverId').toList();
  }

  @override
  Future<void> trustHostKey(String serverId, String fingerprint) async {
    calls.add('trustHostKey $serverId $fingerprint');
    onTrust?.call(serverId, fingerprint);
  }

  @override
  Future<void> forgetHostKey(String serverId) async => calls.add('forgetHostKey $serverId');

  /// Phase 13 : réponse de testServer (défaut : un journal d'une ligne) ; journal rendu par lastAttemptLog ;
  /// réponses reçues aux invites keyboard-interactive (identifiant, réponses décodées ou null si refusée).
  List<String> Function(String id, Uint8List? password)? test;
  List<String> attemptLog = [];
  final promptAnswers = <(String, List<String>?)>[];

  @override
  Future<List<String>> testServer(String serverId, Uint8List? password) async {
    calls.add('testServer $serverId');
    return test?.call(serverId, password) ?? ['Connecté'];
  }

  @override
  Future<List<String>> lastAttemptLog(String serverId) async => List.of(attemptLog);

  @override
  Future<void> answerSshPrompt(String requestId, List<Uint8List>? answers) async =>
      promptAnswers.add((requestId, answers?.map((a) => utf8.decode(List<int>.of(a))).toList()));

  /// Phase 13 : terminaux factices. [terminals] : sessions connues du côté Kotlin ; [terminalBacklogs] : leur sortie
  /// récente ; [terminalWrites] : octets écrits (copiés à l'appel) ; [terminalResizes] : (id, colonnes, lignes) ;
  /// [openTerminalHook] : remplace l'ouverture (erreurs, invites) ; [secureScreen] : dernier FLAG_SECURE demandé.
  final terminals = <TerminalSessionMsg>[];
  final terminalBacklogs = <String, Uint8List>{};
  final terminalWrites = <(String, List<int>)>[];
  final terminalResizes = <(String, int, int)>[];
  final closedTerminals = <String>[];
  FutureOr<TerminalSessionMsg> Function(String serverId, Uint8List? password, String? startDir)? openTerminalHook;
  bool? secureScreen;
  var _terminalSeq = 0;

  @override
  Future<TerminalSessionMsg> openTerminal(String serverId, Uint8List? password, String? startDir) async {
    calls.add('openTerminal $serverId${startDir == null ? '' : ' $startDir'}');
    final hook = openTerminalHook;
    if (hook != null) return await hook(serverId, password, startDir);
    final name = servers.where((s) => s.id == serverId).map((s) => s.name).firstOrNull ?? serverId;
    final same = terminals.where((t) => t.serverId == serverId).length; // titres comme côté Kotlin
    final t = TerminalSessionMsg(
        id: 't${++_terminalSeq}',
        serverId: serverId,
        title: same == 0 ? name : '$name (${same + 1})',
        state: 'open',
        cols: 80,
        rows: 24);
    terminals.add(t);
    return t;
  }

  @override
  Future<void> terminalWrite(String sessionId, Uint8List data) async =>
      terminalWrites.add((sessionId, List<int>.of(data)));

  @override
  Future<void> terminalResize(String sessionId, int cols, int rows) async =>
      terminalResizes.add((sessionId, cols, rows));

  @override
  Future<Uint8List> terminalBacklog(String sessionId) async => terminalBacklogs[sessionId] ?? Uint8List(0);

  @override
  Future<void> closeTerminal(String sessionId) async {
    closedTerminals.add(sessionId);
    terminals.removeWhere((t) => t.id == sessionId);
  }

  @override
  Future<List<TerminalSessionMsg>> terminalSessions() async => List.of(terminals);

  @override
  Future<void> setSecureScreen(bool secure) async => secureScreen = secure;

  /// Phase 13 : trousseau factice ; [generatedKeys] : (nom, type, phrase décodée) ; [sharedTexts] : textes partagés.
  final sshKeyList = <SshKeyMsg>[];
  final generatedKeys = <(String, String, String?)>[];
  final sharedTexts = <String>[];
  var _keySeq = 0;

  @override
  Future<List<SshKeyMsg>> sshKeys() async => List.of(sshKeyList);

  @override
  Future<SshKeyMsg> generateSshKey(String name, String type, Uint8List? passphrase) async {
    generatedKeys.add((name, type, passphrase == null ? null : utf8.decode(List<int>.of(passphrase))));
    final k = SshKeyMsg(
        id: 'g${++_keySeq}',
        name: name,
        type: type == 'rsa' ? 'ssh-rsa' : 'ssh-ed25519',
        fingerprint: 'SHA256:gen$_keySeq',
        encrypted: passphrase != null,
        usedBy: []);
    sshKeyList.add(k);
    return k;
  }

  @override
  Future<SshKeyMsg?> importSshKey(String name) async {
    calls.add('importSshKey $name');
    final k = SshKeyMsg(
        id: 'i${++_keySeq}', name: name, type: 'ssh-ed25519', fingerprint: 'SHA256:imp', encrypted: false, usedBy: []);
    sshKeyList.add(k);
    return k;
  }

  @override
  Future<void> renameSshKey(String keyId, String name) async {
    final i = sshKeyList.indexWhere((k) => k.id == keyId);
    final k = sshKeyList[i];
    sshKeyList[i] = SshKeyMsg(
        id: k.id, name: name, type: k.type, fingerprint: k.fingerprint, encrypted: k.encrypted, usedBy: k.usedBy);
  }

  @override
  Future<void> deleteSshKey(String keyId) async {
    final k = sshKeyList.firstWhere((k) => k.id == keyId);
    if (k.usedBy.isNotEmpty) {
      throw PlatformException(code: '1', message: 'Clé utilisée par\u00A0: ${k.usedBy.join(', ')}');
    }
    sshKeyList.remove(k);
  }

  @override
  Future<String> sshPublicKey(String keyId) async => 'ssh-ed25519 AAAAC3Nza portail@test';

  @override
  Future<void> setServerKey(String serverId, String? keyId) async => calls.add('setServerKey $serverId $keyId');

  @override
  Future<void> shareText(String text) async => sharedTexts.add(text);

  /// Commandes enregistrées factices (celles du serveur puis les communes, comme côté Kotlin).
  final snippetList = <SnippetMsg>[];
  var _snippetSeq = 0;

  @override
  Future<List<SnippetMsg>> snippets(String? serverId) async => [
        ...snippetList.where((s) => serverId != null && s.serverId == serverId),
        ...snippetList.where((s) => s.serverId == null),
      ];

  @override
  Future<SnippetMsg> saveSnippet(SnippetMsg snippet) async {
    final saved = SnippetMsg(
        id: snippet.id.isEmpty ? 'c${++_snippetSeq}' : snippet.id,
        serverId: snippet.serverId,
        name: snippet.name,
        command: snippet.command,
        runNow: snippet.runNow);
    final i = snippetList.indexWhere((s) => s.id == saved.id);
    if (i >= 0) {
      snippetList[i] = saved;
    } else {
      snippetList.add(saved);
    }
    return saved;
  }

  @override
  Future<void> deleteSnippet(String id) async => snippetList.removeWhere((s) => s.id == id);

  /// Tunnels factices ; [startTunnelHook] remplace l'ouverture (erreurs) ; [openedUrls] : adresses ouvertes.
  final tunnelList = <TunnelMsg>[];
  TunnelMsg Function(String sessionId, String tunnelId)? startTunnelHook;
  final openedUrls = <String>[];
  var _tunnelSeq = 0;

  TunnelMsg _withActive(TunnelMsg t, bool active, {String? error}) => TunnelMsg(
      id: t.id,
      serverId: t.serverId,
      localPort: t.localPort,
      remoteHost: t.remoteHost,
      remotePort: t.remotePort,
      auto: t.auto,
      active: active,
      error: error);

  @override
  Future<List<TunnelMsg>> tunnels(String serverId) async => tunnelList.where((t) => t.serverId == serverId).toList();

  @override
  Future<TunnelMsg> saveTunnel(TunnelMsg tunnel) async {
    if (tunnel.localPort < 1024 || tunnel.localPort > 65535) {
      throw PlatformException(code: '1', message: 'Port du téléphone entre 1024 et 65535');
    }
    final saved = TunnelMsg(
        id: tunnel.id.isEmpty ? 'u${++_tunnelSeq}' : tunnel.id,
        serverId: tunnel.serverId,
        localPort: tunnel.localPort,
        remoteHost: tunnel.remoteHost,
        remotePort: tunnel.remotePort,
        auto: tunnel.auto,
        active: false);
    final i = tunnelList.indexWhere((t) => t.id == saved.id);
    if (i >= 0) {
      tunnelList[i] = saved;
    } else {
      tunnelList.add(saved);
    }
    return saved;
  }

  @override
  Future<void> deleteTunnel(String id) async => tunnelList.removeWhere((t) => t.id == id);

  @override
  Future<TunnelMsg> startTunnel(String sessionId, String tunnelId) async {
    calls.add('startTunnel $sessionId $tunnelId');
    final hook = startTunnelHook;
    if (hook != null) return hook(sessionId, tunnelId);
    final i = tunnelList.indexWhere((t) => t.id == tunnelId);
    return tunnelList[i] = _withActive(tunnelList[i], true);
  }

  @override
  Future<void> stopTunnel(String sessionId, String tunnelId) async {
    calls.add('stopTunnel $sessionId $tunnelId');
    final i = tunnelList.indexWhere((t) => t.id == tunnelId);
    tunnelList[i] = _withActive(tunnelList[i], false);
  }

  @override
  Future<void> openUrl(String url) async => openedUrls.add(url);

  /// Installation de clé : [installHook] remplace la réponse (erreurs) ; mots de passe reçus, décodés.
  String Function(String serverId, String keyId, Uint8List? password)? installHook;
  final installPasswords = <String?>[];

  @override
  Future<String> installPublicKey(String serverId, String keyId, Uint8List? password) async {
    calls.add('installPublicKey $serverId $keyId');
    installPasswords.add(password == null ? null : utf8.decode(List<int>.of(password)));
    return installHook?.call(serverId, keyId, password) ?? 'Clé installée sur Maison';
  }

  /// Description rendue par importPrivateKey (null : sélecteur fermé sans choix).
  String? importedKey;

  @override
  Future<String?> importPrivateKey(String serverId) async {
    calls.add('importPrivateKey $serverId');
    return importedKey;
  }

  @override
  Future<void> forgetPrivateKey(String serverId) async => calls.add('forgetPrivateKey $serverId');

  /// Lecteurs : octets des images et textes par chemin ; une erreur par chemin (message) ; réponse de writeText
  /// (défaut : enregistré, mtime + 1) ; enregistrements reçus (chemin, texte, bom, crlf, mtime, taille, force).
  final images = <String, Uint8List>{};
  final readErrors = <String, String>{};
  final texts = <String, TextFileMsg>{};
  TextSaveMsg Function(String path, bool force)? onWriteText;
  String? writeError;
  final writes = <(String, String, bool, bool, int, int, bool)>[];

  @override
  Future<Uint8List> readImage(String sourceId, String path) async {
    calls.add('readImage $sourceId $path');
    final err = readErrors[path];
    if (err != null) throw PlatformException(code: '-1', message: err);
    return images[path]!;
  }

  @override
  Future<TextFileMsg> readText(String sourceId, String path) async {
    calls.add('readText $sourceId $path');
    final err = readErrors[path];
    if (err != null) throw PlatformException(code: '-1', message: err);
    return texts[path]!;
  }

  @override
  Future<TextSaveMsg> writeText(String sourceId, String path, String text, bool bom, bool crlf, int expectedMtime,
      int expectedSize, bool force) async {
    writes.add((path, text, bom, crlf, expectedMtime, expectedSize, force));
    if (writeError != null) throw PlatformException(code: '-13', message: writeError);
    return onWriteText?.call(path, force) ??
        TextSaveMsg(saved: true, changed: false, mtime: expectedMtime + 1, size: utf8.encode(text).length);
  }

  /// Résultats des filtres rapides (vide si absent).
  final filters = <String, List<FilterItemMsg>>{};

  @override
  Future<List<FilterItemMsg>> quickFilter(String filter) async {
    calls.add('quickFilter $filter');
    return List.of(filters[filter] ?? const <FilterItemMsg>[]);
  }

  /// Aperçu du renommage par lot.
  List<RenamePreviewMsg> Function(List<String> paths, RenameRuleMsg rule)? renamer;

  @override
  Future<List<RenamePreviewMsg>> previewRename(String sourceId, List<String> paths, RenameRuleMsg rule) async {
    calls.add('previewRename $sourceId ${paths.join(',')} ${rule.mode}');
    return renamer!(paths, rule);
  }

  @override
  Future<void> applyRename(String sourceId, List<String> paths, RenameRuleMsg rule) async =>
      calls.add('applyRename $sourceId ${paths.join(',')} ${rule.mode} ${rule.base} ${rule.start}');

  /// Corbeille de chaque stockage.
  final trash = <String, List<TrashItemMsg>>{};

  @override
  Future<List<TrashItemMsg>> listTrash(String sourceId) async {
    calls.add('listTrash $sourceId');
    return List.of(trash[sourceId] ?? const <TrashItemMsg>[]);
  }

  @override
  Future<void> restoreTrash(String sourceId, List<String> ids) async {
    calls.add('restoreTrash $sourceId ${ids.join(',')}');
    trash[sourceId]?.removeWhere((t) => ids.contains(t.id));
  }

  @override
  Future<void> purgeTrash(String sourceId, List<String> ids) async {
    calls.add('purgeTrash $sourceId ${ids.join(',')}');
    trash[sourceId]?.removeWhere((t) => ids.contains(t.id));
  }

  @override
  Future<void> emptyTrash(String sourceId) async {
    calls.add('emptyTrash $sourceId');
    trash[sourceId]?.clear();
  }

  @override
  Future<void> openWith(String sourceId, String path) async => calls.add('openWith $sourceId $path');

  @override
  Future<void> playVideo(String sourceId, String path) async => calls.add('playVideo $sourceId $path');

  @override
  Future<void> playAudio(String sourceId, List<String> paths, int startIndex) async =>
      calls.add('playAudio $sourceId ${paths.join(',')} $startIndex');

  @override
  Future<void> playerCommand(String command, int? positionMs) async => calls.add('playerCommand $command $positionMs');

  @override
  Future<void> share(String sourceId, List<String> paths) async => calls.add('share $sourceId ${paths.join(',')}');

  final transfers = <(String, List<String>, String, String, bool)>[];
  int transferCancels = 0;

  @override
  Future<void> startTransfer(String srcId, List<String> paths, String dstId, String dstDir, bool move) async =>
      transfers.add((srcId, paths, dstId, dstDir, move));

  @override
  Future<void> cancelTransfer() async => transferCancels++;

  final compresses = <(String, List<String>, String, String)>[];
  final extracts = <(String, String, String, String, bool)>[];

  @override
  Future<void> startCompress(String srcId, List<String> paths, String dstDir, String name) async =>
      compresses.add((srcId, paths, dstDir, name));

  @override
  Future<void> startExtract(String srcId, String archive, String dstId, String dstDir, bool intoNewFolder,
      {Uint8List? password}) async {
    extracts.add((srcId, archive, dstId, dstDir, intoNewFolder));
    if (password != null) {
      passwordBuffers.add(password);
      extractPasswords.add(utf8.decode(password));
    }
  }

  // --- chiffrement (phase 14) ---

  /// Mots de passe reçus pour une extraction ; tampons reçus (l'écran doit les mettre à zéro après l'appel).
  final extractPasswords = <String>[];
  final passwordBuffers = <Uint8List>[];

  /// Format chiffré par chemin (sinon `none`) ; [filePassword] : le seul mot de passe accepté par openDecrypted et
  /// changeFilePassword (sinon erreur `badPassword`).
  final encryptedInfos = <String, EncryptedInfoMsg>{};
  String filePassword = '';
  final encrypts = <({String srcId, List<String> paths, String dstId, String dstDir, String format, bool together,
      String? name, bool deleteOriginal, String password, Uint8List bytes})>[];
  final decrypts = <({String srcId, String path, String dstId, String dstDir, bool extractFolder, String password})>[];
  final verifies = <(String, String, String)>[];
  final changedPasswords = <(String, String, String, String)>[];
  final openDecryptedPasswords = <String>[];
  final closedDecrypted = <String>[];
  int _decCount = 0;

  String _take(Uint8List b) {
    passwordBuffers.add(b);
    return utf8.decode(b);
  }

  PlatformException _bad() => PlatformException(code: 'badPassword', message: 'Mot de passe incorrect');

  @override
  Future<EncryptedInfoMsg> encryptedInfo(String sourceId, String path) async =>
      encryptedInfos[path] ?? EncryptedInfoMsg(format: 'none', folder: false);

  @override
  Future<void> startEncrypt(String srcId, List<String> paths, String dstId, String dstDir, String format, bool together,
      String? name, bool deleteOriginal, Uint8List password) async {
    encrypts.add((srcId: srcId, paths: paths, dstId: dstId, dstDir: dstDir, format: format, together: together,
        name: name, deleteOriginal: deleteOriginal, password: utf8.decode(password), bytes: password));
    passwordBuffers.add(password);
  }

  @override
  Future<void> startDecrypt(String srcId, String path, String dstId, String dstDir, bool extractFolder, Uint8List password) async =>
      decrypts.add((srcId: srcId, path: path, dstId: dstId, dstDir: dstDir, extractFolder: extractFolder, password: _take(password)));

  @override
  Future<void> startVerify(String srcId, String path, Uint8List password) async => verifies.add((srcId, path, _take(password)));

  @override
  Future<void> changeFilePassword(String srcId, String path, Uint8List oldPassword, Uint8List newPassword) async {
    final o = _take(oldPassword), n = _take(newPassword);
    if (o != filePassword) throw _bad();
    changedPasswords.add((srcId, path, o, n));
  }

  @override
  Future<SourceMsg> openDecrypted(String srcId, String path, Uint8List password) async {
    final p = _take(password);
    openDecryptedPasswords.add(p);
    if (p != filePassword) throw _bad();
    final name = path.substring(path.lastIndexOf('/') + 1).replaceFirst(RegExp(r'\.age$'), '');
    return SourceMsg(id: 'dec:${++_decCount}', stableKey: 'dec:$_decCount', kind: 'decrypted', label: name,
        totalBytes: 1000, freeBytes: 0, readOnly: true, roReason: 'Fichier déchiffré en mémoire, en lecture seule',
        encrypted: false);
  }

  @override
  Future<void> closeDecrypted(String sourceId) async => closedDecrypted.add(sourceId);

  // --- coffres (phase 14) ---
  List<VaultMsg> vaults = [];
  final createdVaults = <(String, String, String, int, String, String)>[];
  final openedVaults = <(String?, String?, String?, String, bool)>[];
  final closedVaults = <String>[];
  final forgottenVaults = <String>[];

  @override
  Future<List<VaultMsg>> listVaults() async => vaults;

  @override
  Future<VaultMsg> createVault(String srcId, String dir, String name, int sizeBytes, String fs, Uint8List password) async {
    createdVaults.add((srcId, dir, name, sizeBytes, fs, _take(password)));
    final v = VaultMsg(id: 'c${createdVaults.length}', name: name, sourceKey: srcId, sourceLabel: srcId,
        path: '$dir/$name.luks'.replaceFirst('//', '/'), sizeBytes: sizeBytes, fs: fs, state: 'closed',
        hasRecovery: false, biometric: false, luksVersion: 2);
    vaults = [...vaults, v];
    return v;
  }

  @override
  Future<VolumeMsg> openVault(String? vaultId, String? srcId, String? path, Uint8List password, bool writable) async {
    final p = _take(password);
    openedVaults.add((vaultId, srcId, path, p, writable));
    if (p != filePassword) throw _bad();
    return VolumeMsg(id: 'vv${openedVaults.length}', diskId: 'vault:$vaultId', partIndex: 0, title: 'Coffre',
        totalBytes: 1000, freeBytes: 500, needsRecovery: false, roReason: '', readOnly: !writable, vaultId: vaultId ?? 'x');
  }

  @override
  Future<void> closeVault(String vaultId) async => closedVaults.add(vaultId);

  @override
  Future<void> forgetVault(String vaultId) async => forgottenVaults.add(vaultId);

  /// Copies protégées reçues (copies des octets, l'appelant met les siens à zéro).
  final secretCopies = <Uint8List>[];

  @override
  Future<void> copySecret(Uint8List text) async => secretCopies.add(Uint8List.fromList(text));

  /// Réponse de [search] selon la requête ; un completer dans [searchGates] la retarde.
  SearchResultMsg Function(String query) searchResult = (_) => SearchResultMsg(entries: [], truncated: false);

  /// Résultats propres à une source (recherche dans tous les stockages) ; sinon [searchResult].
  final searchBySource = <String, SearchResultMsg Function(String query)>{};
  final searchGates = <String, Completer<void>>{};
  int searchCancels = 0;

  /// Recherches et annulations, dans l'ordre (« search source chemin requête », « cancel »).
  final searchLog = <String>[];

  @override
  Future<SearchResultMsg> search(String sourceId, String path, String query, bool showHidden) async {
    calls.add('search $sourceId $path $query');
    searchLog.add('search $sourceId $path $query');
    final gate = searchGates[query];
    if (gate != null) await gate.future;
    return (searchBySource[sourceId] ?? searchResult)(query);
  }

  @override
  Future<void> cancelSearch() async {
    searchCancels++;
    searchLog.add('cancel');
  }

  /// Octets rendus par [thumbnail] selon le chemin (null : pas de vignette).
  final thumbs = <String, Uint8List>{};
  final thumbRequests = <String>[];

  /// Les mêmes demandes, avec leur source : `sourceId|chemin`.
  final thumbSources = <String>[];

  @override
  Future<Uint8List?> thumbnail(String sourceId, String path, int sizePx) async {
    thumbRequests.add(path);
    thumbSources.add('$sourceId|$path');
    return thumbs[path];
  }

  ViewPrefsMsg viewPrefs = ViewPrefsMsg(sort: 'name', ascending: true, grid: false, showHidden: false, builtInViewers: true);
  List<FavoriteMsg> favorites = [];

  @override
  Future<ViewPrefsMsg> getViewPrefs() async => viewPrefs;

  @override
  Future<void> setViewPrefs(ViewPrefsMsg prefs) async => viewPrefs = prefs;

  /// Préférences d'interface ; bienvenue déjà vue : les écrans s'ouvrent sur l'accueil.
  UiPrefsMsg uiPrefs = UiPrefsMsg(theme: 'system', haptics: true, welcomeSeen: true);

  @override
  Future<UiPrefsMsg> getUiPrefs() async => uiPrefs;

  @override
  Future<void> setUiPrefs(UiPrefsMsg prefs) async => uiPrefs = prefs;

  /// Version et appareil montrés par « À propos ».
  AppInfoMsg appInfo = AppInfoMsg(versionName: '1.4.0', versionCode: 11, androidRelease: '13', device: 'Pixel 4 XL');

  @override
  Future<AppInfoMsg> getAppInfo() async => appInfo;

  @override
  Future<List<FavoriteMsg>> listFavorites() async => favorites;

  @override
  Future<void> addFavorite(String sourceId, String path, String label) async {
    final key = sources.firstWhere((s) => s.id == sourceId).stableKey;
    if (favorites.any((f) => f.key == key && f.path == path)) return;
    favorites = [...favorites, FavoriteMsg(key: key, path: path, label: label, sourceId: sourceId)];
  }

  @override
  Future<void> removeFavorite(String key, String path) async =>
      favorites = favorites.where((f) => !(f.key == key && f.path == path)).toList();
}

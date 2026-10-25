import 'dart:typed_data';

import '../ai/ai_api.dart';
import '../bridge/fluluks_api.g.dart';

/// Interface de l'API hôte, substituable dans les tests (intégration IA : [AiApi]).
abstract class HostApi implements AiApi {
  Future<List<DiskMsg>> listDisks();
  Future<List<VolumeMsg>> listVolumes();
  Future<void> requestPermission(String diskId);
  Future<VolumeMsg> unlock(String diskId, int partIndex, Uint8List passphrase, bool writable);
  Future<VolumeMsg> mountPlain(String diskId, int partIndex, bool writable);
  Future<void> eject(String volumeId);
  Future<void> openInFiles(String volumeId);
  Future<bool> getReadOnlyPreference();
  Future<void> setReadOnlyPreference(bool value);
  Future<int> getAutoLockMinutes();
  Future<void> setAutoLockMinutes(int minutes);
  Future<List<SourceMsg>> listSources();
  Future<bool> hasAllFilesAccess();
  Future<void> requestAllFilesAccess();
  Future<List<EntryMsg>> listDir(String sourceId, String path, bool showHidden);
  Future<String> createFolder(String sourceId, String parent, String name);
  Future<String> rename(String sourceId, String path, String newName);
  Future<void> deleteEntries(String sourceId, List<String> paths, bool permanent);
  Future<List<TrashItemMsg>> listTrash(String sourceId);
  Future<void> restoreTrash(String sourceId, List<String> ids);
  Future<void> purgeTrash(String sourceId, List<String> ids);
  Future<void> emptyTrash(String sourceId);
  Future<void> openWith(String sourceId, String path);
  Future<void> playVideo(String sourceId, String path);
  Future<void> playAudio(String sourceId, List<String> paths, int startIndex);
  Future<void> playerCommand(String command, int? positionMs);
  Future<void> share(String sourceId, List<String> paths);
  Future<void> startTransfer(String srcId, List<String> paths, String dstId, String dstDir, bool move);
  Future<void> startCompress(String srcId, List<String> paths, String dstDir, String name);
  Future<void> startExtract(String srcId, String archive, String dstId, String dstDir, bool intoNewFolder,
      {Uint8List? password});
  Future<void> cancelTransfer();

  /// Copie protégée d'un mot de passe (effacée après 60 s) ; [text] est mis à zéro par l'appelant.
  Future<void> copySecret(Uint8List text);

  // chiffrement (phase 14) : les tampons de mots de passe sont mis à zéro par l'appelant après l'appel
  Future<EncryptedInfoMsg> encryptedInfo(String sourceId, String path);
  Future<void> startEncrypt(String srcId, List<String> paths, String dstId, String dstDir, String format, bool together,
      String? name, bool deleteOriginal, Uint8List password);
  Future<void> startDecrypt(String srcId, String path, String dstId, String dstDir, bool extractFolder, Uint8List password);
  Future<void> startVerify(String srcId, String path, Uint8List password);
  Future<void> changeFilePassword(String srcId, String path, Uint8List oldPassword, Uint8List newPassword);
  Future<SourceMsg> openDecrypted(String srcId, String path, Uint8List password);
  Future<void> closeDecrypted(String sourceId);

  // coffres (phase 14)
  Future<List<VaultMsg>> listVaults();
  Future<VaultMsg> createVault(String srcId, String dir, String name, int sizeBytes, String fs, Uint8List password);
  Future<VolumeMsg> openVault(String? vaultId, String? srcId, String? path, Uint8List password, bool writable,
      {bool recovery = false});
  Future<void> changeVaultPassword(String vaultId, Uint8List oldPassword, Uint8List newPassword);
  Future<Uint8List> addRecoveryKey(String vaultId, Uint8List password);
  Future<void> removeRecoveryKey(String vaultId, Uint8List password);
  Future<String?> biometricUnavailable();
  Future<void> enableBiometric(String vaultId, Uint8List password);
  Future<VolumeMsg> openVaultBiometric(String vaultId, bool writable);
  Future<void> disableBiometric(String vaultId, Uint8List? password);
  Future<void> closeVault(String vaultId);
  Future<void> forgetVault(String vaultId);
  Future<SearchResultMsg> search(String sourceId, String path, String query, bool showHidden);
  Future<void> cancelSearch();
  Future<SpaceReportMsg> analyzeSpace(String sourceId, String path);
  Future<SpaceReportMsg> spaceChildren(String sourceId, String path);
  Future<void> cancelAnalysis();
  Future<DetailsMsg> details(String sourceId, String path);
  Future<FolderSizeMsg> folderSize(String sourceId, String path);
  Future<String?> sha256(String sourceId, String path);
  Future<void> cancelHash();
  Future<List<RemoteServerMsg>> listServers();
  Future<RemoteServerMsg> saveServer(RemoteServerMsg server, Uint8List? password, Uint8List? keyPassphrase);
  Future<void> deleteServer(String serverId);
  Future<SourceMsg> connectServer(String serverId, Uint8List? password);
  Future<void> disconnectServer(String serverId);
  Future<void> trustHostKey(String serverId, String fingerprint);
  Future<void> forgetHostKey(String serverId);
  Future<List<String>> testServer(String serverId, Uint8List? password);
  Future<List<String>> lastAttemptLog(String serverId);
  Future<void> answerSshPrompt(String requestId, List<Uint8List>? answers);
  Future<TerminalSessionMsg> openTerminal(String serverId, Uint8List? password, String? startDir);
  Future<void> terminalWrite(String sessionId, Uint8List data);
  Future<void> terminalResize(String sessionId, int cols, int rows);
  Future<Uint8List> terminalBacklog(String sessionId);
  Future<void> closeTerminal(String sessionId);
  Future<List<TerminalSessionMsg>> terminalSessions();
  Future<void> setSecureScreen(bool secure);
  Future<List<SshKeyMsg>> sshKeys();
  Future<SshKeyMsg> generateSshKey(String name, String type, Uint8List? passphrase);
  Future<SshKeyMsg?> importSshKey(String name);
  Future<void> renameSshKey(String keyId, String name);
  Future<void> deleteSshKey(String keyId);
  Future<String> sshPublicKey(String keyId);
  Future<void> setServerKey(String serverId, String? keyId);
  Future<void> shareText(String text);
  Future<String> installPublicKey(String serverId, String keyId, Uint8List? password);
  Future<List<SnippetMsg>> snippets(String? serverId);
  Future<SnippetMsg> saveSnippet(SnippetMsg snippet);
  Future<void> deleteSnippet(String id);
  Future<List<TunnelMsg>> tunnels(String serverId);
  Future<TunnelMsg> saveTunnel(TunnelMsg tunnel);
  Future<void> deleteTunnel(String id);
  Future<TunnelMsg> startTunnel(String sessionId, String tunnelId);
  Future<void> stopTunnel(String sessionId, String tunnelId);
  Future<void> openUrl(String url);
  Future<String?> importPrivateKey(String serverId);
  Future<void> forgetPrivateKey(String serverId);
  Future<Uint8List> readImage(String sourceId, String path);
  Future<TextFileMsg> readText(String sourceId, String path);
  Future<TextSaveMsg> writeText(String sourceId, String path, String text, bool bom, bool crlf, int expectedMtime,
      int expectedSize, bool force);
  Future<List<FilterItemMsg>> quickFilter(String filter);
  Future<List<RenamePreviewMsg>> previewRename(String sourceId, List<String> paths, RenameRuleMsg rule);
  Future<void> applyRename(String sourceId, List<String> paths, RenameRuleMsg rule);
  Future<Uint8List?> thumbnail(String sourceId, String path, int sizePx);
  Future<ViewPrefsMsg> getViewPrefs();
  Future<void> setViewPrefs(ViewPrefsMsg prefs);
  Future<List<FavoriteMsg>> listFavorites();
  Future<void> addFavorite(String sourceId, String path, String label);
  Future<void> removeFavorite(String key, String path);
  Future<UiPrefsMsg> getUiPrefs();
  Future<void> setUiPrefs(UiPrefsMsg prefs);
  Future<AppInfoMsg> getAppInfo();
  Future<void> formatDisk(String diskId, String fs, bool encrypted, String label, Uint8List? passphrase);
}

/// Implémentation réelle : délègue au client Pigeon généré.
class PigeonHostApi with PigeonAiApi implements HostApi {
  PigeonHostApi([FluLuksHostApi? api]) : _api = api ?? FluLuksHostApi();
  final FluLuksHostApi _api;

  @override
  Future<List<DiskMsg>> listDisks() => _api.listDisks();
  @override
  Future<List<VolumeMsg>> listVolumes() => _api.listVolumes();
  @override
  Future<void> requestPermission(String diskId) => _api.requestPermission(diskId);
  @override
  Future<VolumeMsg> unlock(String diskId, int partIndex, Uint8List passphrase, bool writable) =>
      _api.unlock(diskId, partIndex, passphrase, writable);
  @override
  Future<VolumeMsg> mountPlain(String diskId, int partIndex, bool writable) =>
      _api.mountPlain(diskId, partIndex, writable);
  @override
  Future<void> eject(String volumeId) => _api.eject(volumeId);
  @override
  Future<void> openInFiles(String volumeId) => _api.openInFiles(volumeId);
  @override
  Future<bool> getReadOnlyPreference() => _api.getReadOnlyPreference();
  @override
  Future<void> setReadOnlyPreference(bool value) => _api.setReadOnlyPreference(value);
  @override
  Future<int> getAutoLockMinutes() => _api.getAutoLockMinutes();
  @override
  Future<void> setAutoLockMinutes(int minutes) => _api.setAutoLockMinutes(minutes);
  @override
  Future<List<SourceMsg>> listSources() => _api.listSources();
  @override
  Future<bool> hasAllFilesAccess() => _api.hasAllFilesAccess();
  @override
  Future<void> requestAllFilesAccess() => _api.requestAllFilesAccess();
  @override
  Future<List<EntryMsg>> listDir(String sourceId, String path, bool showHidden) =>
      _api.listDir(sourceId, path, showHidden);
  @override
  Future<String> createFolder(String sourceId, String parent, String name) =>
      _api.createFolder(sourceId, parent, name);
  @override
  Future<String> rename(String sourceId, String path, String newName) => _api.rename(sourceId, path, newName);
  @override
  Future<void> deleteEntries(String sourceId, List<String> paths, bool permanent) =>
      _api.deleteEntries(sourceId, paths, permanent);
  @override
  Future<List<TrashItemMsg>> listTrash(String sourceId) => _api.listTrash(sourceId);
  @override
  Future<void> restoreTrash(String sourceId, List<String> ids) => _api.restoreTrash(sourceId, ids);
  @override
  Future<void> purgeTrash(String sourceId, List<String> ids) => _api.purgeTrash(sourceId, ids);
  @override
  Future<void> emptyTrash(String sourceId) => _api.emptyTrash(sourceId);
  @override
  Future<void> openWith(String sourceId, String path) => _api.openWith(sourceId, path);
  @override
  Future<void> playVideo(String sourceId, String path) => _api.playVideo(sourceId, path);
  @override
  Future<void> playAudio(String sourceId, List<String> paths, int startIndex) =>
      _api.playAudio(sourceId, paths, startIndex);
  @override
  Future<void> playerCommand(String command, int? positionMs) => _api.playerCommand(command, positionMs);
  @override
  Future<void> share(String sourceId, List<String> paths) => _api.share(sourceId, paths);
  @override
  Future<void> startTransfer(String srcId, List<String> paths, String dstId, String dstDir, bool move) =>
      _api.startTransfer(srcId, paths, dstId, dstDir, move);
  @override
  Future<void> startCompress(String srcId, List<String> paths, String dstDir, String name) =>
      _api.startCompress(srcId, paths, dstDir, name);
  @override
  Future<void> startExtract(String srcId, String archive, String dstId, String dstDir, bool intoNewFolder,
          {Uint8List? password}) =>
      _api.startExtract(srcId, archive, dstId, dstDir, intoNewFolder, password);
  @override
  Future<void> cancelTransfer() => _api.cancelTransfer();
  @override
  Future<void> copySecret(Uint8List text) => _api.copySecret(text);
  @override
  Future<EncryptedInfoMsg> encryptedInfo(String sourceId, String path) => _api.encryptedInfo(sourceId, path);
  @override
  Future<void> startEncrypt(String srcId, List<String> paths, String dstId, String dstDir, String format, bool together,
          String? name, bool deleteOriginal, Uint8List password) =>
      _api.startEncrypt(srcId, paths, dstId, dstDir, format, together, name, deleteOriginal, password);
  @override
  Future<void> startDecrypt(String srcId, String path, String dstId, String dstDir, bool extractFolder, Uint8List password) =>
      _api.startDecrypt(srcId, path, dstId, dstDir, extractFolder, password);
  @override
  Future<void> startVerify(String srcId, String path, Uint8List password) => _api.startVerify(srcId, path, password);
  @override
  Future<void> changeFilePassword(String srcId, String path, Uint8List oldPassword, Uint8List newPassword) =>
      _api.changeFilePassword(srcId, path, oldPassword, newPassword);
  @override
  Future<SourceMsg> openDecrypted(String srcId, String path, Uint8List password) =>
      _api.openDecrypted(srcId, path, password);
  @override
  Future<void> closeDecrypted(String sourceId) => _api.closeDecrypted(sourceId);
  @override
  Future<List<VaultMsg>> listVaults() => _api.listVaults();
  @override
  Future<VaultMsg> createVault(String srcId, String dir, String name, int sizeBytes, String fs, Uint8List password) =>
      _api.createVault(srcId, dir, name, sizeBytes, fs, password);
  @override
  Future<VolumeMsg> openVault(String? vaultId, String? srcId, String? path, Uint8List password, bool writable,
          {bool recovery = false}) =>
      _api.openVault(vaultId, srcId, path, password, writable, recovery);

  @override
  Future<void> changeVaultPassword(String vaultId, Uint8List oldPassword, Uint8List newPassword) =>
      _api.changeVaultPassword(vaultId, oldPassword, newPassword);

  @override
  Future<Uint8List> addRecoveryKey(String vaultId, Uint8List password) => _api.addRecoveryKey(vaultId, password);

  @override
  Future<void> removeRecoveryKey(String vaultId, Uint8List password) => _api.removeRecoveryKey(vaultId, password);

  @override
  Future<String?> biometricUnavailable() => _api.biometricUnavailable();

  @override
  Future<void> enableBiometric(String vaultId, Uint8List password) => _api.enableBiometric(vaultId, password);

  @override
  Future<VolumeMsg> openVaultBiometric(String vaultId, bool writable) => _api.openVaultBiometric(vaultId, writable);

  @override
  Future<void> disableBiometric(String vaultId, Uint8List? password) => _api.disableBiometric(vaultId, password);
  @override
  Future<void> closeVault(String vaultId) => _api.closeVault(vaultId);
  @override
  Future<void> forgetVault(String vaultId) => _api.forgetVault(vaultId);
  @override
  Future<SearchResultMsg> search(String sourceId, String path, String query, bool showHidden) =>
      _api.search(sourceId, path, query, showHidden);
  @override
  Future<void> cancelSearch() => _api.cancelSearch();
  @override
  Future<SpaceReportMsg> analyzeSpace(String sourceId, String path) => _api.analyzeSpace(sourceId, path);
  @override
  Future<SpaceReportMsg> spaceChildren(String sourceId, String path) => _api.spaceChildren(sourceId, path);
  @override
  Future<void> cancelAnalysis() => _api.cancelAnalysis();
  @override
  Future<DetailsMsg> details(String sourceId, String path) => _api.details(sourceId, path);
  @override
  Future<FolderSizeMsg> folderSize(String sourceId, String path) => _api.folderSize(sourceId, path);
  @override
  Future<String?> sha256(String sourceId, String path) => _api.sha256(sourceId, path);
  @override
  Future<void> cancelHash() => _api.cancelHash();
  @override
  Future<List<RemoteServerMsg>> listServers() => _api.listServers();
  @override
  Future<RemoteServerMsg> saveServer(RemoteServerMsg server, Uint8List? password, Uint8List? keyPassphrase) =>
      _api.saveServer(server, password, keyPassphrase);
  @override
  Future<void> deleteServer(String serverId) => _api.deleteServer(serverId);
  @override
  Future<SourceMsg> connectServer(String serverId, Uint8List? password) => _api.connectServer(serverId, password);
  @override
  Future<void> disconnectServer(String serverId) => _api.disconnectServer(serverId);
  @override
  Future<void> trustHostKey(String serverId, String fingerprint) => _api.trustHostKey(serverId, fingerprint);
  @override
  Future<void> forgetHostKey(String serverId) => _api.forgetHostKey(serverId);
  @override
  Future<List<String>> testServer(String serverId, Uint8List? password) => _api.testServer(serverId, password);
  @override
  Future<List<String>> lastAttemptLog(String serverId) => _api.lastAttemptLog(serverId);
  @override
  Future<void> answerSshPrompt(String requestId, List<Uint8List>? answers) =>
      _api.answerSshPrompt(requestId, answers);
  @override
  Future<TerminalSessionMsg> openTerminal(String serverId, Uint8List? password, String? startDir) =>
      _api.openTerminal(serverId, password, startDir);
  @override
  Future<void> terminalWrite(String sessionId, Uint8List data) => _api.terminalWrite(sessionId, data);
  @override
  Future<void> terminalResize(String sessionId, int cols, int rows) => _api.terminalResize(sessionId, cols, rows);
  @override
  Future<Uint8List> terminalBacklog(String sessionId) => _api.terminalBacklog(sessionId);
  @override
  Future<void> closeTerminal(String sessionId) => _api.closeTerminal(sessionId);
  @override
  Future<List<TerminalSessionMsg>> terminalSessions() => _api.terminalSessions();
  @override
  Future<void> setSecureScreen(bool secure) => _api.setSecureScreen(secure);
  @override
  Future<List<SshKeyMsg>> sshKeys() => _api.sshKeys();
  @override
  Future<SshKeyMsg> generateSshKey(String name, String type, Uint8List? passphrase) =>
      _api.generateSshKey(name, type, passphrase);
  @override
  Future<SshKeyMsg?> importSshKey(String name) => _api.importSshKey(name);
  @override
  Future<void> renameSshKey(String keyId, String name) => _api.renameSshKey(keyId, name);
  @override
  Future<void> deleteSshKey(String keyId) => _api.deleteSshKey(keyId);
  @override
  Future<String> sshPublicKey(String keyId) => _api.sshPublicKey(keyId);
  @override
  Future<void> setServerKey(String serverId, String? keyId) => _api.setServerKey(serverId, keyId);
  @override
  Future<void> shareText(String text) => _api.shareText(text);
  @override
  Future<String> installPublicKey(String serverId, String keyId, Uint8List? password) =>
      _api.installPublicKey(serverId, keyId, password);
  @override
  Future<List<SnippetMsg>> snippets(String? serverId) => _api.snippets(serverId);
  @override
  Future<SnippetMsg> saveSnippet(SnippetMsg snippet) => _api.saveSnippet(snippet);
  @override
  Future<void> deleteSnippet(String id) => _api.deleteSnippet(id);
  @override
  Future<List<TunnelMsg>> tunnels(String serverId) => _api.tunnels(serverId);
  @override
  Future<TunnelMsg> saveTunnel(TunnelMsg tunnel) => _api.saveTunnel(tunnel);
  @override
  Future<void> deleteTunnel(String id) => _api.deleteTunnel(id);
  @override
  Future<TunnelMsg> startTunnel(String sessionId, String tunnelId) => _api.startTunnel(sessionId, tunnelId);
  @override
  Future<void> stopTunnel(String sessionId, String tunnelId) => _api.stopTunnel(sessionId, tunnelId);
  @override
  Future<void> openUrl(String url) => _api.openUrl(url);
  @override
  Future<String?> importPrivateKey(String serverId) => _api.importPrivateKey(serverId);
  @override
  Future<void> forgetPrivateKey(String serverId) => _api.forgetPrivateKey(serverId);
  @override
  Future<Uint8List> readImage(String sourceId, String path) => _api.readImage(sourceId, path);
  @override
  Future<TextFileMsg> readText(String sourceId, String path) => _api.readText(sourceId, path);
  @override
  Future<TextSaveMsg> writeText(String sourceId, String path, String text, bool bom, bool crlf, int expectedMtime,
          int expectedSize, bool force) =>
      _api.writeText(sourceId, path, text, bom, crlf, expectedMtime, expectedSize, force);
  @override
  Future<List<FilterItemMsg>> quickFilter(String filter) => _api.quickFilter(filter);
  @override
  Future<List<RenamePreviewMsg>> previewRename(String sourceId, List<String> paths, RenameRuleMsg rule) =>
      _api.previewRename(sourceId, paths, rule);
  @override
  Future<void> applyRename(String sourceId, List<String> paths, RenameRuleMsg rule) =>
      _api.applyRename(sourceId, paths, rule);
  @override
  Future<Uint8List?> thumbnail(String sourceId, String path, int sizePx) => _api.thumbnail(sourceId, path, sizePx);
  @override
  Future<ViewPrefsMsg> getViewPrefs() => _api.getViewPrefs();
  @override
  Future<void> setViewPrefs(ViewPrefsMsg prefs) => _api.setViewPrefs(prefs);
  @override
  Future<List<FavoriteMsg>> listFavorites() => _api.listFavorites();
  @override
  Future<void> addFavorite(String sourceId, String path, String label) => _api.addFavorite(sourceId, path, label);
  @override
  Future<void> removeFavorite(String key, String path) => _api.removeFavorite(key, path);
  @override
  Future<UiPrefsMsg> getUiPrefs() => _api.getUiPrefs();
  @override
  Future<void> setUiPrefs(UiPrefsMsg prefs) => _api.setUiPrefs(prefs);
  @override
  Future<AppInfoMsg> getAppInfo() => _api.getAppInfo();
  @override
  Future<void> formatDisk(String diskId, String fs, bool encrypted, String label, Uint8List? passphrase) =>
      _api.formatDisk(diskId, fs, encrypted, label, passphrase);
}

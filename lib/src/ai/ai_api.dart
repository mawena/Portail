import 'dart:typed_data';

import '../bridge/fluluks_api.g.dart';

/// Pont de l'intégration IA (phase 15), substituable dans les tests. `HostApi` l'implémente : l'état de
/// l'application n'a qu'un pont.
abstract class AiApi {
  Future<List<AiServerMsg>> aiServers();
  Future<AiServerMsg> saveAiServer(AiServerMsg server, Uint8List? key);
  Future<void> removeAiServerKey(String serverId);
  Future<void> deleteAiServer(String serverId);
  Future<void> setDefaultAiServer(String serverId);
  Future<AiTestResultMsg> testAiServer(String serverId);
  Future<List<String>> aiModels(String serverId);
  Future<void> setAiDefaultModel(String serverId, String? model);
  Future<AiHealthMsg> aiHealth(String serverId);
  Future<List<String>> aiAttemptLog(String serverId);
}

/// Implémentation réelle : délègue au client Pigeon `AiHostApi`.
mixin PigeonAiApi implements AiApi {
  final AiHostApi _ai = AiHostApi();

  @override
  Future<List<AiServerMsg>> aiServers() => _ai.aiServers();
  @override
  Future<AiServerMsg> saveAiServer(AiServerMsg server, Uint8List? key) => _ai.saveAiServer(server, key);
  @override
  Future<void> removeAiServerKey(String serverId) => _ai.removeAiServerKey(serverId);
  @override
  Future<void> deleteAiServer(String serverId) => _ai.deleteAiServer(serverId);
  @override
  Future<void> setDefaultAiServer(String serverId) => _ai.setDefaultAiServer(serverId);
  @override
  Future<AiTestResultMsg> testAiServer(String serverId) => _ai.testAiServer(serverId);
  @override
  Future<List<String>> aiModels(String serverId) => _ai.aiModels(serverId);
  @override
  Future<void> setAiDefaultModel(String serverId, String? model) => _ai.setAiDefaultModel(serverId, model);
  @override
  Future<AiHealthMsg> aiHealth(String serverId) => _ai.aiHealth(serverId);
  @override
  Future<List<String>> aiAttemptLog(String serverId) => _ai.aiAttemptLog(serverId);
}

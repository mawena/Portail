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

  // historique des conversations (T5)
  Future<List<ConversationMsg>> conversations();
  Future<ConversationDetailMsg> conversation(int id);
  Future<ConversationMsg> createConversation(String? serverId, String? model);
  Future<void> renameConversation(int id, String title);
  Future<void> deleteConversation(int id);
  Future<void> setConversationModel(int id, String? serverId, String? model);
  Future<void> setSystemPrompt(int id, String? prompt);

  // réponses en flux (T6)
  Future<ChatMessageMsg> sendChatMessage(int conversationId, String text);
  Future<void> stopGeneration(int conversationId);
  Future<ChatMessageMsg> regenerate(int conversationId);
  Future<List<int>> runningChats();
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

  @override
  Future<List<ConversationMsg>> conversations() => _ai.conversations();
  @override
  Future<ConversationDetailMsg> conversation(int id) => _ai.conversation(id);
  @override
  Future<ConversationMsg> createConversation(String? serverId, String? model) => _ai.createConversation(serverId, model);
  @override
  Future<void> renameConversation(int id, String title) => _ai.renameConversation(id, title);
  @override
  Future<void> deleteConversation(int id) => _ai.deleteConversation(id);
  @override
  Future<void> setConversationModel(int id, String? serverId, String? model) =>
      _ai.setConversationModel(id, serverId, model);
  @override
  Future<void> setSystemPrompt(int id, String? prompt) => _ai.setSystemPrompt(id, prompt);
  @override
  Future<ChatMessageMsg> sendChatMessage(int conversationId, String text) => _ai.sendChatMessage(conversationId, text);
  @override
  Future<void> stopGeneration(int conversationId) => _ai.stopGeneration(conversationId);
  @override
  Future<ChatMessageMsg> regenerate(int conversationId) => _ai.regenerate(conversationId);
  @override
  Future<List<int>> runningChats() => _ai.runningChats();
}

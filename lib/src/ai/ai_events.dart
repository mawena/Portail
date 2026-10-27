import '../bridge/fluluks_api.g.dart';
import 'automation_hub.dart';
import 'chat_hub.dart';

/// Événements de l'intégration IA poussés par Kotlin (phase 15) : réponses du chat et lancements manuels des
/// automatisations, confiés à leur hub.
class AiEvents implements AiEventsApi {
  AiEvents(this.chats, this.automations);

  final ChatHub chats;
  final AutomationHub automations;

  @override
  void onChatDelta(int conversationId, int messageId, String text) => chats.onChatDelta(conversationId, messageId, text);

  @override
  void onChatState(ChatMessageMsg message) => chats.onChatState(message);

  @override
  void onAutomationDelta(int runId, String text) => automations.onRunDelta(runId, text);

  @override
  void onAutomationState(AutomationRunMsg run) => automations.onRunState(run);
}

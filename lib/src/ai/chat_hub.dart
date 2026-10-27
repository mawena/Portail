import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../bridge/fluluks_api.g.dart';
import 'ai_api.dart';

/// Une conversation ouverte : sa fiche et ses messages, dans l'ordre.
class ChatThread {
  ChatThread(this.conversation, this.messages);

  ConversationMsg conversation;
  final List<ChatMessageMsg> messages;
}

/// Conversations côté Dart (phase 15) : tenues ici, hors de tout écran, comme les terminaux. Kotlin pousse le texte
/// des réponses par lots ([onChatDelta]) et leur fin ([onChatState]), par `AiEvents` ; le texte d'une réponse en cours est gardé ici
/// même quand aucun écran ne la montre (Kotlin ne l'écrit dans l'historique qu'à la fin), pour qu'un écran rouvert
/// la retrouve entière.
class ChatHub extends ChangeNotifier {
  ChatHub(this.api);

  final AiApi api;

  List<ConversationMsg> _list = const [];
  bool _loaded = false;
  final _threads = <int, ChatThread>{};
  final _running = <int>{};

  /// Texte reçu des réponses en cours, par message.
  final _live = <int, StringBuffer>{};

  /// Conversations, la plus récente d'abord.
  List<ConversationMsg> get conversations => _list;

  /// Vrai dès que la liste a été lue une fois.
  bool get loaded => _loaded;

  /// Une réponse est en cours dans [id].
  bool isRunning(int id) => _running.contains(id);

  /// Une réponse est en cours, dans une conversation au moins (point d'activité du module IA).
  bool get busy => _running.isNotEmpty;

  /// Conversation [id] si elle a été ouverte ([open]).
  ChatThread? thread(int id) => _threads[id];

  /// Texte affiché du message [m] : ce qui est déjà arrivé, pour une réponse en cours.
  String textOf(ChatMessageMsg m) => _live[m.id]?.toString() ?? m.content;

  Future<void> load() async {
    _list = await api.conversations();
    _running
      ..clear()
      ..addAll(await api.runningChats());
    _loaded = true;
    _threads.removeWhere((id, _) => !_list.any((c) => c.id == id));
    notifyListeners();
  }

  /// Lit la conversation [id] et la garde.
  Future<ChatThread> open(int id) async {
    final d = await api.conversation(id);
    final t = ChatThread(d.conversation, List.of(d.messages));
    _threads[id] = t;
    notifyListeners();
    return t;
  }

  Future<ConversationMsg> create(String? serverId, String? model) async {
    final c = await api.createConversation(serverId, model);
    _threads[c.id] = ChatThread(c, []);
    await load();
    return c;
  }

  /// Envoie [text] dans [id] et lance la réponse. Erreurs (réponse déjà en cours, aucun modèle…) rendues telles
  /// quelles : rien n'est alors écrit.
  Future<void> send(int id, String text) async {
    await api.sendChatMessage(id, text);
    _running.add(id);
    await _reload(id);
  }

  Future<void> stop(int id) => api.stopGeneration(id);

  /// Remplace la dernière réponse par une nouvelle ; sert aussi à « Réessayer ».
  Future<void> regenerate(int id) async {
    await api.regenerate(id);
    _running.add(id);
    await _reload(id);
  }

  Future<void> rename(int id, String title) async {
    await api.renameConversation(id, title);
    await _reload(id);
  }

  Future<void> delete(int id) async {
    await api.deleteConversation(id);
    _threads.remove(id);
    await load();
  }

  Future<void> setModel(int id, String? serverId, String? model) async {
    await api.setConversationModel(id, serverId, model);
    await _reload(id);
  }

  Future<void> setSystemPrompt(int id, String? prompt) async {
    await api.setSystemPrompt(id, prompt);
    await _reload(id);
  }

  /// Relit la conversation [id] (si elle est ouverte) et la liste (titre automatique, ordre).
  Future<void> _reload(int id) async {
    if (_threads.containsKey(id)) await open(id);
    await load();
  }

  void onChatDelta(int conversationId, int messageId, String text) {
    _running.add(conversationId);
    (_live[messageId] ??= StringBuffer()).write(text);
    notifyListeners();
  }

  void onChatState(ChatMessageMsg message) {
    _live.remove(message.id);
    _running.remove(message.conversationId);
    final t = _threads[message.conversationId];
    if (t != null) {
      final i = t.messages.indexWhere((m) => m.id == message.id);
      if (i >= 0) {
        t.messages[i] = message;
      } else {
        t.messages.add(message);
      }
    }
    notifyListeners();
    unawaited(load().catchError((Object _) {}, test: (e) => e is PlatformException));
  }
}

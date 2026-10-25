import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:fluluks/src/ai/ai_api.dart';
import 'package:fluluks/src/bridge/fluluks_api.g.dart';

/// Faux pont de l'intégration IA (phase 15) : serveurs en mémoire, appels enregistrés. Les octets de clé sont copiés
/// à l'appel et la référence d'origine gardée, pour vérifier qu'elle est mise à zéro ensuite.
mixin FakeAiApi implements AiApi {
  final aiServerList = <AiServerMsg>[];
  final aiCalls = <String>[];

  /// Clé reçue par le dernier `saveAiServer` (copie) et la référence d'origine.
  String? aiKeyCopy;
  Uint8List? aiKeyRef;

  /// État rendu par `aiHealth`, par serveur (défaut : en ligne).
  final aiHealthById = <String, AiHealthMsg>{};

  /// Modèles rendus par `aiModels`, par serveur (défaut : deux modèles).
  final aiModelsById = <String, List<String>>{};

  /// Réponse de `testAiServer` (défaut : réussite, version 0.1.0, deux modèles).
  AiTestResultMsg? aiTestResult;
  List<String> aiLog = ['10:00:00.000  GET /health → 200 (12 ms, 33 car.)'];

  /// Erreur levée par le prochain appel de modification, s'il y en a une.
  PlatformException? aiSaveError;

  int _aiNext = 1;

  AiServerMsg _copy(AiServerMsg s, {bool? isDefault, String? defaultModel, bool clearModel = false, bool? hasKey}) =>
      AiServerMsg(
        id: s.id,
        name: s.name,
        baseUrl: s.baseUrl,
        hasKey: hasKey ?? s.hasKey,
        isDefault: isDefault ?? s.isDefault,
        defaultModel: clearModel ? null : defaultModel ?? s.defaultModel,
      );

  @override
  Future<List<AiServerMsg>> aiServers() async => List.of(aiServerList);

  @override
  Future<AiServerMsg> saveAiServer(AiServerMsg server, Uint8List? key) async {
    aiCalls.add('saveAiServer ${server.id} ${server.name} ${server.baseUrl} ${key == null ? 'sans clé' : 'clé'}');
    aiKeyRef = key;
    aiKeyCopy = key == null ? null : utf8.decode(List<int>.of(key));
    final e = aiSaveError;
    if (e != null) throw e;
    final i = aiServerList.indexWhere((s) => s.id == server.id && server.id.isNotEmpty);
    final old = i >= 0 ? aiServerList[i] : null;
    final saved = AiServerMsg(
      id: old?.id ?? 'ai${_aiNext++}',
      name: server.name.isEmpty ? Uri.parse(server.baseUrl).host : server.name,
      baseUrl: server.baseUrl,
      hasKey: (old?.hasKey ?? false) || (key != null && key.isNotEmpty),
      isDefault: old?.isDefault ?? aiServerList.every((s) => !s.isDefault),
      defaultModel: old?.defaultModel,
    );
    if (i >= 0) {
      aiServerList[i] = saved;
    } else {
      aiServerList.add(saved);
    }
    return saved;
  }

  @override
  Future<void> removeAiServerKey(String serverId) async {
    aiCalls.add('removeAiServerKey $serverId');
    final i = aiServerList.indexWhere((s) => s.id == serverId);
    if (i >= 0) aiServerList[i] = _copy(aiServerList[i], hasKey: false);
  }

  @override
  Future<void> deleteAiServer(String serverId) async {
    aiCalls.add('deleteAiServer $serverId');
    final wasDefault = aiServerList.any((s) => s.id == serverId && s.isDefault);
    aiServerList.removeWhere((s) => s.id == serverId);
    if (wasDefault && aiServerList.isNotEmpty) aiServerList[0] = _copy(aiServerList[0], isDefault: true);
  }

  @override
  Future<void> setDefaultAiServer(String serverId) async {
    aiCalls.add('setDefaultAiServer $serverId');
    for (var i = 0; i < aiServerList.length; i++) {
      aiServerList[i] = _copy(aiServerList[i], isDefault: aiServerList[i].id == serverId);
    }
  }

  @override
  Future<AiTestResultMsg> testAiServer(String serverId) async {
    aiCalls.add('testAiServer $serverId');
    return aiTestResult ?? AiTestResultMsg(ok: true, version: '0.1.0', models: ['essai-court', 'essai-long'], log: aiLog);
  }

  @override
  Future<List<String>> aiModels(String serverId) async {
    aiCalls.add('aiModels $serverId');
    return aiModelsById[serverId] ?? ['essai-court', 'essai-long'];
  }

  @override
  Future<void> setAiDefaultModel(String serverId, String? model) async {
    aiCalls.add('setAiDefaultModel $serverId $model');
    final i = aiServerList.indexWhere((s) => s.id == serverId);
    if (i >= 0) aiServerList[i] = _copy(aiServerList[i], defaultModel: model, clearModel: model == null);
  }

  @override
  Future<AiHealthMsg> aiHealth(String serverId) async {
    aiCalls.add('aiHealth $serverId');
    return aiHealthById[serverId] ?? AiHealthMsg(serverId: serverId, state: 'online', version: '0.1.0', modelCount: 2);
  }

  @override
  Future<List<String>> aiAttemptLog(String serverId) async => List.of(aiLog);

  // --- historique des conversations (T5), en mémoire

  final chatConversations = <ConversationMsg>[];
  final chatMessages = <int, List<ChatMessageMsg>>{};
  int _chatNext = 1;
  int chatClock = 1000;

  ConversationMsg _conv(int id) => chatConversations.firstWhere(
        (c) => c.id == id,
        orElse: () => throw PlatformException(code: '-8', message: 'Cette conversation n\'existe plus'),
      );

  void _replaceConv(ConversationMsg c) => chatConversations[chatConversations.indexWhere((x) => x.id == c.id)] = c;

  ConversationMsg _copyConv(ConversationMsg c, {String? title, String? serverId, String? model, String? systemPrompt,
          bool keepServer = true, int? updatedAt}) =>
      ConversationMsg(
        id: c.id,
        title: title ?? c.title,
        serverId: keepServer ? c.serverId : serverId,
        model: keepServer ? c.model : model,
        systemPrompt: systemPrompt ?? c.systemPrompt,
        createdAt: c.createdAt,
        updatedAt: updatedAt ?? c.updatedAt,
      );

  @override
  Future<List<ConversationMsg>> conversations() async =>
      List.of(chatConversations)..sort((a, b) => b.updatedAt != a.updatedAt ? b.updatedAt - a.updatedAt : b.id - a.id);

  @override
  Future<ConversationDetailMsg> conversation(int id) async =>
      ConversationDetailMsg(conversation: _conv(id), messages: List.of(chatMessages[id] ?? const []));

  @override
  Future<ConversationMsg> createConversation(String? serverId, String? model) async {
    aiCalls.add('createConversation $serverId $model');
    AiServerMsg? s;
    for (final x in aiServerList) {
      if (serverId == null ? x.isDefault : x.id == serverId) s = x;
    }
    final t = chatClock++;
    final c = ConversationMsg(
      id: _chatNext++,
      title: '',
      serverId: serverId ?? s?.id,
      model: model ?? s?.defaultModel,
      createdAt: t,
      updatedAt: t,
    );
    chatConversations.add(c);
    return c;
  }

  @override
  Future<void> renameConversation(int id, String title) async {
    aiCalls.add('renameConversation $id $title');
    _replaceConv(_copyConv(_conv(id), title: title.trim()));
  }

  @override
  Future<void> deleteConversation(int id) async {
    aiCalls.add('deleteConversation $id');
    chatConversations.removeWhere((c) => c.id == id);
    chatMessages.remove(id);
  }

  @override
  Future<void> setConversationModel(int id, String? serverId, String? model) async {
    aiCalls.add('setConversationModel $id $serverId $model');
    _replaceConv(_copyConv(_conv(id), keepServer: false, serverId: serverId, model: model));
  }

  @override
  Future<void> setSystemPrompt(int id, String? prompt) async {
    aiCalls.add('setSystemPrompt $id $prompt');
    final c = _conv(id);
    final p = prompt?.trim();
    _replaceConv(ConversationMsg(
      id: c.id,
      title: c.title,
      serverId: c.serverId,
      model: c.model,
      systemPrompt: p == null || p.isEmpty ? null : p,
      createdAt: c.createdAt,
      updatedAt: c.updatedAt,
    ));
  }

  // --- réponses en flux (T6) : la réponse reste « en cours » ; le test la termine par [finishFakeReply]

  final chatRunning = <int>{};
  int _msgNext = 1;

  /// Erreur levée par le prochain `sendChatMessage`, s'il y en a une (rien n'est alors écrit).
  PlatformException? chatSendError;

  ChatMessageMsg _msg(int conv, String role, String content, String state) => ChatMessageMsg(
        id: _msgNext++,
        conversationId: conv,
        role: role,
        content: content,
        state: state,
        createdAt: chatClock++,
      );

  @override
  Future<ChatMessageMsg> sendChatMessage(int conversationId, String text) async {
    aiCalls.add('sendChatMessage $conversationId $text');
    final e = chatSendError;
    if (e != null) {
      chatSendError = null;
      throw e;
    }
    final c = _conv(conversationId);
    final list = chatMessages.putIfAbsent(conversationId, () => []);
    list.add(_msg(conversationId, 'user', text, 'done'));
    if (c.title.isEmpty) _replaceConv(_copyConv(c, title: text.trim()));
    final reply = _msg(conversationId, 'assistant', '', 'streaming');
    list.add(reply);
    chatRunning.add(conversationId);
    return reply;
  }

  @override
  Future<void> stopGeneration(int conversationId) async {
    aiCalls.add('stopGeneration $conversationId');
    chatRunning.remove(conversationId);
  }

  @override
  Future<ChatMessageMsg> regenerate(int conversationId) async {
    aiCalls.add('regenerate $conversationId');
    final list = chatMessages.putIfAbsent(conversationId, () => []);
    if (list.isNotEmpty && list.last.role == 'assistant') list.removeLast();
    final reply = _msg(conversationId, 'assistant', '', 'streaming');
    list.add(reply);
    chatRunning.add(conversationId);
    return reply;
  }

  @override
  Future<List<int>> runningChats() async => chatRunning.toList();

  /// Termine la réponse en cours de [conversationId] côté faux pont et la rend (à pousser par `onChatState`).
  ChatMessageMsg finishFakeReply(int conversationId, String content,
      {String state = 'done', String? error, String? errorDetail}) {
    chatRunning.remove(conversationId);
    final list = chatMessages[conversationId]!;
    final last = list.last;
    final done = ChatMessageMsg(
      id: last.id,
      conversationId: conversationId,
      role: last.role,
      content: content,
      state: state,
      error: error,
      errorDetail: errorDetail,
      createdAt: last.createdAt,
    );
    list[list.length - 1] = done;
    return done;
  }

  // --- automatisations (T8), en mémoire ; un lancement reste « en cours » jusqu'à [finishFakeRun]

  final automationList = <AutomationMsg>[];
  final automationRunList = <AutomationRunMsg>[];
  final automationRunning = <int>{};
  int _autoNext = 1;
  int _runNext = 1;

  /// Erreur levée par le prochain `saveAutomation`, s'il y en a une.
  PlatformException? automationSaveError;

  static final _placeholder = RegExp(r'\{\{\s*([\p{L}_][\p{L}\p{N}_]*)\s*\}\}', unicode: true);

  AutomationRunMsg? _lastRunOf(int id) {
    final runs = automationRunList.where((r) => r.automationId == id).toList();
    return runs.isEmpty ? null : runs.last;
  }

  AutomationMsg _withRun(AutomationMsg a) => AutomationMsg(
        id: a.id,
        name: a.name,
        template: a.template,
        variables: a.variables,
        serverId: a.serverId,
        model: a.model,
        systemPrompt: a.systemPrompt,
        trigger: a.trigger,
        intervalMinutes: a.intervalMinutes,
        enabled: a.enabled,
        lastRun: _lastRunOf(a.id),
      );

  AutomationMsg _auto(int id) => automationList.firstWhere(
        (a) => a.id == id,
        orElse: () => throw PlatformException(code: '-8', message: "Cette automatisation n'existe plus"),
      );

  @override
  Future<List<AutomationMsg>> automations() async => [for (final a in automationList) _withRun(a)];

  @override
  Future<AutomationMsg> saveAutomation(AutomationMsg automation) async {
    aiCalls.add('saveAutomation ${automation.id} ${automation.name} ${automation.trigger} ${automation.intervalMinutes}');
    final e = automationSaveError;
    if (e != null) {
      automationSaveError = null;
      throw e;
    }
    final names = await templateVariables(automation.template);
    final byName = {for (final v in automation.variables) v.name: v};
    final saved = AutomationMsg(
      id: automation.id == 0 ? _autoNext++ : automation.id,
      name: automation.name.trim(),
      template: automation.template,
      variables: [for (final n in names) AutomationVarMsg(name: n, defaultValue: byName[n]?.defaultValue)],
      serverId: automation.serverId ?? aiServerList.where((x) => x.isDefault).firstOrNull?.id,
      model: automation.model ?? aiServerList.where((x) => x.isDefault).firstOrNull?.defaultModel,
      systemPrompt: automation.systemPrompt,
      trigger: automation.trigger,
      intervalMinutes: automation.trigger == 'periodic' ? automation.intervalMinutes : null,
      enabled: automation.enabled,
    );
    final i = automationList.indexWhere((a) => a.id == saved.id);
    if (i >= 0) {
      automationList[i] = saved;
    } else {
      automationList.add(saved);
    }
    return _withRun(saved);
  }

  @override
  Future<void> deleteAutomation(int id) async {
    aiCalls.add('deleteAutomation $id');
    automationList.removeWhere((a) => a.id == id);
    automationRunList.removeWhere((r) => r.automationId == id);
  }

  @override
  Future<AutomationMsg> setAutomationEnabled(int id, bool enabled) async {
    aiCalls.add('setAutomationEnabled $id $enabled');
    final a = _auto(id);
    a.enabled = enabled;
    return _withRun(a);
  }

  @override
  Future<AutomationMsg> duplicateAutomation(int id) async {
    aiCalls.add('duplicateAutomation $id');
    final a = _auto(id);
    final copy = AutomationMsg(
      id: _autoNext++,
      name: '${a.name} (copie)',
      template: a.template,
      variables: a.variables,
      serverId: a.serverId,
      model: a.model,
      systemPrompt: a.systemPrompt,
      trigger: a.trigger,
      intervalMinutes: a.intervalMinutes,
      enabled: false,
    );
    automationList.add(copy);
    return copy;
  }

  @override
  Future<List<String>> templateVariables(String template) async {
    final out = <String>[];
    for (final m in _placeholder.allMatches(template)) {
      final n = m.group(1)!;
      if (n != 'date' && n != 'heure' && !out.contains(n)) out.add(n);
    }
    return out;
  }

  @override
  Future<AutomationRunMsg> runAutomation(int id, Map<String, String> values) async {
    aiCalls.add('runAutomation $id ${values.entries.map((e) => '${e.key}=${e.value}').join(',')}');
    final a = _auto(id);
    final defaults = {for (final v in a.variables) if (v.defaultValue != null) v.name: v.defaultValue!};
    final all = {...defaults, ...values};
    final input = a.template.replaceAllMapped(_placeholder, (m) => all[m.group(1)] ?? m.group(0)!);
    final r = AutomationRunMsg(
      id: _runNext++,
      automationId: id,
      startedAt: chatClock++,
      state: 'running',
      scheduled: false,
      input: input,
    );
    automationRunList.add(r);
    automationRunning.add(r.id);
    return r;
  }

  @override
  Future<void> stopAutomationRun(int runId) async {
    aiCalls.add('stopAutomationRun $runId');
    automationRunning.remove(runId);
  }

  @override
  Future<List<int>> runningAutomationRuns() async => automationRunning.toList();

  @override
  Future<List<AutomationRunMsg>> automationRuns(int automationId) async =>
      automationRunList.where((r) => r.automationId == automationId).toList().reversed.toList();

  @override
  Future<AutomationRunMsg> automationRun(int runId) async => automationRunList.firstWhere(
        (r) => r.id == runId,
        orElse: () => throw PlatformException(code: '-8', message: "Cette exécution n'existe plus"),
      );

  @override
  Future<void> clearAutomationRuns(int automationId) async {
    aiCalls.add('clearAutomationRuns $automationId');
    automationRunList.removeWhere((r) => r.automationId == automationId);
  }

  /// Termine l'exécution [runId] côté faux pont et la rend (à pousser par `onAutomationState`).
  AutomationRunMsg finishFakeRun(int runId, String? output,
      {String state = 'done', String? error, String? errorDetail, bool scheduled = false}) {
    automationRunning.remove(runId);
    final i = automationRunList.indexWhere((r) => r.id == runId);
    final r = automationRunList[i];
    final done = AutomationRunMsg(
      id: r.id,
      automationId: r.automationId,
      startedAt: r.startedAt,
      endedAt: chatClock++,
      state: state,
      scheduled: scheduled || r.scheduled,
      input: r.input,
      output: output,
      error: error,
      errorDetail: errorDetail,
    );
    automationRunList[i] = done;
    return done;
  }
}

/// Serveur IA de démonstration.
AiServerMsg aiServer(String id, String name, String url, {bool isDefault = false, bool hasKey = true, String? model}) =>
    AiServerMsg(id: id, name: name, baseUrl: url, hasKey: hasKey, isDefault: isDefault, defaultModel: model);

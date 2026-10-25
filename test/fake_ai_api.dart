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
}

/// Serveur IA de démonstration.
AiServerMsg aiServer(String id, String name, String url, {bool isDefault = false, bool hasKey = true, String? model}) =>
    AiServerMsg(id: id, name: name, baseUrl: url, hasKey: hasKey, isDefault: isDefault, defaultModel: model);

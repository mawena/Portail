import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../bridge/fluluks_api.g.dart';
import 'ai_api.dart';

/// État des serveurs IA (phase 15), copie de ce que Kotlin publie, tenu hors des écrans (dans `AppState`). L'état en
/// ligne de chaque serveur est vérifié à l'ouverture d'un écran IA puis toutes les [healthEvery] tant qu'un écran IA
/// est affiché ([watch] et [unwatch]) ; jamais en arrière-plan.
class AiHub extends ChangeNotifier {
  AiHub(this.api);

  final AiApi api;

  static const healthEvery = Duration(seconds: 60);

  List<AiServerMsg> _servers = const [];
  bool _loaded = false;
  final _health = <String, AiHealthMsg>{};
  final _checking = <String>{};
  int _watchers = 0;
  Timer? _timer;

  /// Serveurs enregistrés, dans l'ordre d'ajout.
  List<AiServerMsg> get servers => _servers;

  /// Vrai dès que la liste a été lue une fois.
  bool get loaded => _loaded;

  AiServerMsg? server(String id) {
    for (final s in _servers) {
      if (s.id == id) return s;
    }
    return null;
  }

  AiServerMsg? get defaultServer {
    for (final s in _servers) {
      if (s.isDefault) return s;
    }
    return _servers.isEmpty ? null : _servers.first;
  }

  /// Dernier état connu de [id] (null : pas encore vérifié).
  AiHealthMsg? health(String id) => _health[id];

  /// `online`, `offline`, `key-refused`, ou `unknown` (jamais vérifié, vérification en cours).
  String status(String id) => _health[id]?.state ?? 'unknown';

  bool isChecking(String id) => _checking.contains(id);

  Future<void> load() async {
    _servers = await api.aiServers();
    _loaded = true;
    _health.removeWhere((id, _) => server(id) == null);
    notifyListeners();
  }

  /// Un écran IA s'affiche : vérification tout de suite, puis toutes les [healthEvery].
  void watch() {
    if (_watchers++ > 0) return;
    unawaited(_tick());
    _timer = Timer.periodic(healthEvery, (_) => unawaited(_tick()));
  }

  /// L'écran IA se ferme : plus aucune vérification quand il n'y en a plus.
  void unwatch() {
    if (_watchers == 0 || --_watchers > 0) return;
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _tick() async {
    try {
      await load();
    } on PlatformException {
      return;
    }
    await Future.wait([for (final s in _servers) checkHealth(s.id)]);
  }

  Future<void> checkHealth(String id) async {
    if (!_checking.add(id)) return;
    notifyListeners();
    try {
      _health[id] = await api.aiHealth(id);
    } on PlatformException catch (e) {
      _health[id] = AiHealthMsg(serverId: id, state: 'offline', error: e.message, detail: e.details as String?);
    } finally {
      _checking.remove(id);
      notifyListeners();
    }
  }

  /// Enregistre [s] ; [key] (facultative) est mise à zéro après l'appel, sur tous les chemins.
  Future<AiServerMsg> save(AiServerMsg s, Uint8List? key) async {
    try {
      final saved = await api.saveAiServer(s, key);
      await load();
      if (_watchers > 0) unawaited(checkHealth(saved.id));
      return saved;
    } finally {
      key?.fillRange(0, key.length, 0);
    }
  }

  Future<void> removeKey(String id) async {
    await api.removeAiServerKey(id);
    await load();
  }

  Future<void> delete(String id) async {
    await api.deleteAiServer(id);
    _health.remove(id);
    await load();
  }

  Future<void> setDefault(String id) async {
    await api.setDefaultAiServer(id);
    await load();
  }

  Future<void> setDefaultModel(String id, String? model) async {
    await api.setAiDefaultModel(id, model);
    await load();
  }

  Future<AiTestResultMsg> test(String id) async {
    final r = await api.testAiServer(id);
    if (r.ok) {
      _health[id] = AiHealthMsg(serverId: id, state: 'online', version: r.version, modelCount: r.models.length);
      notifyListeners();
    } else {
      unawaited(checkHealth(id)); // hors ligne ou clé refusée : l'indicateur le dit
    }
    return r;
  }

  Future<List<String>> models(String id) => api.aiModels(id);

  Future<List<String>> attemptLog(String id) => api.aiAttemptLog(id);

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../bridge/fluluks_api.g.dart';
import 'ai_api.dart';

/// Automatisations côté Dart (phase 15) : la liste publiée par Kotlin, et le texte reçu de chaque lancement manuel en
/// cours, gardé ici hors de tout écran (Kotlin ne l'écrit dans l'historique qu'à la fin) pour qu'un écran rouvert le
/// retrouve. Kotlin pousse les lots ([onRunDelta]) et la fin ([onRunState]) par `AiEvents`.
class AutomationHub extends ChangeNotifier {
  AutomationHub(this.api);

  final AiApi api;

  List<AutomationMsg> _list = const [];
  bool _loaded = false;
  final _running = <int>{};
  final _live = <int, StringBuffer>{};
  final _finished = <int, AutomationRunMsg>{};

  /// Automatisations, dans l'ordre de création.
  List<AutomationMsg> get automations => _list;

  /// Vrai dès que la liste a été lue une fois.
  bool get loaded => _loaded;

  AutomationMsg? automation(int id) {
    for (final a in _list) {
      if (a.id == id) return a;
    }
    return null;
  }

  /// Le lancement [runId] est en cours.
  bool isRunning(int runId) => _running.contains(runId);

  /// Un lancement au moins est en cours (point d'activité du module IA).
  bool get busy => _running.isNotEmpty;

  /// Texte reçu du lancement [runId] tant qu'il est en cours.
  String? liveText(int runId) => _live[runId]?.toString();

  /// Lancement [runId] terminé pendant que Portail était ouvert (null : en cours, ou inconnu).
  AutomationRunMsg? finished(int runId) => _finished[runId];

  Future<void> load() async {
    _list = await api.automations();
    _running
      ..clear()
      ..addAll(await api.runningAutomationRuns());
    _loaded = true;
    notifyListeners();
  }

  /// Enregistre [a] (id 0 : nouvelle) ; erreurs de la fiche rendues telles quelles.
  Future<AutomationMsg> save(AutomationMsg a) async {
    final saved = await api.saveAutomation(a);
    await load();
    return saved;
  }

  Future<void> delete(int id) async {
    await api.deleteAutomation(id);
    await load();
  }

  Future<void> setEnabled(int id, bool enabled) async {
    await api.setAutomationEnabled(id, enabled);
    await load();
  }

  Future<AutomationMsg> duplicate(int id) async {
    final copy = await api.duplicateAutomation(id);
    await load();
    return copy;
  }

  /// Variables à saisir de [template] (sans `date` ni `heure`), dans l'ordre.
  Future<List<String>> variables(String template) => api.templateVariables(template);

  /// Lancement manuel : [values] saisies ; rend l'exécution « en cours ».
  Future<AutomationRunMsg> run(int id, Map<String, String> values) async {
    final r = await api.runAutomation(id, values);
    _running.add(r.id);
    notifyListeners();
    return r;
  }

  Future<void> stop(int runId) => api.stopAutomationRun(runId);

  /// Plus récente d'abord.
  Future<List<AutomationRunMsg>> runs(int automationId) => api.automationRuns(automationId);

  Future<AutomationRunMsg> runById(int runId) => api.automationRun(runId);

  Future<void> clearRuns(int automationId) async {
    await api.clearAutomationRuns(automationId);
    await load();
  }

  void onRunDelta(int runId, String text) {
    _running.add(runId);
    (_live[runId] ??= StringBuffer()).write(text);
    notifyListeners();
  }

  void onRunState(AutomationRunMsg run) {
    _live.remove(run.id);
    _running.remove(run.id);
    _finished[run.id] = run;
    notifyListeners();
    unawaited(load().catchError((Object _) {}, test: (e) => e is PlatformException)); // dernière exécution
  }
}

import 'package:flutter/foundation.dart';

import '../bridge/fluluks_api.g.dart';
import 'ai_api.dart';

/// Lancements manuels des automatisations côté Dart (phase 15) : le texte reçu de chaque exécution en cours est gardé
/// ici, hors de tout écran (Kotlin ne l'écrit dans l'historique qu'à la fin), pour qu'un écran rouvert le retrouve.
/// Kotlin pousse les lots ([onRunDelta]) et la fin ([onRunState]) par `AiEvents`.
class AutomationHub extends ChangeNotifier {
  AutomationHub(this.api);

  final AiApi api;

  final _live = <int, StringBuffer>{};
  final _finished = <int, AutomationRunMsg>{};

  /// Texte reçu de l'exécution [runId] tant qu'elle est en cours.
  String? liveText(int runId) => _live[runId]?.toString();

  /// Exécution [runId] terminée pendant que Portail était ouvert (null : en cours, ou inconnue).
  AutomationRunMsg? finished(int runId) => _finished[runId];

  void onRunDelta(int runId, String text) {
    (_live[runId] ??= StringBuffer()).write(text);
    notifyListeners();
  }

  void onRunState(AutomationRunMsg run) {
    _live.remove(run.id);
    _finished[run.id] = run;
    notifyListeners();
  }
}

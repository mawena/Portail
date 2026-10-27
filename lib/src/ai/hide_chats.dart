import 'package:flutter/widgets.dart';

import '../state/app_state.dart';

/// Écrans des conversations et des résultats d'automatisations (phase 15) : masqués dans les captures et les
/// applications récentes tant qu'ils sont ouverts, si le réglage « Masquer les conversations » est activé.
mixin HideChats<T extends StatefulWidget> on State<T> {
  AppState get appState;

  bool _held = false;

  @override
  void initState() {
    super.initState();
    if (appState.hideChats) {
      _held = true;
      appState.holdSecure();
    }
  }

  @override
  void dispose() {
    if (_held) appState.releaseSecure();
    super.dispose();
  }
}

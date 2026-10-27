import 'package:flutter/material.dart';

import '../strings_fr.dart';
import '../ui/widgets.dart';

/// État d'un serveur IA : en ligne, hors ligne, clé refusée ou inconnu. Lisible sans la couleur : chaque état a son
/// icône et son texte ; [checking] : vérification en cours (texte inchangé, l'icône tourne en sablier).
class AiStatusDot extends StatelessWidget {
  const AiStatusDot({super.key, required this.state, this.checking = false});

  /// `online`, `offline`, `key-refused` ou `unknown`.
  final String state;
  final bool checking;

  static IconData iconFor(String state) => switch (state) {
        'online' => Icons.check_circle_rounded,
        'offline' => Icons.cloud_off_rounded,
        'key-refused' => Icons.key_off_rounded,
        _ => Icons.help_outline_rounded,
      };

  static ChipTone toneFor(String state) => switch (state) {
        'online' => ChipTone.good,
        'offline' => ChipTone.danger,
        'key-refused' => ChipTone.warning,
        _ => ChipTone.neutral,
      };

  @override
  Widget build(BuildContext context) => StatusChip(
        label: Fr.aiStatusLabel(state),
        icon: checking && state == 'unknown' ? Icons.hourglass_empty_rounded : iconFor(state),
        tone: toneFor(state),
      );
}

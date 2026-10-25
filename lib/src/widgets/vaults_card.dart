import 'package:flutter/material.dart';

import '../screens/vault_create_screen.dart';
import '../state/app_state.dart';
import '../strings_fr.dart';
import '../ui/tokens.dart';
import '../ui/widgets.dart';
import 'vault_tile.dart';

/// Section « Coffres » de l'accueil (phase 14) : les coffres connus (fermés, ouverts ou indisponibles), puis
/// « Créer un coffre » (sur le premier stockage possible ; l'emplacement se change dans l'écran de création).
class VaultsSection extends StatelessWidget {
  const VaultsSection({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final host = state.sources.where(canHoldVault).firstOrNull;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SectionHeader(Fr.vaults),
      if (state.vaults.isEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: Space.s),
          child: Text(Fr.vaultsEmpty,
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ),
      // clé sur l'élément de la colonne : un coffre qui change de place garde sa tuile (et l'ouverture en cours)
      for (final v in state.vaults)
        Padding(
          key: ValueKey(v.id),
          padding: const EdgeInsets.only(bottom: Space.s),
          child: VaultTile(state: state, vault: v),
        ),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextButton.icon(
          icon: const Icon(Icons.add_rounded),
          label: const Text(Fr.createVault),
          onPressed: host == null ? null : () => openVaultCreate(context, state, sourceId: host.id),
        ),
      ),
    ]);
  }
}

import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../strings_fr.dart';
import '../ui/states.dart';
import '../ui/tokens.dart';
import '../widgets/bottom_dock.dart';
import '../widgets/vault_tile.dart';
import 'module_shell.dart';
import 'vault_create_screen.dart';

/// Racine du module « Coffres » (phase 16, demande du 2026-10-27) : les coffres connus (fermés, ouverts ou
/// indisponibles), puis « Créer un coffre » (sur le premier stockage possible ; l'emplacement se change dans l'écran de
/// création). Aucun coffre : écran vide qui explique et propose d'en créer un. Le contenu d'un coffre ouvert s'affiche
/// dans ce module.
class VaultsHomeScreen extends StatelessWidget {
  const VaultsHomeScreen({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text(Fr.moduleVaults), actions: moduleActions(context, state)),
      bottomNavigationBar: BottomDock(state: state),
      body: ListenableBuilder(
        listenable: state,
        builder: (context, _) {
          final host = state.sources.where(canHoldVault).firstOrNull;
          void create() => openVaultCreate(context, state, sourceId: host!.id);
          if (state.vaults.isEmpty) {
            return EmptyState(
              icon: Icons.lock_outline_rounded,
              title: Fr.vaultsNoneTitle,
              message: Fr.vaultsEmpty,
              action: FilledButton.icon(
                icon: const Icon(Icons.add_rounded),
                label: const Text(Fr.createVault),
                onPressed: host == null ? null : create,
              ),
            );
          }
          return ListView(padding: const EdgeInsets.all(Space.l), children: [
            // clé sur l'élément de la liste : un coffre qui change de place garde sa tuile (et l'ouverture en cours)
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
                onPressed: host == null ? null : create,
              ),
            ),
          ]);
        },
      ),
    );
  }
}

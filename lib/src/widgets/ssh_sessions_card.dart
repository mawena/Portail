import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../strings_fr.dart';
import '../terminal/terminal_hub.dart';
import '../terminal/terminal_screen.dart';
import '../ui/dialogs.dart';
import '../ui/tokens.dart';
import '../ui/widgets.dart';

/// Section « Sessions SSH » de l'accueil (phase 13), tant qu'un terminal est ouvert ou gardé fermé : toucher rouvre
/// son écran, la croix ferme la session (confirmé si elle est ouverte).
class SshSessionsCard extends StatelessWidget {
  const SshSessionsCard({super.key, required this.state});

  final AppState state;

  String _status(TerminalEntry e) => switch (e.info.state) {
        'connecting' => Fr.sessionConnecting,
        'open' => Fr.sessionOpen,
        _ => Fr.sessionClosedBecause(e.info.error),
      };

  Future<void> _close(BuildContext context, TerminalEntry e) async {
    if (e.isOpen) {
      final ok = await confirmAction(
        context,
        title: Fr.closeSessionAsk,
        body: Fr.closeSessionHelp,
        confirmLabel: Fr.closeSession,
        destructive: true,
      );
      if (!ok) return;
    }
    state.terminals.close(e.info.id);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SectionHeader(Fr.sshSessions),
      for (final e in state.terminals.sessions)
        Padding(
          padding: const EdgeInsets.only(bottom: Space.s),
          child: Card(
            child: ListTile(
              leading: Icon(
                Icons.terminal_rounded,
                color: e.isClosed ? scheme.onSurfaceVariant : scheme.primary,
              ),
              title: Text(e.title, overflow: TextOverflow.ellipsis),
              subtitle: Text(_status(e)),
              onTap: () => showTerminal(context, state, e.info.id),
              trailing: IconButton(
                tooltip: Fr.closeSession,
                icon: const Icon(Icons.close_rounded),
                onPressed: () => _close(context, e),
              ),
            ),
          ),
        ),
    ]);
  }
}

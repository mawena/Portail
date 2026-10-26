import 'package:flutter/material.dart';

import '../bridge/fluluks_api.g.dart';
import '../state/app_state.dart';
import '../strings_fr.dart';
import '../terminal/tunnels_screen.dart';
import '../ui/sheets.dart';
import '../ui/states.dart';
import '../ui/tokens.dart';
import '../ui/widgets.dart';
import '../widgets/bottom_dock.dart';
import '../widgets/server_tile.dart';
import '../widgets/source_tile.dart';
import '../widgets/ssh_sessions_card.dart';
import 'module_shell.dart';
import 'server_form_screen.dart';
import 'ssh_keys_screen.dart';

/// Racine du module « Distants » (phase 16, T1) : serveurs enregistrés et « Ajouter un serveur », sessions SSH
/// ouvertes, tunnels et clés SSH. Aucun serveur : écran vide qui invite à en ajouter un.
class RemoteHomeScreen extends StatelessWidget {
  const RemoteHomeScreen({super.key, required this.state});

  final AppState state;

  void _addServer(BuildContext context) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ServerFormScreen(state: state)));

  /// Tunnels d'un serveur SFTP, avec sa session ouverte s'il en a une ; plusieurs serveurs : choisi d'abord.
  Future<void> _tunnels(BuildContext context, List<RemoteServerMsg> sftp) async {
    final id = sftp.length == 1
        ? sftp.single.id
        : await showActionSheet<String>(context, title: Fr.tunnelsChooseServer, actions: [
            for (final s in sftp) SheetAction(s.id, Icons.dns_rounded, s.name, subtitle: '${s.user}@${s.host}'),
          ]);
    if (id == null || !context.mounted) return;
    final session = state.terminals.sessions.where((e) => e.info.serverId == id && e.isOpen).firstOrNull;
    await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => TunnelsScreen(state: state, serverId: id, sessionId: session?.info.id)));
  }

  Widget _gap(Widget child) => Padding(padding: const EdgeInsets.only(bottom: Space.s), child: child);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text(Fr.moduleRemote), actions: moduleActions(context, state)),
      bottomNavigationBar: BottomDock(state: state),
      body: ListenableBuilder(
        listenable: Listenable.merge([state, state.terminals]),
        builder: (context, _) {
          final servers = state.servers;
          if (servers.isEmpty && state.terminals.sessions.isEmpty) {
            return EmptyState(
              icon: Icons.cloud_outlined,
              title: Fr.remoteNoServers,
              message: Fr.remoteNoServersBody,
              action: FilledButton.icon(
                icon: const Icon(Icons.add_rounded),
                label: const Text(Fr.addServer),
                onPressed: () => _addServer(context),
              ),
            );
          }
          final sftp = servers.where((s) => s.protocol == 'sftp').toList();
          return ListView(padding: const EdgeInsets.all(Space.l), children: [
            const SectionHeader(Fr.remoteFolders),
            for (final s in servers) _gap(ServerTile(state: state, server: s)),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                icon: const Icon(Icons.add_rounded),
                label: const Text(Fr.addServer),
                onPressed: () => _addServer(context),
              ),
            ),
            if (state.terminals.sessions.isNotEmpty) SshSessionsCard(state: state),
            const SectionHeader(Fr.sectionSsh),
            _gap(Card(
              clipBehavior: Clip.antiAlias,
              child: ListTile(
                leading: const TonalIcon(Icons.swap_horiz_rounded),
                title: const Text(Fr.tunnels),
                subtitle: Text(sftp.isEmpty ? Fr.tunnelsNeedSftp : Fr.tunnelsHelp),
                trailing: const Icon(Icons.chevron_right_rounded),
                enabled: sftp.isNotEmpty,
                onTap: sftp.isEmpty ? null : () => _tunnels(context, sftp),
              ),
            )),
            _gap(Card(
              clipBehavior: Clip.antiAlias,
              child: ListTile(
                leading: const TonalIcon(Icons.key_rounded),
                title: const Text(Fr.sshKeys),
                subtitle: const Text(Fr.sshKeysHelp),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.of(context)
                    .push(MaterialPageRoute<void>(builder: (_) => SshKeysScreen(state: state))),
              ),
            )),
          ]);
        },
      ),
    );
  }
}

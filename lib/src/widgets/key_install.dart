import 'package:flutter/material.dart';

import '../bridge/fluluks_api.g.dart';
import '../state/app_state.dart';
import '../strings_fr.dart';
import '../ui/dialogs.dart';
import '../ui/feedback.dart';
import '../ui/tokens.dart';
import 'server_tile.dart';

/// Choix d'une clé du trousseau ([keys]) ; null si annulé.
Future<SshKeyMsg?> pickSshKey(BuildContext context, List<SshKeyMsg> keys) => showDialog<SshKeyMsg>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text(Fr.chooseKey),
        children: [
          if (keys.isEmpty)
            const Padding(padding: EdgeInsets.all(Space.l), child: Text(Fr.noKeysBody))
          else
            for (final k in keys)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, k),
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.key_rounded),
                  title: Text(k.name),
                  subtitle: Text('${k.type} ${k.fingerprint}'),
                ),
              ),
        ],
      ),
    );

/// Choix d'un serveur SFTP enregistré ; null si annulé.
Future<RemoteServerMsg?> pickSftpServer(BuildContext context, AppState state) {
  final servers = state.servers.where((s) => s.protocol == 'sftp').toList();
  return showDialog<RemoteServerMsg>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: const Text(Fr.chooseServer),
      children: [
        if (servers.isEmpty)
          const Padding(padding: EdgeInsets.all(Space.l), child: Text(Fr.noSftpServer))
        else
          for (final s in servers)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, s),
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.cloud_outlined),
                title: Text(s.name),
                subtitle: Text('${s.user}@${s.host}:${s.port}'),
              ),
            ),
      ],
    ),
  );
}

/// Installe la clé publique de [key] sur [s] (mot de passe et empreinte demandés comme pour une connexion), puis
/// propose « Utiliser cette clé pour ce serveur ». Rend vrai si le serveur utilise désormais cette clé.
Future<bool> installKeyOnServer(BuildContext context, AppState state, RemoteServerMsg s, SshKeyMsg key) async {
  final msg = await withServerAuth(context, state, s, (pw) => state.api.installPublicKey(s.id, key.id, pw));
  if (msg == null || !context.mounted) return false;
  showMessage(context, msg, kind: MessageKind.success);
  if (s.keyId == key.id) return false;
  final use = await confirmAction(context, title: Fr.useKeyFor(s.name), body: Fr.useKeyHelp, confirmLabel: Fr.useKey);
  if (!use || !context.mounted) return false;
  await state.setServerKey(s.id, key.id);
  return true;
}

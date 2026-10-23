import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../bridge/fluluks_api.g.dart';
import '../screens/explorer_screen.dart';
import '../screens/server_form_screen.dart';
import '../state/app_state.dart';
import '../strings_fr.dart';
import '../ui/feedback.dart';
import '../ui/tokens.dart';
import 'connection_details_sheet.dart';

/// Serveur distant enregistré (accueil) : toucher connecte puis ouvre son dossier de départ ; Déconnecter si la
/// connexion est ouverte ; Modifier ouvre sa fiche.
class ServerTile extends StatelessWidget {
  const ServerTile({super.key, required this.state, required this.server});

  final AppState state;
  final RemoteServerMsg server;

  @override
  Widget build(BuildContext context) {
    final s = server;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: ListTile(
        // connecté : icône pleine, couleur d'un état actif
        leading: Icon(
          s.connected ? Icons.cloud_done_rounded : Icons.cloud_outlined,
          color: s.connected ? scheme.primary : scheme.onSurfaceVariant,
        ),
        title: Text(s.name),
        subtitle: Text(Fr.serverLine(s.protocol, s.user, s.host, s.port, s.connected)),
        onTap: () => connectAndOpen(context, state, s),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          if (s.connected)
            IconButton(
              tooltip: Fr.disconnect,
              icon: const Icon(Icons.link_off_rounded),
              onPressed: () => state.disconnectServer(s.id),
            ),
          IconButton(
            tooltip: Fr.editServer,
            icon: const Icon(Icons.edit_rounded),
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute<void>(builder: (_) => ServerFormScreen(state: state, server: s))),
          ),
        ]),
      ),
    );
  }
}

/// Connecte [s] puis ouvre son dossier de départ (voir [withServerAuth]).
Future<void> connectAndOpen(BuildContext context, AppState state, RemoteServerMsg s, {Uint8List? password}) async {
  final src = await withServerAuth(context, state, s, (pw) => state.connectServer(s.id, pw), password: password);
  if (src != null && context.mounted) await openExplorer(context, state, src.id, path: s.startPath);
}

/// Lance [action] sur le serveur [s] (connexion, test) ; rend son résultat, ou null après un échec déjà montré. Mot de
/// passe manquant ou refusé : demandé ; clé SFTP inconnue : montrée, et acceptée seulement sur « Faire confiance » ;
/// clé changée : refus expliqué ; échec SSH (phase 13) : message précis et bouton « Détails ».
Future<T?> withServerAuth<T>(
  BuildContext context,
  AppState state,
  RemoteServerMsg s,
  Future<T> Function(Uint8List? password) action, {
  Uint8List? password,
}) async {
  try {
    return await action(password);
  } on PlatformException catch (e) {
    if (!context.mounted) return null;
    switch (e.code) {
      case 'auth':
        final p = await _askPassword(context, s, wrong: e.details != true);
        if (p == null || !context.mounted) return null;
        final bytes = Uint8List.fromList(utf8.encode(p));
        try {
          return await withServerAuth(context, state, s, action, password: bytes);
        } finally {
          bytes.fillRange(0, bytes.length, 0);
        }
      case 'hostkey-unknown':
        final fp = e.details as String? ?? '';
        if (!await _trust(context, fp) || !context.mounted) return null;
        await state.trustHostKey(s.id, fp);
        if (!context.mounted) return null;
        return withServerAuth(context, state, s, action, password: password);
      case 'hostkey-changed':
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text(Fr.hostKeyChangedTitle),
            content: Text(e.message ?? Fr.genericError),
            actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text(Fr.ok))],
          ),
        );
        return null;
      case 'ssh':
        showMessage(
          context,
          e.message ?? Fr.genericError,
          kind: MessageKind.error,
          actionLabel: Fr.details,
          onAction: () => showConnectionDetails(context, state, s.id, cause: e.details as String?),
        );
        return null;
      default:
        showMessage(context, e.message ?? Fr.genericError, kind: MessageKind.error);
        return null;
    }
  }
}

Future<String?> _askPassword(BuildContext context, RemoteServerMsg s, {required bool wrong}) =>
    showDialog<String>(context: context, builder: (_) => _PasswordDialog(name: s.name, wrong: wrong));

/// Mot de passe d'un serveur ; le champ appartient au dialogue (détruit après son animation de fermeture).
class _PasswordDialog extends StatefulWidget {
  const _PasswordDialog({required this.name, required this.wrong});

  final String name;
  final bool wrong;

  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(Fr.passwordFor(widget.name)),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (widget.wrong) ...[
            Text(Fr.wrongPassword, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            const SizedBox(height: Space.m),
          ],
          TextField(
            controller: _ctrl,
            obscureText: true,
            autofocus: true,
            decoration: const InputDecoration(labelText: Fr.password),
            onSubmitted: (v) => Navigator.pop(context, v),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text(Fr.cancel)),
          TextButton(onPressed: () => Navigator.pop(context, _ctrl.text), child: const Text(Fr.connect)),
        ],
      );
}

Future<bool> _trust(BuildContext context, String fingerprint) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(Fr.trustTitle),
        content: SelectableText(Fr.trustBody(fingerprint)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text(Fr.cancel)),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text(Fr.trust)),
        ],
      ),
    ) ??
    false;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../bridge/fluluks_api.g.dart';
import '../state/app_state.dart';
import '../strings_fr.dart';
import '../ui/dialogs.dart';
import '../ui/feedback.dart';
import '../ui/states.dart';
import '../ui/tokens.dart';
import '../widgets/ssh_key_form.dart';

enum _KeyMenu { copy, share, rename, delete }

/// « Clés SSH » (Réglages → Fichiers, phase 13) : le trousseau de clés du téléphone ; Générer, Importer ; pour
/// chaque clé : copier ou partager sa clé publique, la renommer, la supprimer (refusé si un serveur l'utilise).
class SshKeysScreen extends StatefulWidget {
  const SshKeysScreen({super.key, required this.state});

  final AppState state;

  @override
  State<SshKeysScreen> createState() => _SshKeysScreenState();
}

class _SshKeysScreenState extends State<SshKeysScreen> {
  List<SshKeyMsg>? _keys;
  bool _busy = false;

  AppState get _state => widget.state;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final keys = await _state.api.sshKeys();
    if (mounted) setState(() => _keys = keys);
  }

  /// Lance [action] en montrant l'attente ; ses erreurs deviennent un message.
  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } on PlatformException catch (e) {
      if (mounted) showMessage(context, e.message ?? Fr.genericError, kind: MessageKind.error);
    } finally {
      if (mounted) setState(() => _busy = false);
      await _load();
    }
  }

  Future<void> _generate() async {
    final k = await askNewSshKey(context);
    if (k == null) return;
    await _run(() async {
      try {
        await _state.api.generateSshKey(k.name, k.type, k.passphrase);
      } finally {
        k.passphrase?.fillRange(0, k.passphrase!.length, 0);
      }
    });
  }

  Future<void> _import() async {
    final name = await promptText(context, title: Fr.importKey, label: Fr.keyName, initial: Fr.importedKeyName);
    if (name == null) return;
    await _run(() => _state.api.importSshKey(name));
  }

  Future<void> _menu(SshKeyMsg k, _KeyMenu m) async {
    switch (m) {
      case _KeyMenu.copy:
        await _run(() async {
          await Clipboard.setData(ClipboardData(text: await _state.api.sshPublicKey(k.id)));
          if (mounted) showMessage(context, Fr.publicKeyCopied, kind: MessageKind.success);
        });
      case _KeyMenu.share:
        await _run(() async => _state.api.shareText(await _state.api.sshPublicKey(k.id)));
      case _KeyMenu.rename:
        final name = await promptText(context, title: Fr.rename, label: Fr.keyName, initial: k.name);
        if (name != null) await _run(() => _state.api.renameSshKey(k.id, name));
      case _KeyMenu.delete:
        final ok = await confirmAction(
          context,
          title: Fr.deleteKeyAsk(k.name),
          body: Fr.deleteKeyHelp,
          confirmLabel: Fr.delete,
          destructive: true,
        );
        if (ok) await _run(() => _state.api.deleteSshKey(k.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final keys = _keys;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text(Fr.sshKeys),
        bottom: _busy
            ? const PreferredSize(preferredSize: Size.fromHeight(4), child: LinearProgressIndicator())
            : null,
      ),
      body: SafeArea(
        child: keys == null
            ? const DelayedProgress()
            : ListView(padding: const EdgeInsets.all(Space.l), children: [
                Wrap(spacing: Space.s, runSpacing: Space.s, children: [
                  FilledButton.icon(
                    onPressed: _busy ? null : _generate,
                    icon: const Icon(Icons.add_rounded),
                    label: const Text(Fr.generateKey),
                  ),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _import,
                    icon: const Icon(Icons.file_open_rounded),
                    label: const Text(Fr.importKeyShort),
                  ),
                ]),
                const SizedBox(height: Space.l),
                if (keys.isEmpty)
                  const EmptyState(icon: Icons.key_off_rounded, title: Fr.noKeysTitle, message: Fr.noKeysBody)
                else
                  for (final k in keys)
                    Card(
                      child: ListTile(
                        leading: Icon(k.encrypted ? Icons.enhanced_encryption_rounded : Icons.key_rounded,
                            color: theme.colorScheme.primary),
                        title: Text(k.name),
                        subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('${k.type} ${k.fingerprint}', style: const TextStyle(fontFamily: 'monospace')),
                          if (k.encrypted) const Text(Fr.keyEncrypted),
                          Text(k.usedBy.isEmpty ? Fr.keyUnused : Fr.keyUsedBy(k.usedBy)),
                        ]),
                        isThreeLine: true,
                        trailing: PopupMenuButton<_KeyMenu>(
                          tooltip: Fr.keyOptions(k.name),
                          onSelected: (m) => _menu(k, m),
                          itemBuilder: (_) => const [
                            PopupMenuItem(value: _KeyMenu.copy, child: Text(Fr.copyPublicKey)),
                            PopupMenuItem(value: _KeyMenu.share, child: Text(Fr.sharePublicKey)),
                            PopupMenuItem(value: _KeyMenu.rename, child: Text(Fr.rename)),
                            PopupMenuItem(value: _KeyMenu.delete, child: Text(Fr.delete)),
                          ],
                        ),
                      ),
                    ),
              ]),
      ),
    );
  }
}

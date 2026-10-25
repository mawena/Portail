import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../bridge/fluluks_api.g.dart';
import '../state/app_state.dart';
import '../strings_fr.dart';
import '../ui/feedback.dart';
import '../ui/tokens.dart';
import '../ui/widgets.dart';
import '../widgets/decrypt_dialog.dart';
import '../widgets/password_field.dart';

/// Changer le mot de passe d'un coffre fermé (phase 14) : son emplacement de clé est remplacé, le contenu n'est pas
/// réécrit. La clé de secours tient lieu d'ancien mot de passe s'il est oublié.
Future<void> changeVaultPassword(BuildContext context, AppState state, VaultMsg vault) async {
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => ChangePasswordDialog(
      state: state,
      title: Fr.changeVaultPasswordTitle(vault.name),
      oldHelp: Fr.oldPasswordOrRecovery,
      blocked: vault.state == 'open' ? Fr.closeVaultFirst : null,
      change: (o, n) => state.changeVaultPassword(vault.id, o, n),
    ),
  );
  if (ok == true && context.mounted) showMessage(context, Fr.passwordChanged, kind: MessageKind.success);
}

/// Ouvre l'écran de la clé de secours du coffre [vaultId].
Future<void> openRecoveryKey(BuildContext context, AppState state, String vaultId) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => RecoveryKeyScreen(state: state, vaultId: vaultId)));

/// Clé de secours d'un coffre (phase 14) : présente ou non ; Créer, Remplacer, Retirer, coffre fermé, après le mot de
/// passe. Une clé créée est montrée une seule fois ([RecoveryKeyShownScreen]) : Portail ne la garde nulle part.
class RecoveryKeyScreen extends StatefulWidget {
  const RecoveryKeyScreen({super.key, required this.state, required this.vaultId});

  final AppState state;
  final String vaultId;

  @override
  State<RecoveryKeyScreen> createState() => _RecoveryKeyScreenState();
}

class _RecoveryKeyScreenState extends State<RecoveryKeyScreen> {
  bool _busy = false;
  String? _error;

  AppState get state => widget.state;

  /// [action] avec le mot de passe du coffre (demandé d'abord) ; erreurs montrées sur l'écran.
  Future<void> _withPassword(Future<void> Function(Uint8List pw) action) async {
    final pw = await askVaultPassword(context);
    if (pw == null || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action(pw);
    } on PlatformException catch (e) {
      if (mounted) setState(() => _error = cryptErrorText(e));
    } finally {
      pw.fillRange(0, pw.length, 0);
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _create() => _withPassword((pw) async {
        final key = await state.addRecoveryKey(widget.vaultId, pw);
        if (!mounted) {
          key.fillRange(0, key.length, 0);
          return;
        }
        await Navigator.of(context).push(MaterialPageRoute<void>(
          fullscreenDialog: true,
          builder: (_) => RecoveryKeyShownScreen(state: state, recoveryKey: key),
        ));
      });

  Future<void> _remove() => _withPassword((pw) async {
        await state.removeRecoveryKey(widget.vaultId, pw);
        if (mounted) showMessage(context, Fr.recoveryKeyRemoved, kind: MessageKind.success);
      });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text(Fr.recoveryKey)),
      body: ListenableBuilder(
        listenable: state,
        builder: (context, _) {
          final v = state.vaultById(widget.vaultId);
          if (v == null) return const SizedBox.shrink(); // retiré de la liste entre-temps
          final open = v.state == 'open';
          final can = !_busy && !open && v.state != 'unavailable';
          return AdaptiveBody(
            maxWidth: Layout.maxForm,
            child: ListView(
              padding: listPadding(context, const EdgeInsets.all(Space.l)),
              children: [
                Text(v.name, style: theme.textTheme.titleMedium),
                const SizedBox(height: Space.s),
                const Text(Fr.recoveryKeyHelp),
                const SizedBox(height: Space.l),
                StatusBanner(
                  icon: v.hasRecovery ? Icons.key_rounded : Icons.key_off_rounded,
                  text: v.hasRecovery ? Fr.recoveryKeyPresent : Fr.recoveryKeyAbsent,
                  tone: v.hasRecovery ? ChipTone.good : ChipTone.neutral,
                ),
                if (open) ...[
                  const SizedBox(height: Space.s),
                  const StatusBanner(icon: Icons.lock_rounded, text: Fr.closeVaultFirst, tone: ChipTone.warning),
                ],
                if (_error != null) ...[
                  const SizedBox(height: Space.s),
                  StatusBanner(icon: Icons.error_rounded, text: _error!, tone: ChipTone.danger),
                ],
                const SizedBox(height: Space.l),
                if (_busy) ...[
                  const LinearProgressIndicator(),
                  const SizedBox(height: Space.s),
                  const Text(Fr.workingOnKeys),
                ] else if (v.hasRecovery) ...[
                  OutlinedButton(onPressed: can ? _create : null, child: const Text(Fr.recoveryKeyReplace)),
                  Padding(
                    padding: const EdgeInsets.only(top: Space.xs, bottom: Space.s),
                    child: Text(Fr.recoveryKeyReplaceHelp, style: theme.textTheme.bodySmall),
                  ),
                  TextButton(
                    style: TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
                    onPressed: can ? _remove : null,
                    child: const Text(Fr.recoveryKeyRemove),
                  ),
                ] else
                  FilledButton(onPressed: can ? _create : null, child: const Text(Fr.recoveryKeyCreate)),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// La clé de secours, montrée une seule fois : Copier (presse-papiers sensible, effacé après 60 s) et « J'ai noté la
/// clé », seule sortie. Les octets sont mis à zéro en quittant.
class RecoveryKeyShownScreen extends StatefulWidget {
  const RecoveryKeyShownScreen({super.key, required this.state, required this.recoveryKey});

  final AppState state;
  final Uint8List recoveryKey;

  @override
  State<RecoveryKeyShownScreen> createState() => _RecoveryKeyShownScreenState();
}

class _RecoveryKeyShownScreenState extends State<RecoveryKeyShownScreen> {
  @override
  void dispose() {
    widget.recoveryKey.fillRange(0, widget.recoveryKey.length, 0);
    super.dispose();
  }

  Future<void> _copy() async {
    await widget.state.api.copySecret(widget.recoveryKey);
    if (mounted) showMessage(context, Fr.recoveryKeyCopied, kind: MessageKind.success);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mono = theme.textTheme.headlineSmall!.copyWith(fontFamily: 'monospace', letterSpacing: 1);
    return PopScope(
      canPop: false, // seule sortie : « J'ai noté la clé »
      child: Scaffold(
        appBar: AppBar(automaticallyImplyLeading: false, title: const Text(Fr.recoveryKeyShownTitle)),
        body: AdaptiveBody(
          maxWidth: Layout.maxForm,
          child: ListView(
            padding: listPadding(context, const EdgeInsets.all(Space.l)),
            children: [
              const StatusBanner(icon: Icons.warning_rounded, text: Fr.recoveryKeyShownOnce, tone: ChipTone.warning),
              const SizedBox(height: Space.l),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(Space.l),
                  child: SelectionContainer.disabled(
                    child: Text(latin1.decode(widget.recoveryKey), style: mono, textAlign: TextAlign.center),
                  ),
                ),
              ),
              const SizedBox(height: Space.s),
              Text(Fr.recoveryKeyLinux, style: theme.textTheme.bodySmall),
              const SizedBox(height: Space.l),
              OutlinedButton.icon(
                onPressed: _copy,
                icon: const Icon(Icons.copy_rounded),
                label: const Text(Fr.copyRecoveryKey),
              ),
              const SizedBox(height: Space.s),
              FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text(Fr.recoveryKeyNoted)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Mot de passe du coffre avant de créer ou retirer la clé de secours, ou de régler la biométrie ; rend ses octets
/// (l'appelant les met à zéro), ou null si annulé.
Future<Uint8List?> askVaultPassword(BuildContext context, {String? help}) =>
    showDialog<Uint8List>(context: context, builder: (_) => _VaultPasswordDialog(help: help));

class _VaultPasswordDialog extends StatefulWidget {
  const _VaultPasswordDialog({this.help});

  final String? help;

  @override
  State<_VaultPasswordDialog> createState() => _VaultPasswordDialogState();
}

class _VaultPasswordDialogState extends State<_VaultPasswordDialog> {
  final _pass = TextEditingController();

  void _changed() => setState(() {});

  @override
  void initState() {
    super.initState();
    _pass.addListener(_changed);
  }

  @override
  void dispose() {
    _pass.removeListener(_changed);
    _pass.clear();
    _pass.dispose();
    super.dispose();
  }

  void _ok() {
    if (_pass.text.isEmpty) return;
    Navigator.of(context).pop(Uint8List.fromList(utf8.encode(_pass.text)));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        icon: const Icon(Icons.lock_rounded),
        title: const Text(Fr.vaultPasswordTitle),
        scrollable: true,
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, spacing: Space.s, children: [
          if (widget.help != null) Text(widget.help!),
          PasswordField(controller: _pass, autofocus: true, onSubmitted: (_) => _ok()),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text(Fr.cancel)),
          FilledButton(onPressed: _pass.text.isEmpty ? null : _ok, child: const Text(Fr.ok)),
        ],
      );
}

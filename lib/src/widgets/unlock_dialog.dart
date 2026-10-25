import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../bridge/fluluks_api.g.dart';
import '../state/app_state.dart';
import '../strings_fr.dart';
import '../ui/feedback.dart';
import '../ui/tokens.dart';
import '../ui/widgets.dart';
import 'password_field.dart';

/// Dialogue de saisie de la phrase de passe. Les octets UTF-8 envoyés sont mis à zéro après l'appel
/// (réussi ou non) et le champ est vidé ; la phrase n'est jamais conservée ailleurs. Afficher ou masquer la phrase
/// ne change que son rendu (aucune copie). La case « Ouvrir en lecture seule » fixe l'écriture demandée.
/// Variante coffre ([UnlockDialog.vault], phase 14) : mot de passe du coffre, rend son volume en se fermant.
class UnlockDialog extends StatefulWidget {
  const UnlockDialog({
    super.key,
    required this.state,
    required this.diskId,
    required this.partIndex,
    required this.partitionName,
    this.writable = true,
  })  : vaultId = null,
        vaultSourceId = null,
        vaultPath = null,
        offerRecovery = false,
        _vault = false;

  /// Ouvre le coffre connu [vaultId], ou le fichier [vaultPath] de [vaultSourceId] ; [name] : nom montré.
  const UnlockDialog.vault({
    super.key,
    required this.state,
    required String name,
    this.vaultId,
    this.vaultSourceId,
    this.vaultPath,
    this.writable = true,
    this.offerRecovery = true,
  })  : diskId = '',
        partIndex = 0,
        partitionName = name,
        _vault = true;

  final AppState state;
  final String diskId;
  final int partIndex;
  final String partitionName;
  final String? vaultId;
  final String? vaultSourceId;
  final String? vaultPath;

  /// Coffre : lien « Utiliser la clé de secours » (la clé se tape à la place du mot de passe).
  final bool offerRecovery;
  final bool _vault;

  /// Écriture demandée au départ (faux si « Ouvrir les disques en lecture seule » est actif) : la case
  /// « Ouvrir en lecture seule » en part, et l'utilisateur peut la changer.
  final bool writable;

  @override
  State<UnlockDialog> createState() => _UnlockDialogState();
}

class _UnlockDialogState extends State<UnlockDialog> {
  final _controller = TextEditingController();
  bool _busy = false;
  String? _error;
  late bool _readOnly = !widget.writable;
  bool _recovery = false;

  @override
  void dispose() {
    _controller.clear();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || _controller.text.isEmpty) return;
    final Uint8List pass = utf8.encode(
      _controller.text,
    ); // un seul tampon, celui qui sera mis à zéro
    setState(() {
      _busy = true;
      _error = null;
    });
    String? error;
    var ok = false;
    Object result = true;
    try {
      final w = widget;
      if (w._vault) {
        result = await w.state.openVault(
            vaultId: w.vaultId,
            srcId: w.vaultSourceId,
            path: w.vaultPath,
            password: pass,
            writable: !_readOnly,
            recovery: _recovery);
      } else {
        await w.state.unlock(w.diskId, w.partIndex, pass, writable: !_readOnly);
      }
      ok = true;
    } on PlatformException catch (e) {
      error = e.message ?? Fr.genericError;
    } catch (_) {
      error = Fr.genericError; // jamais le contenu de l'exception
    } finally {
      pass.fillRange(0, pass.length, 0);
      if (mounted) _controller.clear();
    }
    if (!mounted) return;
    if (ok) {
      AppHaptics.success(widget.state);
      Navigator.of(context).pop(result);
    } else {
      AppHaptics.warning(widget.state);
      setState(() {
        _busy = false;
        _error = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        icon: const Icon(Icons.lock_rounded),
        title: Text(widget._vault ? Fr.vaultOpenTitle(widget.partitionName) : Fr.unlockTitle(widget.partitionName)),
        scrollable: true, // texte à 200 % : le contenu défile, les boutons restent visibles
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // champ de déverrouillage : ni règle, ni force, ni générateur (phrase LUKS existante)
            PasswordField(
              key: ValueKey(_recovery), // champ neuf en changeant de mode
              controller: _controller,
              label: _recovery ? Fr.recoveryKey : (widget._vault ? Fr.password : Fr.passphrase),
              showLabel: _recovery ? Fr.showRecoveryKey : (widget._vault ? Fr.showPassword : Fr.showPassphrase),
              hideLabel: _recovery ? Fr.hideRecoveryKey : (widget._vault ? Fr.hidePassword : Fr.hidePassphrase),
              enabled: !_busy,
              autofocus: true,
              onSubmitted: (_) => _submit(),
            ),
            if (widget._vault && widget.offerRecovery)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton(
                  onPressed: _busy
                      ? null
                      : () => setState(() {
                            _controller.clear();
                            _error = null;
                            _recovery = !_recovery;
                          }),
                  child: Text(_recovery ? Fr.usePassword : Fr.useRecoveryKey),
                ),
              ),
            const SizedBox(height: Space.s),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text(Fr.openReadOnly),
              value: _readOnly,
              onChanged: _busy ? null : (v) => setState(() => _readOnly = v ?? _readOnly),
            ),
            if (_busy) ...[
              const SizedBox(height: Space.s),
              const LinearProgressIndicator(),
              const SizedBox(height: Space.s),
              Text(widget._vault ? Fr.vaultOpening : Fr.unlocking),
            ],
            if (_error != null) ...[
              const SizedBox(height: Space.s),
              StatusBanner(icon: Icons.error_rounded, text: _error!, tone: ChipTone.danger),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.of(context).pop(false),
            child: const Text(Fr.cancel),
          ),
          FilledButton(
            onPressed: _busy ? null : _submit,
            child: Text(widget._vault ? Fr.open : Fr.unlock),
          ),
        ],
      ),
    );
  }
}

/// Demande le mot de passe d'un coffre et l'ouvre ; rend son volume (stockage du même identifiant), ou null.
Future<VolumeMsg?> openVaultDialog(BuildContext context, AppState state,
        {required String name, String? vaultId, String? srcId, String? path, bool offerRecovery = true}) =>
    showDialog<Object>(
      context: context,
      barrierDismissible: false,
      builder: (_) => UnlockDialog.vault(
        state: state,
        name: name,
        vaultId: vaultId,
        vaultSourceId: srcId,
        vaultPath: path,
        writable: !state.readOnlyPreference,
        offerRecovery: offerRecovery,
      ),
    ).then((r) => r is VolumeMsg ? r : null);

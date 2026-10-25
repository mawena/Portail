import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../bridge/fluluks_api.g.dart';
import '../state/app_state.dart';
import '../strings_fr.dart';
import '../ui/feedback.dart';
import '../ui/tokens.dart';
import '../ui/widgets.dart';
import 'folder_picker.dart';
import 'password_field.dart';

/// Message d'une erreur du pont : « Mot de passe incorrect » pour le code `badPassword`.
String cryptErrorText(PlatformException e) => e.code == 'badPassword' ? Fr.badPassword : (e.message ?? Fr.genericError);

/// Fichier chiffré touché (phase 14) : son mot de passe, puis Ouvrir (fichier seul, déchiffré en mémoire), Déchiffrer
/// ici ou vers un dossier choisi (un dossier chiffré `.zip.age` s'extrait), ou Vérifier. Un mauvais mot de passe à
/// l'ouverture garde le dialogue ouvert, champ vidé, pour un nouvel essai. Rend la vue déchiffrée ouverte par Ouvrir,
/// sinon null. Les octets du mot de passe sont mis à zéro après chaque appel.
class DecryptDialog extends StatefulWidget {
  const DecryptDialog({
    super.key,
    required this.state,
    required this.sourceId,
    required this.entry,
    required this.dir,
    required this.folder,
  });

  final AppState state;
  final String sourceId;
  final EntryMsg entry;

  /// Dossier ouvert : destination de « Déchiffrer ici ».
  final String dir;

  /// Dossier chiffré (`.zip.age`) : extraire, jamais ouvrir en vue.
  final bool folder;

  @override
  State<DecryptDialog> createState() => _DecryptDialogState();
}

class _DecryptDialogState extends State<DecryptDialog> {
  final _pass = TextEditingController();
  bool _busy = false;
  String? _error;

  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    _pass.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _pass.dispose();
    super.dispose();
  }

  /// Lance [action] avec le mot de passe en octets ; rend vrai si le dialogue peut se fermer.
  Future<void> _run(Future<SourceMsg?> Function(Uint8List pass) action) async {
    if (_busy || _pass.text.isEmpty) return;
    final pass = Uint8List.fromList(utf8.encode(_pass.text));
    setState(() {
      _busy = true;
      _error = null;
    });
    SourceMsg? view;
    String? error;
    try {
      view = await action(pass);
      error = state.lastError;
      if (error != null) state.clearError();
    } on PlatformException catch (e) {
      error = cryptErrorText(e);
    } finally {
      pass.fillRange(0, pass.length, 0);
    }
    if (!mounted) return;
    if (error == null) {
      Navigator.of(context).pop(view);
      return;
    }
    AppHaptics.warning(state);
    _pass.clear();
    setState(() {
      _busy = false;
      _error = error;
    });
  }

  Future<SourceMsg?> _open(Uint8List pass) => state.openDecrypted(widget.sourceId, widget.entry.path, pass);

  Future<SourceMsg?> _decryptTo(String dstId, String dir, Uint8List pass) async {
    await state.startDecrypt(widget.sourceId, widget.entry.path, dstId, dir, extractFolder: true, password: pass);
    return null;
  }

  Future<void> _decryptElsewhere() async {
    if (_busy || _pass.text.isEmpty) return;
    final picked = await pickFolder(context, state);
    if (picked == null || !mounted) return;
    await _run((p) => _decryptTo(picked.$1, picked.$2, p));
  }

  Future<SourceMsg?> _verify(Uint8List pass) async {
    await state.startVerify(widget.sourceId, widget.entry.path, pass);
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final ready = !_busy && _pass.text.isNotEmpty;
    final here = widget.folder ? Fr.extractHere : Fr.decryptHere;
    final to = widget.folder ? Fr.extractTo : Fr.decryptTo;
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        icon: const Icon(Icons.lock_rounded),
        title: Text(widget.entry.name, maxLines: 2, overflow: TextOverflow.ellipsis),
        scrollable: true,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: Space.s,
          children: [
            PasswordField(
              controller: _pass,
              enabled: !_busy,
              autofocus: true,
              onSubmitted: (_) => widget.folder ? _run((p) => _decryptTo(widget.sourceId, widget.dir, p)) : _run(_open),
            ),
            if (_busy) ...[const LinearProgressIndicator(), const Text(Fr.workingOnKeys)],
            if (_error != null) StatusBanner(icon: Icons.error_rounded, text: _error!, tone: ChipTone.danger),
            if (!widget.folder)
              FilledButton.icon(
                onPressed: ready ? () => _run(_open) : null,
                icon: const Icon(Icons.visibility_rounded),
                label: const Text(Fr.openDecrypted),
              ),
            (widget.folder ? FilledButton.icon : OutlinedButton.icon)(
              onPressed: ready ? () => _run((p) => _decryptTo(widget.sourceId, widget.dir, p)) : null,
              icon: const Icon(Icons.lock_open_rounded),
              label: Text(here),
            ),
            OutlinedButton.icon(
              onPressed: ready ? _decryptElsewhere : null,
              icon: const Icon(Icons.drive_file_move_rounded),
              label: Text(to),
            ),
            OutlinedButton.icon(
              onPressed: ready ? () => _run(_verify) : null,
              icon: const Icon(Icons.verified_rounded),
              label: const Text(Fr.verifyAction),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(), child: const Text(Fr.cancel)),
        ],
      ),
    );
  }
}

/// Changer le mot de passe d'un fichier `.age` : le mot de passe actuel, puis le nouveau (confirmé, avec sa force et
/// le générateur). Un mot de passe actuel faux garde le dialogue ouvert. Vrai si le mot de passe a changé.
class ChangeFilePasswordDialog extends StatelessWidget {
  const ChangeFilePasswordDialog({super.key, required this.state, required this.sourceId, required this.entry});

  final AppState state;
  final String sourceId;
  final EntryMsg entry;

  @override
  Widget build(BuildContext context) => ChangePasswordDialog(
        state: state,
        title: entry.name,
        change: (o, n) => state.changeFilePassword(sourceId, entry.path, o, n),
      );
}

/// Ancien mot de passe, puis le nouveau (force, générateur, confirmation) ; [change] reçoit les octets, mis à zéro
/// ensuite par ce dialogue. [oldHelp] : aide sous l'ancien ; [blocked] : raison d'un refus d'avance (coffre ouvert),
/// le bouton reste désactivé. Se ferme sur vrai quand le mot de passe est changé.
class ChangePasswordDialog extends StatefulWidget {
  const ChangePasswordDialog({
    super.key,
    required this.state,
    required this.title,
    required this.change,
    this.oldHelp,
    this.blocked,
  });

  final AppState state;
  final String title;
  final Future<void> Function(Uint8List oldPassword, Uint8List newPassword) change;
  final String? oldHelp;
  final String? blocked;

  @override
  State<ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends State<ChangePasswordDialog> {
  final _old = TextEditingController();
  final _new = TextEditingController();
  final _confirm = TextEditingController();
  bool _valid = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _old.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _old.dispose();
    _new.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || !_valid || _old.text.isEmpty || widget.blocked != null) return;
    final o = Uint8List.fromList(utf8.encode(_old.text));
    final n = Uint8List.fromList(utf8.encode(_new.text));
    setState(() {
      _busy = true;
      _error = null;
    });
    String? error;
    try {
      await widget.change(o, n);
    } on PlatformException catch (e) {
      error = cryptErrorText(e);
    } finally {
      o.fillRange(0, o.length, 0);
      n.fillRange(0, n.length, 0);
    }
    if (!mounted) return;
    if (error == null) {
      Navigator.of(context).pop(true);
      return;
    }
    _old.clear();
    setState(() {
      _busy = false;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        icon: const Icon(Icons.password_rounded),
        title: Text(widget.title, maxLines: 2, overflow: TextOverflow.ellipsis),
        scrollable: true,
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, spacing: Space.s, children: [
          if (widget.blocked != null) StatusBanner(icon: Icons.lock_rounded, text: widget.blocked!, tone: ChipTone.warning),
          PasswordField(controller: _old, label: Fr.currentPassword, enabled: !_busy, autofocus: true),
          if (widget.oldHelp != null) Text(widget.oldHelp!, style: Theme.of(context).textTheme.bodySmall),
          PasswordField(
            controller: _new,
            confirm: _confirm,
            showStrength: true,
            allowGenerate: true,
            copySecret: widget.state.api.copySecret,
            enabled: !_busy,
            onValidChanged: (v) => setState(() => _valid = v),
          ),
          if (_busy) const LinearProgressIndicator(),
          if (_error != null) StatusBanner(icon: Icons.error_rounded, text: _error!, tone: ChipTone.danger),
        ]),
        actions: [
          TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(false), child: const Text(Fr.cancel)),
          FilledButton(
            onPressed: !_busy && _valid && _old.text.isNotEmpty && widget.blocked == null ? _submit : null,
            child: const Text(Fr.changeButton),
          ),
        ],
      ),
    );
  }
}

/// Mot de passe d'une archive ZIP protégée, demandé avant l'extraction ; null si annulé. L'appelant met les octets à
/// zéro après usage.
Future<Uint8List?> askArchivePassword(BuildContext context, String name) => showDialog<Uint8List>(
      context: context,
      builder: (_) => _ArchivePasswordDialog(name: name),
    );

class _ArchivePasswordDialog extends StatefulWidget {
  const _ArchivePasswordDialog({required this.name});

  final String name;

  @override
  State<_ArchivePasswordDialog> createState() => _ArchivePasswordDialogState();
}

class _ArchivePasswordDialogState extends State<_ArchivePasswordDialog> {
  final _pass = TextEditingController();

  @override
  void initState() {
    super.initState();
    _pass.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _pass.dispose();
    super.dispose();
  }

  void _ok() {
    if (_pass.text.isEmpty) return;
    Navigator.of(context).pop(Uint8List.fromList(utf8.encode(_pass.text)));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        icon: const Icon(Icons.folder_zip_rounded),
        title: const Text(Fr.protectedArchive),
        scrollable: true,
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(widget.name, style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: Space.s),
          PasswordField(controller: _pass, autofocus: true, onSubmitted: (_) => _ok()),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text(Fr.cancel)),
          FilledButton(onPressed: _pass.text.isEmpty ? null : _ok, child: const Text(Fr.extractButton)),
        ],
      );
}

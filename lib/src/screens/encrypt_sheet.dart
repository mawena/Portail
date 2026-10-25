import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../strings_fr.dart';
import '../ui/tokens.dart';
import '../ui/widgets.dart';
import '../widgets/folder_picker.dart';
import '../widgets/password_field.dart';

/// Ouvre l'écran Chiffrer pour [paths] de [sourceId] (dossier ouvert : [dir]).
Future<void> openEncryptSheet(BuildContext context, AppState state, String sourceId, List<String> paths, String dir) =>
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => EncryptSheet(state: state, sourceId: sourceId, paths: paths, dir: dir),
    ));

/// Chiffrer des fichiers ou des dossiers (phase 14) : format (chiffrement fort age par défaut, ou ZIP AES-256 pour
/// l'échange, avec sa mise en garde), réunion de plusieurs éléments dans un seul fichier, destination (ce dossier, ou
/// un dossier de n'importe quel stockage), suppression de l'original après vérification, et le mot de passe, avec sa
/// force et le générateur. Le mot de passe part en octets, mis à zéro après l'appel.
class EncryptSheet extends StatefulWidget {
  const EncryptSheet({super.key, required this.state, required this.sourceId, required this.paths, required this.dir});

  final AppState state;
  final String sourceId;
  final List<String> paths;
  final String dir;

  @override
  State<EncryptSheet> createState() => _EncryptSheetState();
}

class _EncryptSheetState extends State<EncryptSheet> {
  String _format = 'age';
  bool _together = false;
  final _name = TextEditingController(text: Fr.archiveDefault);
  String _dest = 'here';
  (String, String)? _other;
  bool _delete = false;
  final _pass = TextEditingController();
  final _confirm = TextEditingController();
  bool _valid = false;
  bool _busy = false;
  String? _error;

  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    _name.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _name.dispose();
    _pass.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _chooseDest(String? v) async {
    if (v == null || _busy) return;
    if (v == 'here') {
      setState(() => _dest = 'here');
      return;
    }
    final picked = await pickFolder(context, state);
    if (!mounted || picked == null) return;
    setState(() {
      _dest = 'other';
      _other = picked;
    });
  }

  String _destLabel((String, String) d) => Fr.destChosen(state.sourceById(d.$1)?.label ?? d.$1, d.$2);

  bool get _canSubmit => _valid && !_busy && (!_together || _name.text.trim().isNotEmpty);

  Future<void> _submit() async {
    // règles revérifiées sur le texte même : jamais de chiffrement avec un champ vidé entre-temps
    if (!_canSubmit || PasswordField.problem(_pass.text, _confirm.text) != null) return;
    await _send();
  }

  Future<void> _send() async {
    final (dstId, dstDir) = _dest == 'other' && _other != null ? _other! : (widget.sourceId, widget.dir);
    final Uint8List pass = Uint8List.fromList(utf8.encode(_pass.text));
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await state.startEncrypt(widget.sourceId, widget.paths, dstId, dstDir,
          format: _format,
          together: _together,
          name: _together ? _name.text.trim() : null,
          deleteOriginal: _delete,
          password: pass);
    } finally {
      pass.fillRange(0, pass.length, 0);
    }
    if (!mounted) return;
    final err = state.lastError;
    if (err != null) {
      state.clearError();
      setState(() {
        _busy = false;
        _error = err;
      });
      return;
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final n = widget.paths.length;
    final subject = n == 1 ? widget.paths.single.substring(widget.paths.single.lastIndexOf('/') + 1) : Fr.selected(n);
    final readOnly = state.sourceById(widget.sourceId)?.readOnly ?? true;
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(title: const Text(Fr.encryptTitle)),
        body: AdaptiveBody(
          maxWidth: Layout.maxForm,
          child: ListView(
            padding: listPadding(context, const EdgeInsets.all(Space.l)),
            children: [
              Text(subject, style: theme.textTheme.titleMedium, maxLines: 2, overflow: TextOverflow.ellipsis),
              const SectionHeader(Fr.encryptFormat),
              RadioGroup<String>(
                key: const ValueKey('encrypt-format'),
                groupValue: _format,
                onChanged: (v) {
                  if (!_busy && v != null) setState(() => _format = v);
                },
                child: const Column(children: [
                  RadioListTile<String>(value: 'age', title: Text(Fr.formatStrong), subtitle: Text(Fr.formatStrongHelp)),
                  RadioListTile<String>(value: 'zip', title: Text(Fr.formatZip), subtitle: Text(Fr.formatZipHelp)),
                ]),
              ),
              if (_format == 'zip')
                const StatusBanner(icon: Icons.warning_rounded, text: Fr.zipNamesWarning, tone: ChipTone.warning),
              if (n > 1) ...[
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text(Fr.together),
                  value: _together,
                  onChanged: _busy ? null : (v) => setState(() => _together = v),
                ),
                if (_together)
                  TextField(
                    controller: _name,
                    enabled: !_busy,
                    decoration: const InputDecoration(labelText: Fr.togetherName),
                  ),
              ],
              const SectionHeader(Fr.destination),
              RadioGroup<String>(
                key: const ValueKey('encrypt-dest'),
                groupValue: _dest,
                onChanged: _chooseDest,
                child: Column(children: [
                  const RadioListTile<String>(value: 'here', title: Text(Fr.destHere)),
                  RadioListTile<String>(
                    value: 'other',
                    title: const Text(Fr.destOther),
                    subtitle: _other == null ? null : Text(_destLabel(_other!)),
                    // déjà choisi : ce bouton en choisit un autre
                    secondary: _dest == 'other'
                        ? IconButton(
                            tooltip: Fr.pickFolderTitle,
                            icon: const Icon(Icons.edit_location_alt_rounded),
                            onPressed: _busy ? null : () => _chooseDest('other'),
                          )
                        : null,
                  ),
                ]),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text(Fr.deleteOriginal),
                subtitle: const Text(Fr.deleteOriginalHelp),
                value: _delete,
                onChanged: _busy || readOnly ? null : (v) => setState(() => _delete = v ?? false),
              ),
              if (_delete) const StatusBanner(icon: Icons.info_rounded, text: Fr.deleteOriginalFlash, tone: ChipTone.neutral),
              const SizedBox(height: Space.l),
              PasswordField(
                controller: _pass,
                confirm: _confirm,
                showStrength: true,
                allowGenerate: true,
                copySecret: state.api.copySecret,
                enabled: !_busy,
                onValidChanged: (v) => setState(() => _valid = v),
              ),
              const SizedBox(height: Space.l),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: Space.s),
                  child: StatusBanner(icon: Icons.error_rounded, text: _error!, tone: ChipTone.danger),
                ),
              FilledButton(onPressed: _canSubmit ? _submit : null, child: const Text(Fr.encryptButton)),
            ],
          ),
        ),
      ),
    );
  }
}

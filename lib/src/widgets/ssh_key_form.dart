import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../strings_fr.dart';
import '../ui/tokens.dart';

/// Ce que demande « Générer » : nom, type (`ed25519` ou `rsa`) et phrase facultative, en octets (à remettre à zéro).
typedef NewSshKey = ({String name, String type, Uint8List? passphrase});

/// Dialogue « Nouvelle clé SSH » (phase 13) ; null si annulé.
Future<NewSshKey?> askNewSshKey(BuildContext context) =>
    showDialog<NewSshKey>(context: context, builder: (_) => const SshKeyForm());

class SshKeyForm extends StatefulWidget {
  const SshKeyForm({super.key});

  @override
  State<SshKeyForm> createState() => _SshKeyFormState();
}

class _SshKeyFormState extends State<SshKeyForm> {
  final _name = TextEditingController(text: 'Portail');
  final _phrase = TextEditingController();
  final _confirm = TextEditingController();
  String _type = 'ed25519';
  String? _error;

  @override
  void dispose() {
    for (final c in [_name, _phrase, _confirm]) {
      c.dispose();
    }
    super.dispose();
  }

  void _submit() {
    if (_phrase.text != _confirm.text) {
      setState(() => _error = Fr.passMismatch);
      return;
    }
    final phrase = _phrase.text.isEmpty ? null : Uint8List.fromList(utf8.encode(_phrase.text));
    Navigator.pop<NewSshKey>(context, (name: _name.text.trim(), type: _type, passphrase: phrase));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text(Fr.generateKeyTitle),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextField(controller: _name, decoration: const InputDecoration(labelText: Fr.keyName)),
          const SizedBox(height: Space.l),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'ed25519', label: Text(Fr.keyTypeEd25519)),
              ButtonSegment(value: 'rsa', label: Text(Fr.keyTypeRsa)),
            ],
            selected: {_type},
            showSelectedIcon: false,
            onSelectionChanged: (s) => setState(() => _type = s.first),
          ),
          const SizedBox(height: Space.s),
          Text(Fr.keyTypeHelp, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: Space.l),
          TextField(
            controller: _phrase,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(labelText: Fr.keyPassphraseOptional, helperText: Fr.keyPassphraseHelpNew),
          ),
          TextField(
            controller: _confirm,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(labelText: Fr.keyPassphraseConfirm, errorText: _error),
            onSubmitted: (_) => _submit(),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text(Fr.cancel)),
        FilledButton(onPressed: _submit, child: const Text(Fr.generateKey)),
      ],
    );
  }
}

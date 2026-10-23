import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../bridge/fluluks_api.g.dart';
import '../strings_fr.dart';
import '../ui/tokens.dart';

/// Pose l'invite keyboard-interactive [p] d'un serveur SSH (phase 13) ; rend une réponse en octets par invite, ou null
/// si l'utilisateur refuse. L'appelant remet les octets à zéro après l'envoi.
Future<List<Uint8List>?> askSshPrompt(BuildContext context, SshPromptMsg p) => showDialog<List<Uint8List>>(
      context: context,
      barrierDismissible: false,
      builder: (_) => SshPromptDialog(prompt: p),
    );

/// Dialogue d'une invite : titre (nom du serveur ou de l'invite), instruction, un champ par invite (masqué sans écho).
class SshPromptDialog extends StatefulWidget {
  const SshPromptDialog({super.key, required this.prompt});

  final SshPromptMsg prompt;

  @override
  State<SshPromptDialog> createState() => _SshPromptDialogState();
}

class _SshPromptDialogState extends State<SshPromptDialog> {
  late final _fields = [for (final _ in widget.prompt.prompts) TextEditingController()];

  @override
  void dispose() {
    for (final c in _fields) {
      c.dispose();
    }
    super.dispose();
  }

  void _send() => Navigator.pop(context, [for (final c in _fields) Uint8List.fromList(utf8.encode(c.text))]);

  @override
  Widget build(BuildContext context) {
    final p = widget.prompt;
    return AlertDialog(
      title: Text(p.name.isEmpty ? Fr.sshPromptTitle : p.name),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (p.instruction.isNotEmpty) ...[Text(p.instruction), const SizedBox(height: Space.m)],
          for (var i = 0; i < p.prompts.length; i++)
            TextField(
              controller: _fields[i],
              obscureText: !(i < p.echo.length && p.echo[i]),
              autofocus: i == 0,
              autocorrect: false,
              enableSuggestions: false,
              enableIMEPersonalizedLearning: false,
              decoration: InputDecoration(labelText: p.prompts[i].trim()),
              onSubmitted: i == p.prompts.length - 1 ? (_) => _send() : null,
            ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text(Fr.cancel)),
        TextButton(onPressed: _send, child: const Text(Fr.sendAnswer)),
      ],
    );
  }
}

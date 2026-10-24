import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../bridge/fluluks_api.g.dart';
import '../state/app_state.dart';
import '../strings_fr.dart';
import '../ui/dialogs.dart';
import '../ui/feedback.dart';
import '../ui/tokens.dart';
import 'terminal_hub.dart';

/// Feuille « Commandes » du terminal (phase 13) : celles du serveur puis les communes ; toucher en choisit une (rendue
/// à l'appelant, qui l'envoie), appui long la modifie, « Ajouter une commande » en crée une.
Future<SnippetMsg?> showSnippetsSheet(BuildContext context, AppState state, TerminalEntry entry) =>
    showModalBottomSheet<SnippetMsg>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => SnippetsSheet(state: state, entry: entry),
    );

/// Envoie [s] au terminal [e] : fins de ligne en retour chariot, Entrée ajoutée si « Exécuter aussitôt » ; plusieurs
/// lignes : confirmé d'abord.
Future<void> runSnippet(BuildContext context, AppState state, TerminalEntry e, SnippetMsg s) async {
  final lines = s.command.split('\n').where((l) => l.trim().isNotEmpty).length;
  if (lines > 1) {
    final ok = await confirmAction(
      context,
      title: Fr.pasteLines(lines),
      body: Fr.pasteLinesHelp,
      confirmLabel: Fr.snippetRun,
    );
    if (!ok) return;
  }
  var text = s.command.replaceAll('\r\n', '\r').replaceAll('\n', '\r');
  if (s.runNow && !text.endsWith('\r')) text += '\r';
  state.terminals.send(e.info.id, text);
}

/// Crée ou modifie une commande ([initial] null : nouvelle, [command] pré-remplie) ; rend vrai si la liste a changé.
Future<bool> editSnippet(
  BuildContext context,
  AppState state,
  TerminalEntry entry, {
  SnippetMsg? initial,
  String command = '',
}) async {
  final serverName = state.servers.where((s) => s.id == entry.info.serverId).map((s) => s.name).firstOrNull ??
      entry.info.title;
  final changed = await showDialog<bool>(
    context: context,
    builder: (_) => _SnippetEditor(
      state: state,
      serverId: entry.info.serverId,
      serverName: serverName,
      initial: initial,
      command: command,
    ),
  );
  return changed ?? false;
}

class SnippetsSheet extends StatefulWidget {
  const SnippetsSheet({super.key, required this.state, required this.entry});

  final AppState state;
  final TerminalEntry entry;

  @override
  State<SnippetsSheet> createState() => _SnippetsSheetState();
}

class _SnippetsSheetState extends State<SnippetsSheet> {
  List<SnippetMsg>? _list;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final l = await widget.state.api.snippets(widget.entry.info.serverId);
    if (mounted) setState(() => _list = l);
  }

  Future<void> _edit({SnippetMsg? initial}) async {
    if (await editSnippet(context, widget.state, widget.entry, initial: initial)) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final list = _list;
    final theme = Theme.of(context);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.7),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.l),
            child: Text(Fr.snippets, style: theme.textTheme.titleLarge),
          ),
          Flexible(
            child: list == null
                ? const SizedBox(height: 96)
                : list.isEmpty
                    ? const Padding(padding: EdgeInsets.all(Space.l), child: Text(Fr.noSnippets))
                    : ListView(shrinkWrap: true, children: [
                        for (final s in list)
                          ListTile(
                            leading: Icon(s.serverId == null ? Icons.public_rounded : Icons.dns_rounded),
                            title: Text(s.name),
                            subtitle: Text(
                              s.command,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontFamily: 'monospace'),
                            ),
                            trailing: s.runNow ? const Icon(Icons.keyboard_return_rounded) : null,
                            onTap: () => Navigator.pop(context, s),
                            onLongPress: () => _edit(initial: s),
                          ),
                      ]),
          ),
          Padding(
            padding: const EdgeInsets.all(Space.l),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                icon: const Icon(Icons.add_rounded),
                label: const Text(Fr.addSnippet),
                onPressed: () => _edit(),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

class _SnippetEditor extends StatefulWidget {
  const _SnippetEditor({
    required this.state,
    required this.serverId,
    required this.serverName,
    required this.initial,
    required this.command,
  });

  final AppState state;
  final String serverId;
  final String serverName;
  final SnippetMsg? initial;
  final String command;

  @override
  State<_SnippetEditor> createState() => _SnippetEditorState();
}

class _SnippetEditorState extends State<_SnippetEditor> {
  late final _name = TextEditingController(text: widget.initial?.name ?? '');
  late final _command = TextEditingController(text: widget.initial?.command ?? widget.command);
  late bool _runNow = widget.initial?.runNow ?? true;
  late bool _thisServer = widget.initial?.serverId != null;

  @override
  void dispose() {
    _name.dispose();
    _command.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    try {
      await widget.state.api.saveSnippet(SnippetMsg(
        id: widget.initial?.id ?? '',
        serverId: _thisServer ? widget.serverId : null,
        name: _name.text.trim().isEmpty ? _command.text.trim() : _name.text.trim(),
        command: _command.text,
        runNow: _runNow,
      ));
      if (mounted) Navigator.pop(context, true);
    } on PlatformException catch (e) {
      if (mounted) showMessage(context, e.message ?? Fr.genericError, kind: MessageKind.error);
    }
  }

  Future<void> _delete() async {
    await widget.state.api.deleteSnippet(widget.initial!.id);
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.initial == null ? Fr.newSnippet : Fr.editSnippet),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: _name, decoration: const InputDecoration(labelText: Fr.snippetName)),
            TextField(
              controller: _command,
              minLines: 1,
              maxLines: 6,
              autocorrect: false,
              enableSuggestions: false,
              style: const TextStyle(fontFamily: 'monospace'),
              decoration: const InputDecoration(labelText: Fr.snippetCommand),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text(Fr.snippetRunNow),
              subtitle: const Text(Fr.snippetRunNowHelp),
              value: _runNow,
              onChanged: (v) => setState(() => _runNow = v),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(Fr.snippetThisServer(widget.serverName)),
              value: _thisServer,
              onChanged: (v) => setState(() => _thisServer = v ?? false),
            ),
          ]),
        ),
        actions: [
          if (widget.initial != null) TextButton(onPressed: _delete, child: const Text(Fr.delete)),
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text(Fr.cancel)),
          TextButton(onPressed: _save, child: const Text(Fr.save)),
        ],
      );
}

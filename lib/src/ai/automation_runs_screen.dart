import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../bridge/fluluks_api.g.dart';
import '../state/app_state.dart';
import '../strings_fr.dart';
import '../ui/dialogs.dart';
import '../ui/feedback.dart';
import '../ui/states.dart';
import '../ui/tokens.dart';
import '../ui/widgets.dart';
import 'automation_form.dart';
import 'automations_screen.dart';
import 'hide_chats.dart';
import 'markdown_view.dart';

IconData _stateIcon(String state) => switch (state) {
      'running' => Icons.hourglass_top_rounded,
      'done' => Icons.check_circle_rounded,
      'failed' => Icons.error_rounded,
      _ => Icons.stop_circle_rounded,
    };

/// Date, durée et origine d'une exécution : « Hier, 14:05 · 12 s · Planifiée ».
String _runLine(AutomationRunMsg r) => [
      Fr.friendlyDate(r.startedAt ~/ 1000),
      if (r.endedAt != null) Fr.automationDuration(r.endedAt! - r.startedAt),
      r.scheduled ? Fr.automationScheduledRun : Fr.automationManualRun,
    ].join(' · ');

/// Fiche d'une automatisation (phase 15) : modèle de prompt, serveur et modèle, déclenchement, **Lancer** (variables
/// saisies d'abord), historique des exécutions ; Modifier, Dupliquer, Effacer l'historique et Supprimer.
class AutomationRunsScreen extends StatefulWidget {
  const AutomationRunsScreen({super.key, required this.state, required this.automationId});

  final AppState state;
  final int automationId;

  @override
  State<AutomationRunsScreen> createState() => _AutomationRunsScreenState();
}

class _AutomationRunsScreenState extends State<AutomationRunsScreen> with HideChats {
  @override
  AppState get appState => widget.state;

  late final hub = widget.state.automations;
  List<AutomationRunMsg>? _runs;

  /// Dernière exécution vue : la liste est relue quand elle change (fin d'une exécution).
  String? _lastSeen;

  int get id => widget.automationId;

  @override
  void initState() {
    super.initState();
    hub.addListener(_onHub);
    if (!hub.loaded) unawaited(_guard(hub.load()));
    unawaited(_reload());
  }

  @override
  void dispose() {
    hub.removeListener(_onHub);
    super.dispose();
  }

  void _onHub() {
    final last = hub.automation(id)?.lastRun;
    final key = last == null ? null : '${last.id}:${last.state}';
    if (key != _lastSeen) {
      _lastSeen = key;
      unawaited(_reload());
    }
  }

  Future<void> _reload() async {
    try {
      final runs = await hub.runs(id);
      if (mounted) setState(() => _runs = runs);
    } on PlatformException catch (e) {
      if (mounted) showMessage(context, e.message ?? Fr.automations, kind: MessageKind.error);
    }
  }

  Future<void> _guard(Future<Object?> f) async {
    try {
      await f;
    } on PlatformException catch (e) {
      if (mounted) showMessage(context, e.message ?? Fr.automations, kind: MessageKind.error);
    }
  }

  Future<void> _push(Widget page) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
    if (mounted) unawaited(_reload());
  }

  Future<void> _launch(AutomationMsg a) async {
    var values = const <String, String>{};
    if (a.variables.isNotEmpty) {
      final v = await showDialog<Map<String, String>>(context: context, builder: (_) => _VariablesDialog(automation: a));
      if (v == null || !mounted) return;
      values = v;
    }
    try {
      final run = await hub.run(a.id, values);
      if (mounted) await _push(AutomationRunScreen(state: widget.state, runId: run.id));
    } on PlatformException catch (e) {
      if (mounted) showMessage(context, e.message ?? Fr.automations, kind: MessageKind.error);
    }
  }

  Future<void> _delete() async {
    final ok = await confirmAction(
      context,
      title: Fr.automationDeleteTitle,
      body: Fr.automationDeleteBody,
      confirmLabel: Fr.delete,
      destructive: true,
    );
    if (!ok || !mounted) return;
    try {
      await hub.delete(id);
      if (mounted) Navigator.of(context).pop();
    } on PlatformException catch (e) {
      if (mounted) showMessage(context, e.message ?? Fr.automations, kind: MessageKind.error);
    }
  }

  Future<void> _clear() async {
    final ok = await confirmAction(
      context,
      title: Fr.automationClearTitle,
      body: Fr.automationClearBody,
      confirmLabel: Fr.automationClearHistory,
      destructive: true,
    );
    if (!ok || !mounted) return;
    await _guard(hub.clearRuns(id));
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([hub, widget.state.ai]),
      builder: (context, _) {
        final a = hub.automation(id);
        if (a == null) {
          return Scaffold(appBar: AppBar(), body: hub.loaded ? const SizedBox.shrink() : const DelayedProgress());
        }
        final ai = widget.state.ai;
        final server = a.serverId == null ? null : ai.server(a.serverId!);
        final runs = _runs;
        return Scaffold(
          appBar: AppBar(
            title: Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            actions: [
              IconButton(
                tooltip: Fr.automationEdit,
                icon: const Icon(Icons.edit_rounded),
                onPressed: () => _push(AutomationForm(state: widget.state, automation: a)),
              ),
              PopupMenuButton<void Function()>(
                tooltip: Fr.moreOptions,
                icon: const Icon(Icons.more_vert_rounded),
                onSelected: (f) => f(),
                itemBuilder: (_) => [
                  PopupMenuItem(value: () => _guard(hub.duplicate(id)), child: const Text(Fr.automationDuplicate)),
                  PopupMenuItem(value: _clear, child: const Text(Fr.automationClearHistory)),
                  PopupMenuItem(value: _delete, child: const Text(Fr.delete)),
                ],
              ),
            ],
          ),
          body: AdaptiveBody(
            child: ListView(padding: listPadding(context, const EdgeInsets.all(Space.l)), children: [
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, spacing: Space.m, children: [
                InfoLine(icon: Icons.notes_rounded, text: a.template),
                InfoLine(
                  icon: Icons.dns_rounded,
                  text: '${server?.name ?? Fr.chatServerGone} · ${a.model ?? Fr.chatNoModel}',
                ),
                InfoLine(
                  icon: a.trigger == 'periodic' ? Icons.schedule_rounded : Icons.bolt_rounded,
                  text: a.trigger == 'periodic'
                      ? '${Fr.automationInterval(a.intervalMinutes ?? 15)}${a.enabled ? '' : ' · ${Fr.automationDisabled}'}'
                      : Fr.automationManual,
                ),
              ]),
              const SizedBox(height: Space.l),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: FilledButton(onPressed: () => _launch(a), child: const Text(Fr.automationRun)),
              ),
              const SectionHeader(Fr.automationHistory),
              if (runs == null)
                const Padding(padding: EdgeInsets.all(Space.l), child: LinearProgressIndicator())
              else if (runs.isEmpty)
                Text(Fr.automationNoRuns, style: Theme.of(context).textTheme.bodyMedium)
              else
                for (final r in runs)
                  ListTile(
                    key: ValueKey(r.id),
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(_stateIcon(r.state)),
                    title: Text(Fr.automationRunState(r.state)),
                    subtitle: Text(_runLine(r)),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => _push(AutomationRunScreen(state: widget.state, runId: r.id)),
                  ),
            ]),
          ),
        );
      },
    );
  }
}

/// Valeurs des variables au lancement, valeurs par défaut proposées.
class _VariablesDialog extends StatefulWidget {
  const _VariablesDialog({required this.automation});

  final AutomationMsg automation;

  @override
  State<_VariablesDialog> createState() => _VariablesDialogState();
}

class _VariablesDialogState extends State<_VariablesDialog> {
  late final _fields = {
    for (final v in widget.automation.variables) v.name: TextEditingController(text: v.defaultValue ?? ''),
  };

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(Fr.automationRunTitle(widget.automation.name)),
        scrollable: true,
        content: Column(mainAxisSize: MainAxisSize.min, spacing: Space.m, children: [
          for (final e in _fields.entries)
            TextField(controller: e.value, decoration: InputDecoration(labelText: e.key)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text(Fr.cancel)),
          FilledButton(
            onPressed: () => Navigator.pop(context, {for (final e in _fields.entries) e.key: e.value.text}),
            child: const Text(Fr.automationRun),
          ),
        ],
      );
}

/// Une exécution (phase 15) : état, date, durée, prompt envoyé et résultat en Markdown, suivi en direct pendant un
/// lancement manuel (Arrêter) ; Copier et Partager le résultat.
class AutomationRunScreen extends StatefulWidget {
  const AutomationRunScreen({super.key, required this.state, required this.runId});

  final AppState state;
  final int runId;

  @override
  State<AutomationRunScreen> createState() => _AutomationRunScreenState();
}

class _AutomationRunScreenState extends State<AutomationRunScreen> with HideChats {
  @override
  AppState get appState => widget.state;

  late final hub = widget.state.automations;
  AutomationRunMsg? _run;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final r = await hub.runById(widget.runId);
      if (mounted) setState(() => _run = r);
    } on PlatformException catch (e) {
      if (mounted) showMessage(context, e.message ?? Fr.automations, kind: MessageKind.error);
    }
  }

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) showMessage(context, Fr.chatCopied, kind: MessageKind.success);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: hub,
      builder: (context, _) {
        final theme = Theme.of(context);
        final s = theme.colorScheme;
        final run = hub.finished(widget.runId) ?? _run;
        final running = run?.state == 'running';
        final text = running ? hub.liveText(widget.runId) ?? '' : run?.output ?? '';
        final caption = theme.textTheme.labelMedium?.copyWith(color: s.onSurfaceVariant);
        return Scaffold(
          appBar: AppBar(
            title: const Text(Fr.automationResult),
            actions: [
              if (running)
                IconButton(
                  tooltip: Fr.chatStop,
                  icon: const Icon(Icons.stop_rounded),
                  onPressed: () => hub.stop(widget.runId),
                ),
              if (!running && text.isNotEmpty) ...[
                IconButton(
                  tooltip: Fr.automationCopyResult,
                  icon: const Icon(Icons.content_copy_rounded),
                  onPressed: () => _copy(text),
                ),
                IconButton(
                  tooltip: Fr.automationShareResult,
                  icon: const Icon(Icons.share_rounded),
                  onPressed: () => widget.state.api.shareText(text),
                ),
              ],
            ],
          ),
          body: run == null
              ? const DelayedProgress()
              : AdaptiveBody(
                  child: ListView(padding: listPadding(context, const EdgeInsets.all(Space.l)), children: [
                    Row(spacing: Space.s, children: [
                      Icon(_stateIcon(run.state), size: 20, color: s.onSurfaceVariant),
                      Expanded(child: Text('${Fr.automationRunState(run.state)} · ${_runLine(run)}', style: caption)),
                    ]),
                    const SectionHeader(Fr.automationInput),
                    Container(
                      padding: const EdgeInsets.all(Space.m),
                      decoration: BoxDecoration(
                        color: s.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(Radii.m),
                      ),
                      child: Text(run.input, style: theme.textTheme.bodyMedium),
                    ),
                    const SectionHeader(Fr.automationResult),
                    if (text.isNotEmpty) MarkdownView(data: text, onOpenUrl: widget.state.api.openUrl),
                    if (running && text.isEmpty)
                      Semantics(
                        liveRegion: true,
                        child: Row(spacing: Space.s, children: [
                          const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                          Text(Fr.chatGenerating, style: caption),
                        ]),
                      ),
                    if (run.state == 'stopped') Text(Fr.automationStopped, style: caption),
                    if (run.state == 'interrupted') Text(Fr.automationInterrupted, style: caption),
                    if (run.state == 'failed')
                      Container(
                        padding: const EdgeInsets.all(Space.m),
                        decoration: BoxDecoration(color: s.errorContainer, borderRadius: BorderRadius.circular(Radii.m)),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, spacing: Space.xs, children: [
                          Text(
                            run.error ?? Fr.automationRunState('failed'),
                            style: theme.textTheme.bodyMedium?.copyWith(color: s.onErrorContainer),
                          ),
                          if (run.errorDetail != null)
                            Text(
                              run.errorDetail!,
                              style: theme.textTheme.bodySmall?.copyWith(color: s.onErrorContainer, fontFamily: 'monospace'),
                            ),
                        ]),
                      ),
                  ]),
                ),
        );
      },
    );
  }
}

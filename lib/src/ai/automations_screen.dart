import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../bridge/fluluks_api.g.dart';
import '../state/app_state.dart';
import '../strings_fr.dart';
import '../ui/feedback.dart';
import '../ui/states.dart';
import '../ui/tokens.dart';
import '../ui/widgets.dart';
import 'ai_servers_screen.dart';
import 'automation_form.dart';
import 'automation_runs_screen.dart';

/// Automatisations (phase 15) : nom, déclenchement et dernière exécution ; interrupteur des automatisations
/// planifiées ; toucher ouvre la fiche (lancer, historique, modifier). Aucun serveur IA : écran vide qui y mène.
class AutomationsScreen extends StatefulWidget {
  const AutomationsScreen({super.key, required this.state});

  final AppState state;

  @override
  State<AutomationsScreen> createState() => _AutomationsScreenState();
}

class _AutomationsScreenState extends State<AutomationsScreen> {
  late final hub = widget.state.automations;
  late final ai = widget.state.ai;

  @override
  void initState() {
    super.initState();
    ai.watch();
    unawaited(_guard(hub.load()));
  }

  @override
  void dispose() {
    ai.unwatch();
    super.dispose();
  }

  Future<void> _guard(Future<Object?> f) async {
    try {
      await f;
    } on PlatformException catch (e) {
      if (mounted) showMessage(context, e.message ?? Fr.automations, kind: MessageKind.error);
    }
  }

  void _push(Widget page) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([hub, ai]),
      builder: (context, _) {
        final list = hub.automations;
        if (ai.loaded && ai.servers.isEmpty && hub.loaded && list.isEmpty) {
          return Scaffold(
            appBar: AppBar(title: const Text(Fr.automations)),
            body: EmptyState(
              icon: Icons.smart_toy_rounded,
              title: Fr.aiNoServers,
              message: Fr.automationNoServersBody,
              action: FilledButton(
                onPressed: () => _push(AiServersScreen(state: widget.state)),
                child: const Text(Fr.aiServers),
              ),
            ),
          );
        }
        return Scaffold(
          appBar: AppBar(title: const Text(Fr.automations)),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => _push(AutomationForm(state: widget.state)),
            icon: const Icon(Icons.add_rounded),
            label: const Text(Fr.automationNew),
          ),
          body: !hub.loaded
              ? const DelayedProgress()
              : list.isEmpty
                  ? const EmptyState(
                      icon: Icons.bolt_rounded,
                      title: Fr.automationNoneTitle,
                      message: Fr.automationNoneBody,
                    )
                  : AdaptiveBody(
                      child: ListView(
                        padding: listPadding(context, const EdgeInsets.only(bottom: 88)),
                        children: [for (final a in list) _tile(context, a)],
                      ),
                    ),
        );
      },
    );
  }

  Widget _tile(BuildContext context, AutomationMsg a) {
    final periodic = a.trigger == 'periodic';
    final last = a.lastRun;
    final when = periodic ? Fr.automationInterval(a.intervalMinutes ?? 15) : Fr.automationManual;
    final lastText = last == null
        ? Fr.automationNeverRun
        : '${Fr.automationRunState(last.state)}, ${Fr.friendlyDate(last.startedAt ~/ 1000)}';
    return ListTile(
      key: ValueKey(a.id),
      leading: Icon(periodic ? Icons.schedule_rounded : Icons.bolt_rounded),
      title: Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text('$when · $lastText', maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: periodic
          ? MergeSemantics(
              child: Semantics(
                label: Fr.automationEnabled,
                child: Switch(
                  value: a.enabled,
                  onChanged: (v) => _guard(hub.setEnabled(a.id, v)),
                ),
              ),
            )
          : const Icon(Icons.chevron_right_rounded),
      onTap: () => _push(AutomationRunsScreen(state: widget.state, automationId: a.id)),
    );
  }
}

/// Une ligne d'information de la fiche : icône et texte, sur la largeur.
class InfoLine extends StatelessWidget {
  const InfoLine({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(crossAxisAlignment: CrossAxisAlignment.start, spacing: Space.m, children: [
      Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
      Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
    ]);
  }
}

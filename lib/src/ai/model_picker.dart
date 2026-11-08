import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/app_state.dart';
import '../strings_fr.dart';
import '../ui/tokens.dart';
import 'ai_status_dot.dart';

/// Choix du serveur et du modèle (chat, automatisations) : rend (serveur, modèle), ou null si la feuille est fermée.
Future<(String, String)?> showModelPicker(BuildContext context, AppState state, {String? serverId, String? model}) =>
    showModalBottomSheet<(String, String)>(
      context: context,
      useRootNavigator: true, // au-dessus de la barre des modules
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _ModelPicker(state: state, serverId: serverId, model: model),
    );

/// Choix du serveur et du modèle : chaque serveur, son état et ses modèles (lus à l'ouverture). Rend (serveur, modèle).
class _ModelPicker extends StatefulWidget {
  const _ModelPicker({required this.state, required this.serverId, required this.model});

  final AppState state;
  final String? serverId;
  final String? model;

  @override
  State<_ModelPicker> createState() => _ModelPickerState();
}

class _ModelPickerState extends State<_ModelPicker> {
  late final ai = widget.state.ai;
  late final Map<String, Future<List<String>>> _models = {for (final s in ai.servers) s.id: ai.models(s.id)};

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = theme.colorScheme;
    return SafeArea(
      child: ListView(shrinkWrap: true, padding: const EdgeInsets.only(bottom: Space.s), children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.xl, 0, Space.xl, Space.s),
          child: Text(Fr.chatChooseModel, style: theme.textTheme.titleMedium),
        ),
        for (final server in ai.servers) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.xl, Space.m, Space.xl, Space.xs),
            child: Wrap(spacing: Space.s, runSpacing: Space.xs, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Text(server.name, style: theme.textTheme.titleSmall),
              AiStatusDot(state: ai.status(server.id), checking: ai.isChecking(server.id)),
            ]),
          ),
          FutureBuilder<List<String>>(
            future: _models[server.id],
            builder: (context, snap) {
              if (snap.hasError) {
                final e = snap.error;
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Space.xl, vertical: Space.s),
                  child: Text(
                    e is PlatformException ? e.message ?? Fr.aiStatusOffline : Fr.aiStatusOffline,
                    style: theme.textTheme.bodyMedium?.copyWith(color: s.error),
                  ),
                );
              }
              if (!snap.hasData) {
                return const Padding(
                  padding: EdgeInsets.symmetric(horizontal: Space.xl, vertical: Space.s),
                  child: LinearProgressIndicator(),
                );
              }
              final models = snap.data!;
              if (models.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Space.xl, vertical: Space.s),
                  child: Text(Fr.aiNoModels, style: theme.textTheme.bodyMedium),
                );
              }
              return Column(children: [
                for (final m in models)
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: Space.xl),
                    leading: Icon(
                      server.id == widget.serverId && m == widget.model
                          ? Icons.radio_button_checked_rounded
                          : Icons.radio_button_unchecked_rounded,
                    ),
                    title: Text(m),
                    selected: server.id == widget.serverId && m == widget.model,
                    onTap: () => Navigator.pop(context, (server.id, m)),
                  ),
              ]);
            },
          ),
        ],
      ]),
    );
  }
}

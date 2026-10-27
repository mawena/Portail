import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../strings_fr.dart';
import '../ui/states.dart';
import '../ui/tokens.dart';
import '../ui/widgets.dart';
import 'ai_server_form.dart';
import 'ai_status_dot.dart';

/// Serveurs IA (phase 15) : nom, adresse, état en ligne, serveur par défaut ; toucher un serveur ouvre sa fiche
/// (clé, modèles, test de connexion). État vérifié à l'ouverture puis toutes les 60 s tant que l'écran est affiché.
class AiServersScreen extends StatefulWidget {
  const AiServersScreen({super.key, required this.state});

  final AppState state;

  @override
  State<AiServersScreen> createState() => _AiServersScreenState();
}

class _AiServersScreenState extends State<AiServersScreen> {
  late final hub = widget.state.ai;

  @override
  void initState() {
    super.initState();
    hub.watch();
  }

  @override
  void dispose() {
    hub.unwatch();
    super.dispose();
  }

  void _open([String? id]) => Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => AiServerForm(state: widget.state, server: id == null ? null : hub.server(id))));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text(Fr.aiServers)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _open,
        icon: const Icon(Icons.add_rounded),
        label: const Text(Fr.aiAddServer),
      ),
      body: ListenableBuilder(
        listenable: hub,
        builder: (context, _) {
          if (!hub.loaded) return const DelayedProgress();
          if (hub.servers.isEmpty) {
            return const EmptyState(icon: Icons.smart_toy_rounded, title: Fr.aiNoServers, message: Fr.aiNoServersBody);
          }
          return AdaptiveBody(
            child: ListView(padding: listPadding(context, const EdgeInsets.only(bottom: 88)), children: [
              for (final s in hub.servers)
                ListTile(
                  leading: const Icon(Icons.dns_rounded),
                  title: Text(s.name),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: Space.xs),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, spacing: Space.xs, children: [
                      Text(s.baseUrl, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                      Wrap(spacing: Space.s, runSpacing: Space.xs, children: [
                        AiStatusDot(state: hub.status(s.id), checking: hub.isChecking(s.id)),
                        if (s.isDefault) const StatusChip(label: Fr.aiDefaultBadge, icon: Icons.star_rounded),
                      ]),
                    ]),
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => _open(s.id),
                ),
            ]),
          );
        },
      ),
    );
  }
}

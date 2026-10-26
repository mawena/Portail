import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../screens/module_shell.dart';
import '../state/app_state.dart';
import '../strings_fr.dart';
import '../ui/feedback.dart';
import '../ui/states.dart';
import '../ui/tokens.dart';
import '../widgets/bottom_dock.dart';
import '../widgets/source_tile.dart';
import 'ai_servers_screen.dart';
import 'automations_screen.dart';
import 'chat_list_screen.dart';

/// Racine du module « IA » (phase 16, T1) : Chat, Automatisations et Serveurs IA, avec leurs compteurs. Aucun serveur
/// (ni conversation ni automatisation gardée) : écran vide qui mène aux serveurs IA. Les listes sont lues une fois ;
/// l'état en ligne des serveurs n'est pas suivi d'ici (l'écran reste construit quand on change de module).
class AiHomeScreen extends StatefulWidget {
  const AiHomeScreen({super.key, required this.state});

  final AppState state;

  @override
  State<AiHomeScreen> createState() => _AiHomeScreenState();
}

class _AiHomeScreenState extends State<AiHomeScreen> {
  AppState get _state => widget.state;

  @override
  void initState() {
    super.initState();
    if (!_state.ai.loaded) unawaited(_guard(_state.ai.load()));
    if (!_state.chats.loaded) unawaited(_guard(_state.chats.load()));
    if (!_state.automations.loaded) unawaited(_guard(_state.automations.load()));
  }

  Future<void> _guard(Future<Object?> f) async {
    try {
      await f;
    } on PlatformException catch (e) {
      if (mounted) showMessage(context, e.message ?? Fr.genericError, kind: MessageKind.error);
    }
  }

  void _push(Widget page) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

  Widget _tile(IconData icon, String title, String subtitle, Widget Function() page) => Padding(
        padding: const EdgeInsets.only(bottom: Space.s),
        child: Card(
          clipBehavior: Clip.antiAlias,
          child: ListTile(
            leading: TonalIcon(icon),
            title: Text(title),
            subtitle: Text(subtitle),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => _push(page()),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final s = _state;
    return Scaffold(
      appBar: AppBar(title: const Text(Fr.moduleAi), actions: moduleActions(context, s)),
      bottomNavigationBar: BottomDock(state: s),
      body: ListenableBuilder(
        listenable: Listenable.merge([s.ai, s.chats, s.automations]),
        builder: (context, _) {
          final servers = s.ai.servers;
          final conversations = s.chats.conversations;
          final automations = s.automations.automations;
          if (s.ai.loaded && servers.isEmpty && conversations.isEmpty && automations.isEmpty) {
            return EmptyState(
              icon: Icons.smart_toy_rounded,
              title: Fr.aiNoServers,
              message: Fr.aiNoServersBody,
              action: FilledButton(
                onPressed: () => _push(AiServersScreen(state: s)),
                child: const Text(Fr.aiServers),
              ),
            );
          }
          return ListView(padding: const EdgeInsets.all(Space.l), children: [
            _tile(Icons.forum_rounded, Fr.chatTitle, Fr.chatCount(conversations.length),
                () => ChatListScreen(state: s)),
            _tile(Icons.bolt_rounded, Fr.automations, Fr.automationsCount(automations.length),
                () => AutomationsScreen(state: s)),
            _tile(Icons.dns_rounded, Fr.aiServers, Fr.aiServersCount(servers.length), () => AiServersScreen(state: s)),
          ]);
        },
      ),
    );
  }
}

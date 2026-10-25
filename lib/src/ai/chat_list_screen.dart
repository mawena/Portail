import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../bridge/fluluks_api.g.dart';
import '../state/app_state.dart';
import '../strings_fr.dart';
import '../ui/dialogs.dart';
import '../ui/feedback.dart';
import '../ui/sheets.dart';
import '../ui/states.dart';
import '../ui/tokens.dart';
import '../ui/widgets.dart';
import 'ai_servers_screen.dart';
import 'chat_screen.dart';

/// Conversations avec les modèles (phase 15), la plus récente d'abord ; appui long : renommer ou supprimer. Sur grand
/// écran, la conversation choisie s'affiche à côté de la liste. Aucun serveur IA : écran vide qui mène aux serveurs.
class ChatListScreen extends StatefulWidget {
  const ChatListScreen({super.key, required this.state});

  final AppState state;

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  late final chats = widget.state.chats;
  late final ai = widget.state.ai;

  /// Grand écran : conversation montrée (null : la plus récente), ou nouvelle conversation ([_draft]).
  int? _selected;
  bool _draft = false;

  /// Grand écran : change quand l'utilisateur choisit une autre conversation (écran neuf) ; une conversation créée
  /// par le premier envoi garde le même écran.
  int _pane = 0;

  @override
  void initState() {
    super.initState();
    ai.watch();
    unawaited(_guard(chats.load()));
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
      if (mounted) showMessage(context, e.message ?? Fr.chatTitle, kind: MessageKind.error);
    }
  }

  bool get _wide => windowClassOf(context) == WindowClass.expanded;

  void _open(int? id) {
    if (_wide) {
      setState(() {
        _selected = id;
        _draft = id == null;
        _pane++;
      });
      return;
    }
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => ChatScreen(state: widget.state, conversationId: id)));
  }

  Future<void> _actions(ConversationMsg c) async {
    final title = c.title.isEmpty ? Fr.chatNew : c.title;
    final action = await showActionSheet<String>(context, title: title, actions: const [
      SheetAction('rename', Icons.edit_rounded, Fr.rename),
      SheetAction('delete', Icons.delete_rounded, Fr.delete, destructive: true),
    ]);
    if (!mounted) return;
    switch (action) {
      case 'rename':
        final t = await promptText(
          context,
          title: Fr.chatRenameTitle,
          label: Fr.chatTitleLabel,
          initial: c.title,
          validator: (v) => v.trim().isEmpty ? Fr.chatTitleEmpty : null,
        );
        if (t != null && mounted) await _guard(chats.rename(c.id, t.trim()));
      case 'delete':
        final ok = await confirmAction(
          context,
          title: Fr.chatDeleteTitle,
          body: Fr.chatDeleteBody,
          confirmLabel: Fr.delete,
          destructive: true,
        );
        if (!ok || !mounted) return;
        await _guard(chats.delete(c.id));
        if (mounted && _selected == c.id) {
          setState(() {
            _selected = null;
            _pane++;
          });
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([chats, ai]),
      builder: (context, _) {
        final list = chats.conversations;
        if (ai.loaded && ai.servers.isEmpty && chats.loaded && list.isEmpty) {
          return Scaffold(
            appBar: AppBar(title: const Text(Fr.chatTitle)),
            body: EmptyState(
              icon: Icons.smart_toy_rounded,
              title: Fr.aiNoServers,
              message: Fr.chatNoServersBody,
              action: FilledButton(
                onPressed: () => Navigator.of(context)
                    .push(MaterialPageRoute<void>(builder: (_) => AiServersScreen(state: widget.state))),
                child: const Text(Fr.aiServers),
              ),
            ),
          );
        }
        final fab = FloatingActionButton.extended(
          heroTag: null,
          onPressed: () => _open(null),
          icon: const Icon(Icons.add_comment_rounded),
          label: const Text(Fr.chatNew),
        );
        if (!_wide) {
          return Scaffold(
            appBar: AppBar(title: const Text(Fr.chatTitle)),
            floatingActionButton: fab,
            body: AdaptiveBody(child: _list(context, list, null)),
          );
        }
        final shown = _draft ? null : _selected ?? list.firstOrNull?.id;
        return Scaffold(
          body: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SizedBox(
              width: 360,
              child: Scaffold(
                appBar: AppBar(title: const Text(Fr.chatTitle)),
                floatingActionButton: fab,
                body: _list(context, list, shown),
              ),
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: ChatScreen(
                key: ValueKey(_pane),
                state: widget.state,
                conversationId: shown,
                embedded: true,
                onSelect: (id) => setState(() {
                  _selected = id;
                  _draft = false;
                  if (id == null) _pane++;
                }),
              ),
            ),
          ]),
        );
      },
    );
  }

  Widget _list(BuildContext context, List<ConversationMsg> list, int? shown) {
    if (!chats.loaded) return const DelayedProgress();
    if (list.isEmpty) {
      return const EmptyState(
        icon: Icons.forum_rounded,
        title: Fr.chatNoConversations,
        message: Fr.chatNoConversationsBody,
      );
    }
    return ListView(padding: listPadding(context, const EdgeInsets.only(bottom: 88)), children: [
      for (final c in list)
        ListTile(
          key: ValueKey(c.id),
          leading: const Icon(Icons.chat_bubble_outline_rounded),
          title: Text(c.title.isEmpty ? Fr.chatNew : c.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            '${c.model ?? Fr.chatNoModel} · ${Fr.friendlyDate(c.updatedAt ~/ 1000)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: chats.isRunning(c.id)
              ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : null,
          selected: shown == c.id,
          onTap: () => _open(c.id),
          onLongPress: () => _actions(c),
        ),
    ]);
  }
}

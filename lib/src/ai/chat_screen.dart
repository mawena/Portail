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
import 'ai_servers_screen.dart';
import 'chat_hub.dart';
import 'hide_chats.dart';
import 'markdown_view.dart';
import 'model_picker.dart';

/// Conversation avec un modèle (phase 15) : messages de l'utilisateur en bulles à droite, réponses pleine largeur en
/// Markdown, défilement qui suit la réponse tant que l'utilisateur ne remonte pas ; champ multiligne, Envoyer, Arrêter
/// pendant la génération, Régénérer et Copier sur la dernière réponse. Serveur et modèle choisis dans la barre de titre,
/// prompt système, renommer et supprimer dans le menu ⋮.
///
/// [conversationId] null : nouvelle conversation, créée au premier envoi (sur le serveur par défaut et son modèle par
/// défaut, ou ceux choisis avant). [embedded] : à côté de la liste sur grand écran ; [onSelect] reçoit alors la
/// conversation créée, ou null quand elle est supprimée.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.state, this.conversationId, this.embedded = false, this.onSelect});

  final AppState state;
  final int? conversationId;
  final bool embedded;
  final ValueChanged<int?>? onSelect;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with HideChats {
  @override
  AppState get appState => widget.state;

  late final ChatHub chats = widget.state.chats;
  late final ai = widget.state.ai;
  late int? _id = widget.conversationId;
  final _input = TextEditingController();
  final _scroll = ScrollController();

  /// La vue suit la fin de la conversation ; faux dès que l'utilisateur remonte.
  bool _follow = true;
  bool _sending = false;

  /// Serveur et modèle d'une conversation pas encore créée (null : ceux par défaut).
  String? _draftServer;
  String? _draftModel;

  @override
  void initState() {
    super.initState();
    if (!widget.embedded) ai.watch();
    if (!ai.loaded) unawaited(_guard(ai.load()));
    if (!chats.loaded) unawaited(_guard(chats.load()));
    _openThread();
    _input.addListener(() => setState(() {}));
  }

  @override
  void didUpdateWidget(ChatScreen old) {
    super.didUpdateWidget(old);
    if (old.conversationId != widget.conversationId && widget.conversationId != _id) {
      _id = widget.conversationId;
      _follow = true;
      _openThread();
    }
  }

  @override
  void dispose() {
    if (!widget.embedded) ai.unwatch();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _openThread() {
    final id = _id;
    if (id != null) unawaited(_guard(chats.open(id)));
  }

  /// Erreur d'un appel au pont : montrée en message, l'écran reste utilisable.
  Future<void> _guard(Future<Object?> f) async {
    try {
      await f;
    } on PlatformException catch (e) {
      if (mounted) showMessage(context, e.message ?? Fr.chatTitle, kind: MessageKind.error);
    }
  }

  ChatThread? get _thread => _id == null ? null : chats.thread(_id!);

  String? get _serverId => _thread?.conversation.serverId ?? (_id == null ? _draftServer ?? ai.defaultServer?.id : null);

  String? get _model {
    final t = _thread;
    if (t != null) return t.conversation.model;
    if (_id != null) return null;
    if (_draftServer != null) return _draftModel;
    return ai.defaultServer?.defaultModel;
  }

  bool get _running => _id != null && chats.isRunning(_id!);

  String get _modelLabel {
    final sid = _serverId;
    final model = _model;
    if (sid == null) return Fr.chatNoModel;
    final name = ai.server(sid)?.name ?? Fr.chatServerGone;
    return '$name · ${model ?? Fr.chatNoModel}';
  }

  void _toBottom() {
    if (!mounted || !_follow || !_scroll.hasClients) return;
    final p = _scroll.position;
    if (p.pixels != p.maxScrollExtent) _scroll.jumpTo(p.maxScrollExtent);
  }

  bool _onScroll(ScrollNotification n) {
    if ((n is ScrollUpdateNotification && n.dragDetails != null) || n is ScrollEndNotification) {
      final p = n.metrics;
      _follow = p.maxScrollExtent - p.pixels < Layout.minTouch;
    }
    return false;
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      var id = _id;
      if (id == null) {
        id = (await chats.create(_serverId, _model)).id;
        setState(() => _id = id);
        widget.onSelect?.call(id);
      }
      await chats.send(id, text);
      _input.clear();
      _follow = true;
    } on PlatformException catch (e) {
      if (mounted) showMessage(context, e.message ?? Fr.chatTitle, kind: MessageKind.error);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _chooseModel() async {
    final picked = await showModelPicker(context, widget.state, serverId: _serverId, model: _model);
    if (picked == null || !mounted) return;
    final (sid, model) = picked;
    final id = _id;
    if (id == null) {
      setState(() {
        _draftServer = sid;
        _draftModel = model;
      });
    } else {
      await _guard(chats.setModel(id, sid, model));
    }
  }

  Future<void> _systemPrompt(int id) async {
    final current = _thread?.conversation.systemPrompt ?? '';
    final text = await showDialog<String>(context: context, builder: (_) => _SystemPromptDialog(initial: current));
    if (text == null || !mounted) return;
    await _guard(chats.setSystemPrompt(id, text.trim().isEmpty ? null : text.trim()));
  }

  Future<void> _rename(int id) async {
    final title = await promptText(
      context,
      title: Fr.chatRenameTitle,
      label: Fr.chatTitleLabel,
      initial: _thread?.conversation.title ?? '',
      validator: (v) => v.trim().isEmpty ? Fr.chatTitleEmpty : null,
    );
    if (title == null || !mounted) return;
    await _guard(chats.rename(id, title.trim()));
  }

  Future<void> _delete(int id) async {
    final ok = await confirmAction(
      context,
      title: Fr.chatDeleteTitle,
      body: Fr.chatDeleteBody,
      confirmLabel: Fr.delete,
      destructive: true,
    );
    if (!ok || !mounted) return;
    try {
      await chats.delete(id);
    } on PlatformException catch (e) {
      if (mounted) showMessage(context, e.message ?? Fr.chatTitle, kind: MessageKind.error);
      return;
    }
    if (!mounted) return;
    if (widget.embedded) {
      widget.onSelect?.call(null);
    } else {
      Navigator.of(context).pop();
    }
  }

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) showMessage(context, Fr.chatCopied, kind: MessageKind.success);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([chats, ai]),
      builder: (context, _) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _toBottom());
        final thread = _thread;
        final title = thread?.conversation.title ?? '';
        final id = _id;
        return Scaffold(
          appBar: AppBar(
            automaticallyImplyLeading: !widget.embedded,
            title: _TitleBlock(
              title: title.isEmpty ? Fr.chatNew : title,
              modelLabel: _modelLabel,
              onTapModel: _running ? null : _chooseModel,
            ),
            actions: [
              if (id != null)
                PopupMenuButton<void Function()>(
                  tooltip: Fr.moreOptions,
                  icon: const Icon(Icons.more_vert_rounded),
                  onSelected: (f) => f(),
                  itemBuilder: (_) => [
                    PopupMenuItem(value: () => _systemPrompt(id), child: const Text(Fr.chatSystemPrompt)),
                    PopupMenuItem(value: () => _rename(id), child: const Text(Fr.rename)),
                    PopupMenuItem(value: () => _delete(id), child: const Text(Fr.delete)),
                  ],
                ),
            ],
          ),
          body: Column(children: [
            Expanded(child: _body(context, thread)),
            _Composer(
              controller: _input,
              running: _running,
              canSend: !_sending && _input.text.trim().isNotEmpty && _serverId != null && _model != null,
              onSend: _send,
              onStop: id == null ? null : () => _guard(chats.stop(id)),
            ),
          ]),
        );
      },
    );
  }

  Widget _body(BuildContext context, ChatThread? thread) {
    if (ai.loaded && ai.servers.isEmpty && (thread?.messages.isEmpty ?? true)) {
      return EmptyState(
        icon: Icons.smart_toy_rounded,
        title: Fr.aiNoServers,
        message: Fr.chatNoServersBody,
        action: FilledButton(
          onPressed: () => Navigator.of(context)
              .push(MaterialPageRoute<void>(builder: (_) => AiServersScreen(state: widget.state))),
          child: const Text(Fr.aiServers),
        ),
      );
    }
    if (_id != null && thread == null) return const DelayedProgress();
    final messages = thread?.messages ?? const <ChatMessageMsg>[];
    if (messages.isEmpty) {
      return EmptyState(
        icon: Icons.forum_rounded,
        title: _model == null ? Fr.chatNoModel : Fr.chatEmptyThread,
        message: _model == null ? Fr.chatPickModelFirst : null,
      );
    }
    final lastAssistant = messages.lastIndexWhere((m) => m.role == 'assistant');
    return NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: Layout.maxList),
          child: ListView.builder(
            key: const ValueKey('chat-messages'),
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(Space.l, Space.l, Space.l, Space.l),
            itemCount: messages.length,
            itemBuilder: (context, i) {
              final m = messages[i];
              return Padding(
                padding: const EdgeInsets.only(bottom: Space.l),
                child: m.role == 'user'
                    ? _UserBubble(text: m.content, onCopy: () => _copy(m.content))
                    : _Answer(
                        message: m,
                        text: chats.textOf(m),
                        last: i == lastAssistant,
                        running: _running,
                        onCopy: _copy,
                        onRegenerate: () => _guard(chats.regenerate(m.conversationId)),
                        onOpenUrl: widget.state.api.openUrl,
                      ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Titre de la conversation et, dessous, le serveur et le modèle (touchés : choix).
class _TitleBlock extends StatelessWidget {
  const _TitleBlock({required this.title, required this.modelLabel, required this.onTapModel});

  final String title;
  final String modelLabel;
  final VoidCallback? onTapModel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = theme.colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      Semantics(
        button: onTapModel != null,
        hint: Fr.chatChooseModel,
        child: InkWell(
          onTap: onTapModel,
          borderRadius: BorderRadius.circular(Radii.s),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: Space.xs),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Flexible(
                child: Text(
                  modelLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(color: s.onSurfaceVariant),
                ),
              ),
              if (onTapModel != null) Icon(Icons.arrow_drop_down_rounded, size: 20, color: s.onSurfaceVariant),
            ]),
          ),
        ),
      ),
    ]);
  }
}

/// Message de l'utilisateur : bulle à droite (appui long : copier).
class _UserBubble extends StatelessWidget {
  const _UserBubble({required this.text, required this.onCopy});

  final String text;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = theme.colorScheme;
    return LayoutBuilder(
      builder: (context, c) => Align(
        alignment: AlignmentDirectional.centerEnd,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: c.maxWidth * 0.85),
          child: Semantics(
            label: Fr.chatYou,
            child: GestureDetector(
              onLongPress: onCopy,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: Space.l, vertical: Space.m),
                decoration: BoxDecoration(
                  color: s.primaryContainer,
                  borderRadius: BorderRadius.circular(Radii.l),
                ),
                child: Text(text, style: theme.textTheme.bodyLarge?.copyWith(color: s.onPrimaryContainer)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Réponse du modèle, pleine largeur : Markdown, état (en cours, arrêtée, interrompue, échec) et, sur la dernière,
/// Copier et Régénérer (ou Réessayer après un échec).
class _Answer extends StatelessWidget {
  const _Answer({
    required this.message,
    required this.text,
    required this.last,
    required this.running,
    required this.onCopy,
    required this.onRegenerate,
    required this.onOpenUrl,
  });

  final ChatMessageMsg message;
  final String text;
  final bool last;
  final bool running;
  final ValueChanged<String> onCopy;
  final VoidCallback onRegenerate;
  final Future<void> Function(String url) onOpenUrl;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = theme.colorScheme;
    final caption = theme.textTheme.labelMedium?.copyWith(color: s.onSurfaceVariant);
    final streaming = message.state == 'streaming';
    final failed = message.state == 'failed';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, spacing: Space.s, children: [
      if (text.isNotEmpty) MarkdownView(data: text, onOpenUrl: onOpenUrl),
      if (streaming && text.isEmpty)
        Semantics(
          liveRegion: true,
          child: Row(spacing: Space.s, children: [
            const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            Text(Fr.chatGenerating, style: caption),
          ]),
        ),
      if (message.state == 'stopped') Text(Fr.chatStopped, style: caption),
      if (message.state == 'interrupted') Text(Fr.chatInterrupted, style: caption),
      if (failed)
        Container(
          padding: const EdgeInsets.all(Space.m),
          decoration: BoxDecoration(color: s.errorContainer, borderRadius: BorderRadius.circular(Radii.m)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, spacing: Space.xs, children: [
            Text(message.error ?? Fr.chatTitle, style: theme.textTheme.bodyMedium?.copyWith(color: s.onErrorContainer)),
            if (message.errorDetail != null)
              Text(
                message.errorDetail!,
                style: theme.textTheme.bodySmall?.copyWith(color: s.onErrorContainer, fontFamily: 'monospace'),
              ),
          ]),
        ),
      if (last && !running)
        Wrap(spacing: Space.xs, crossAxisAlignment: WrapCrossAlignment.center, children: [
          if (failed || message.state == 'interrupted')
            TextButton.icon(
              onPressed: onRegenerate,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text(Fr.retry),
            )
          else
            IconButton(
              tooltip: Fr.chatRegenerate,
              icon: const Icon(Icons.refresh_rounded),
              onPressed: onRegenerate,
            ),
          if (text.isNotEmpty)
            IconButton(
              tooltip: Fr.chatCopyReply,
              icon: const Icon(Icons.content_copy_rounded),
              onPressed: () => onCopy(text),
            ),
        ]),
    ]);
  }
}

/// Champ du message, Envoyer, ou Arrêter pendant une réponse.
class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.running,
    required this.canSend,
    required this.onSend,
    required this.onStop,
  });

  final TextEditingController controller;
  final bool running;
  final bool canSend;
  final VoidCallback onSend;
  final VoidCallback? onStop;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Material(
      color: s.surfaceContainerLow,
      child: SafeArea(
        top: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: Layout.maxList),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(Space.l, Space.s, Space.s, Space.s),
              child: Row(crossAxisAlignment: CrossAxisAlignment.end, spacing: Space.s, children: [
                Expanded(
                  child: TextField(
                    controller: controller,
                    minLines: 1,
                    maxLines: 6,
                    keyboardType: TextInputType.multiline,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(
                      hintText: Fr.chatInputHint,
                      filled: true,
                      fillColor: s.surfaceContainerHighest,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(Radii.xl),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(horizontal: Space.l, vertical: Space.m),
                    ),
                  ),
                ),
                if (running)
                  IconButton.filledTonal(
                    tooltip: Fr.chatStop,
                    icon: const Icon(Icons.stop_rounded),
                    onPressed: onStop,
                  )
                else
                  IconButton.filled(
                    tooltip: Fr.chatSend,
                    icon: const Icon(Icons.arrow_upward_rounded),
                    onPressed: canSend ? onSend : null,
                  ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// Prompt système de la conversation : texte libre, vide pour aucun.
class _SystemPromptDialog extends StatefulWidget {
  const _SystemPromptDialog({required this.initial});

  final String initial;

  @override
  State<_SystemPromptDialog> createState() => _SystemPromptDialogState();
}

class _SystemPromptDialogState extends State<_SystemPromptDialog> {
  late final _c = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text(Fr.chatSystemPrompt),
        scrollable: true,
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text(Fr.chatSystemPromptHelp),
          const SizedBox(height: Space.m),
          TextField(
            controller: _c,
            autofocus: true,
            minLines: 3,
            maxLines: 8,
            keyboardType: TextInputType.multiline,
            decoration: const InputDecoration(border: OutlineInputBorder()),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text(Fr.cancel)),
          FilledButton(onPressed: () => Navigator.pop(context, _c.text), child: const Text(Fr.save)),
        ],
      );
}

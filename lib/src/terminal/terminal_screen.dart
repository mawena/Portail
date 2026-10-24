import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../bridge/fluluks_api.g.dart';
import '../state/app_state.dart';
import '../state/prefs.dart';
import '../strings_fr.dart';
import '../ui/dialogs.dart';
import '../ui/feedback.dart';
import '../ui/tokens.dart';
import '../widgets/server_tile.dart';
import 'key_bar.dart';
import 'snippets_sheet.dart';
import 'terminal_hub.dart';
import 'terminal_theme.dart';
import 'tunnels_screen.dart';

enum _Menu { paste, snippets, tunnels, fontSize, close }

/// Ouvre un terminal sur le serveur SFTP [s] (mot de passe, empreinte et échecs comme pour l'explorateur), puis son
/// écran ; [startDir] : dossier de départ (« Ouvrir un terminal ici »).
Future<void> openTerminal(BuildContext context, AppState state, RemoteServerMsg s, {String? startDir}) async {
  // contexte du Navigator : la session, annoncée pendant la connexion, ajoute la carte des sessions à l'accueil et la
  // tuile qui a lancé l'ouverture est reconstruite ; dialogues (mot de passe, empreinte) et écran partent d'ici
  context = Navigator.of(context).context;
  final e = await withServerAuth(
    context,
    state,
    s,
    (pw) => state.terminals.open(s.id, password: pw, startDir: startDir),
  );
  if (e == null || !context.mounted) return;
  await showTerminal(context, state, e.info.id);
}

/// Écran de la session [sessionId], déjà ouverte.
Future<void> showTerminal(BuildContext context, AppState state, String sessionId) => Navigator.of(context)
    .push(MaterialPageRoute<void>(builder: (_) => TerminalScreen(state: state, sessionId: sessionId)));

/// Écran d'un terminal SSH (phase 13) : affichage xterm de la session [sessionId] tenue par `AppState.terminals`.
/// Pincer change la taille du texte (8 à 32, mémorisée) ; appui long : sélection, puis « Copier » ; menu ⋮ : Coller,
/// Taille du texte, Fermer la session. Une session fermée propose « Reconnecter » sur le même serveur.
class TerminalScreen extends StatefulWidget {
  const TerminalScreen({super.key, required this.state, required this.sessionId});

  final AppState state;
  final String sessionId;

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> {
  late String _id = widget.sessionId;
  final _controller = TerminalController();
  final _focus = FocusNode();
  final _mods = KeyModifiers();
  bool _secure = false;

  // pincement à deux doigts : position des doigts, écart et taille au départ, taille en cours
  final _pointers = <int, Offset>{};
  double? _pinchStartDistance;
  double _pinchStartSize = terminalFontDefault.toDouble();
  double? _pinchSize;

  AppState get _state => widget.state;
  TerminalHub get _hub => _state.terminals;

  @override
  void initState() {
    super.initState();
    _hub.addListener(_changed);
    _state.uiPrefsListenable.addListener(_changed);
    _controller.addListener(_changed);
    if (_state.uiPrefs.terminalSecure ?? false) {
      _secure = true;
      _state.api.setSecureScreen(true);
    }
  }

  @override
  void dispose() {
    _hub.removeListener(_changed);
    _state.uiPrefsListenable.removeListener(_changed);
    _controller.removeListener(_changed);
    if (_secure) _state.api.setSecureScreen(false);
    final e = _hub.entry(_id);
    if (e != null && e.inputFilter == _mods.apply) e.inputFilter = null;
    _mods.dispose();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  double get _fontSize => _pinchSize ?? _state.uiPrefs.terminalFont.toDouble();

  RemoteServerMsg? _server(TerminalEntry e) {
    for (final s in _state.servers) {
      if (s.id == e.info.serverId) return s;
    }
    return null;
  }

  // --- pincement

  void _down(PointerDownEvent ev) {
    _pointers[ev.pointer] = ev.position;
    if (_pointers.length == 2) {
      final p = _pointers.values.toList();
      _pinchStartDistance = (p[0] - p[1]).distance;
      _pinchStartSize = _fontSize;
    }
  }

  void _move(PointerMoveEvent ev) {
    if (!_pointers.containsKey(ev.pointer)) return;
    _pointers[ev.pointer] = ev.position;
    final start = _pinchStartDistance;
    if (_pointers.length != 2 || start == null || start < 1) return;
    final p = _pointers.values.toList();
    final size = (_pinchStartSize * (p[0] - p[1]).distance / start)
        .clamp(terminalFontMin.toDouble(), terminalFontMax.toDouble());
    setState(() => _pinchSize = size);
  }

  void _up(PointerEvent ev) {
    _pointers.remove(ev.pointer);
    if (_pointers.length >= 2 || _pinchStartDistance == null) return;
    _pinchStartDistance = null;
    final size = _pinchSize;
    if (size != null) _saveFontSize(size.round());
  }

  Future<void> _saveFontSize(int size) async {
    await _state.setUiPrefs(_state.uiPrefs.copyWith(terminalFontSize: size));
    if (mounted) setState(() => _pinchSize = null);
  }

  // --- actions

  Future<void> _copy(TerminalEntry e) async {
    final range = _controller.selection;
    if (range == null) return;
    final text = e.terminal.buffer.getText(range);
    _controller.clearSelection();
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) showMessage(context, Fr.terminalCopied, kind: MessageKind.success);
  }

  /// Colle le presse-papiers ; plusieurs lignes : confirmé d'abord (chacune serait exécutée). Les fins de ligne
  /// partent en retour chariot, comme d'un terminal.
  Future<void> _paste(TerminalEntry e) async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (text == null || text.isEmpty || !mounted) return;
    final lines = text.split('\n');
    while (lines.length > 1 && lines.last.trim().isEmpty) {
      lines.removeLast();
    }
    if (lines.length > 1) {
      final ok = await confirmAction(
        context,
        title: Fr.pasteLines(lines.length),
        body: Fr.pasteLinesHelp,
        confirmLabel: Fr.terminalPaste,
      );
      if (!ok) return;
    }
    e.terminal.paste(text.replaceAll('\r\n', '\r').replaceAll('\n', '\r'));
  }

  Future<void> _snippets(TerminalEntry e) async {
    final s = await showSnippetsSheet(context, _state, e);
    if (s != null && mounted) await runSnippet(context, _state, e, s);
  }

  /// La sélection devient une nouvelle commande enregistrée.
  Future<void> _saveSelection(TerminalEntry e) async {
    final range = _controller.selection;
    if (range == null) return;
    final text = e.terminal.buffer.getText(range).trim();
    _controller.clearSelection();
    await editSnippet(context, _state, e, command: text);
  }

  Future<void> _chooseFontSize() async {
    var value = _state.uiPrefs.terminalFont.toDouble();
    final chosen = await showDialog<double>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text(Fr.terminalFontSize),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(Fr.terminalFontValue(value.round())),
            Slider(
              value: value,
              min: terminalFontMin.toDouble(),
              max: terminalFontMax.toDouble(),
              divisions: terminalFontMax - terminalFontMin,
              label: Fr.terminalFontValue(value.round()),
              onChanged: (v) => set(() => value = v),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text(Fr.cancel)),
            TextButton(onPressed: () => Navigator.pop(ctx, value), child: const Text(Fr.ok)),
          ],
        ),
      ),
    );
    if (chosen != null) await _saveFontSize(chosen.round());
  }

  Future<void> _close(TerminalEntry e) async {
    if (e.isOpen) {
      final ok = await confirmAction(
        context,
        title: Fr.closeSessionAsk,
        body: Fr.closeSessionHelp,
        confirmLabel: Fr.closeSession,
        destructive: true,
      );
      if (!ok) return;
    }
    _hub.close(e.info.id);
    if (mounted) Navigator.pop(context);
  }

  /// Nouvelle session sur le même serveur (mot de passe et empreinte demandés comme pour l'explorateur) ; l'ancienne
  /// est oubliée.
  Future<void> _reconnect(TerminalEntry e) async {
    final old = e.info.id;
    final s = _server(e);
    final TerminalEntry? fresh;
    if (s == null) {
      fresh = await _hub.open(e.info.serverId);
    } else {
      fresh = await withServerAuth(context, _state, s, (pw) => _hub.open(s.id, password: pw));
    }
    if (fresh == null || !mounted) return;
    final id = fresh.info.id;
    _hub.close(old);
    setState(() => _id = id);
  }

  @override
  Widget build(BuildContext context) {
    final e = _hub.entry(_id);
    if (e == null) {
      return Scaffold(
        appBar: AppBar(title: const Text(Fr.sessionClosed)),
        body: const Center(child: Text(Fr.sessionClosed)),
      );
    }
    final cs = Theme.of(context).colorScheme;
    final serverName = _server(e)?.name ?? e.info.title;
    e.inputFilter = _mods.apply; // Ctrl et Alt de la barre s'appliquent aussi au clavier du téléphone
    return Scaffold(
      appBar: AppBar(
        title: Text(e.title, overflow: TextOverflow.ellipsis),
        actions: [
          if (_hub.sessions.length > 1)
            PopupMenuButton<String>(
              tooltip: Fr.sshSessions,
              icon: const Icon(Icons.layers_rounded),
              onSelected: (id) {
                _controller.clearSelection();
                setState(() => _id = id);
              },
              itemBuilder: (_) => [
                for (final s in _hub.sessions)
                  CheckedPopupMenuItem(value: s.info.id, checked: s.info.id == _id, child: Text(s.title)),
              ],
            ),
          if (_controller.selection != null) ...[
            IconButton(tooltip: Fr.copy, icon: const Icon(Icons.copy_rounded), onPressed: () => _copy(e)),
            IconButton(
              tooltip: Fr.saveAsSnippet,
              icon: const Icon(Icons.bookmark_add_rounded),
              onPressed: () => _saveSelection(e),
            ),
          ],
          PopupMenuButton<_Menu>(
            tooltip: Fr.moreOptions,
            onSelected: (m) => switch (m) {
              _Menu.paste => _paste(e),
              _Menu.snippets => _snippets(e),
              _Menu.tunnels => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) =>
                      TunnelsScreen(state: _state, serverId: e.info.serverId, sessionId: e.isOpen ? e.info.id : null))),
              _Menu.fontSize => _chooseFontSize(),
              _Menu.close => _close(e),
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: _Menu.paste, enabled: e.isOpen, child: const Text(Fr.terminalPaste)),
              PopupMenuItem(value: _Menu.snippets, enabled: e.isOpen, child: const Text(Fr.snippets)),
              const PopupMenuItem(value: _Menu.tunnels, child: Text(Fr.tunnels)),
              const PopupMenuItem(value: _Menu.fontSize, child: Text(Fr.terminalFontSize)),
              const PopupMenuItem(value: _Menu.close, child: Text(Fr.closeSession)),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: Column(children: [
          if (e.isClosed) _ClosedBar(message: e.info.error ?? Fr.sessionClosed, onReconnect: () => _reconnect(e)),
          Expanded(
            child: Listener(
              onPointerDown: _down,
              onPointerMove: _move,
              onPointerUp: _up,
              onPointerCancel: _up,
              child: Semantics(
                label: Fr.terminalOf(serverName),
                child: TerminalView(
                  e.terminal,
                  controller: _controller,
                  focusNode: _focus,
                  autofocus: true,
                  readOnly: !e.isOpen,
                  theme: terminalTheme(cs),
                  textStyle: TerminalStyle(fontSize: _fontSize, fontFamily: 'monospace'),
                  keyboardType: TextInputType.visiblePassword, // ni correction ni suggestion
                  keyboardAppearance: cs.brightness,
                  padding: const EdgeInsets.all(Space.xs),
                ),
              ),
            ),
          ),
          if (e.isOpen)
            KeyBar(
              onInput: (s) => _hub.send(e.info.id, s),
              modifiers: _mods,
              appCursorKeys: () => e.terminal.cursorKeysMode,
            ),
        ]),
      ),
    );
  }
}

/// Bandeau d'une session fermée : la raison et « Reconnecter ».
class _ClosedBar extends StatelessWidget {
  const _ClosedBar({required this.message, required this.onReconnect});

  final String message;
  final VoidCallback onReconnect;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.errorContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.m, vertical: Space.xs),
        child: Row(children: [
          Icon(Icons.link_off_rounded, color: cs.onErrorContainer),
          const SizedBox(width: Space.m),
          Expanded(child: Text(message, style: TextStyle(color: cs.onErrorContainer))),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: cs.onErrorContainer, minimumSize: const Size(48, 48)),
            onPressed: onReconnect,
            child: const Text(Fr.reconnect),
          ),
        ]),
      ),
    );
  }
}

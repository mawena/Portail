import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../bridge/fluluks_api.g.dart';
import '../state/app_state.dart';
import '../strings_fr.dart';
import '../ui/dialogs.dart';
import '../ui/feedback.dart';
import '../ui/states.dart';
import '../ui/tokens.dart';

enum _TunnelMenu { edit, delete }

/// « Tunnels » d'un serveur (phase 13) : `127.0.0.1:<port>` du téléphone vers un service vu du serveur. Avec un
/// terminal ouvert ([sessionId]), chaque tunnel s'active ou se coupe, et un tunnel actif s'ouvre dans le navigateur ;
/// sans terminal (fiche du serveur), on les prépare seulement.
class TunnelsScreen extends StatefulWidget {
  const TunnelsScreen({super.key, required this.state, required this.serverId, this.sessionId});

  final AppState state;
  final String serverId;
  final String? sessionId;

  @override
  State<TunnelsScreen> createState() => _TunnelsScreenState();
}

class _TunnelsScreenState extends State<TunnelsScreen> {
  List<TunnelMsg>? _list;
  final _busy = <String>{};

  AppState get _state => widget.state;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final l = await _state.api.tunnels(widget.serverId);
    if (mounted) setState(() => _list = l);
  }

  void _error(PlatformException e) {
    if (mounted) showMessage(context, e.message ?? Fr.genericError, kind: MessageKind.error);
  }

  Future<void> _toggle(TunnelMsg t, bool on) async {
    final session = widget.sessionId;
    if (session == null) return;
    setState(() => _busy.add(t.id));
    try {
      if (on) {
        await _state.api.startTunnel(session, t.id);
      } else {
        await _state.api.stopTunnel(session, t.id);
      }
    } on PlatformException catch (e) {
      _error(e);
    } finally {
      _busy.remove(t.id);
      await _load();
    }
  }

  Future<void> _edit([TunnelMsg? t]) async {
    final changed = await showDialog<bool>(
      context: context,
      builder: (_) => _TunnelEditor(state: _state, serverId: widget.serverId, initial: t),
    );
    if (changed ?? false) await _load();
  }

  Future<void> _menu(TunnelMsg t, _TunnelMenu m) async {
    switch (m) {
      case _TunnelMenu.edit:
        await _edit(t);
      case _TunnelMenu.delete:
        final ok = await confirmAction(context, title: Fr.deleteTunnelAsk, confirmLabel: Fr.delete, destructive: true);
        if (!ok) return;
        try {
          await _state.api.deleteTunnel(t.id);
        } on PlatformException catch (e) {
          _error(e);
        }
        await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = _list;
    final theme = Theme.of(context);
    final canToggle = widget.sessionId != null;
    return Scaffold(
      appBar: AppBar(title: const Text(Fr.tunnels)),
      body: SafeArea(
        child: list == null
            ? const DelayedProgress()
            : ListView(padding: const EdgeInsets.all(Space.l), children: [
                if (!canToggle)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Space.m),
                    child: Text(Fr.tunnelsNeedTerminal,
                        style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  ),
                if (list.isEmpty)
                  const EmptyState(icon: Icons.swap_horiz_rounded, title: Fr.noTunnels, message: Fr.noTunnelsBody)
                else
                  for (final t in list)
                    Card(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        ListTile(
                          leading: Icon(Icons.swap_horiz_rounded,
                              color: t.active ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant),
                          title: Text(Fr.tunnelLine(t.localPort, t.remoteHost, t.remotePort),
                              style: const TextStyle(fontFamily: 'monospace')),
                          subtitle: t.error != null
                              ? Text(t.error!, style: TextStyle(color: theme.colorScheme.error))
                              : (t.auto ? const Text(Fr.tunnelAutoOn) : null),
                          trailing: PopupMenuButton<_TunnelMenu>(
                            tooltip: Fr.tunnelOptions,
                            onSelected: (m) => _menu(t, m),
                            itemBuilder: (_) => const [
                              PopupMenuItem(value: _TunnelMenu.edit, child: Text(Fr.editTunnel)),
                              PopupMenuItem(value: _TunnelMenu.delete, child: Text(Fr.delete)),
                            ],
                          ),
                        ),
                        if (canToggle)
                          SwitchListTile(
                            title: const Text(Fr.tunnelActive),
                            value: t.active,
                            onChanged: _busy.contains(t.id) ? null : (on) => _toggle(t, on),
                          ),
                        if (t.active)
                          Align(
                            alignment: AlignmentDirectional.centerStart,
                            child: Padding(
                              padding: const EdgeInsets.only(left: Space.s, bottom: Space.s),
                              child: TextButton.icon(
                                icon: const Icon(Icons.open_in_browser_rounded),
                                label: const Text(Fr.openInBrowser),
                                onPressed: () async {
                                  try {
                                    await _state.api.openUrl('http://127.0.0.1:${t.localPort}');
                                  } on PlatformException catch (e) {
                                    _error(e);
                                  }
                                },
                              ),
                            ),
                          ),
                      ]),
                    ),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    icon: const Icon(Icons.add_rounded),
                    label: const Text(Fr.addTunnel),
                    onPressed: () => _edit(),
                  ),
                ),
              ]),
      ),
    );
  }
}

class _TunnelEditor extends StatefulWidget {
  const _TunnelEditor({required this.state, required this.serverId, required this.initial});

  final AppState state;
  final String serverId;
  final TunnelMsg? initial;

  @override
  State<_TunnelEditor> createState() => _TunnelEditorState();
}

class _TunnelEditorState extends State<_TunnelEditor> {
  late final _local = TextEditingController(text: widget.initial?.localPort.toString() ?? '');
  late final _host = TextEditingController(text: widget.initial?.remoteHost ?? 'localhost');
  late final _remote = TextEditingController(text: widget.initial?.remotePort.toString() ?? '');
  late bool _auto = widget.initial?.auto ?? false;
  String? _localError;
  String? _hostError;
  String? _remoteError;

  @override
  void dispose() {
    for (final c in [_local, _host, _remote]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final local = int.tryParse(_local.text.trim());
    final remote = int.tryParse(_remote.text.trim());
    final host = _host.text.trim();
    setState(() {
      _localError = local == null || local < 1024 || local > 65535 ? Fr.tunnelLocalPortRange : null;
      _remoteError = remote == null || remote < 1 || remote > 65535 ? Fr.tunnelRemotePortRange : null;
      _hostError = host.isEmpty || host.contains(RegExp(r'\s')) ? Fr.tunnelHostInvalid : null;
    });
    if (_localError != null || _remoteError != null || _hostError != null) return;
    try {
      await widget.state.api.saveTunnel(TunnelMsg(
        id: widget.initial?.id ?? '',
        serverId: widget.serverId,
        localPort: local!,
        remoteHost: host,
        remotePort: remote!,
        auto: _auto,
        active: false,
      ));
      if (mounted) Navigator.pop(context, true);
    } on PlatformException catch (e) {
      if (mounted) showMessage(context, e.message ?? Fr.genericError, kind: MessageKind.error);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.initial == null ? Fr.newTunnel : Fr.editTunnel),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: _local,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: Fr.tunnelLocalPort, errorText: _localError),
            ),
            TextField(
              controller: _host,
              autocorrect: false,
              decoration: InputDecoration(labelText: Fr.tunnelRemoteHost, errorText: _hostError),
            ),
            TextField(
              controller: _remote,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: Fr.tunnelRemotePort, errorText: _remoteError),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text(Fr.tunnelAuto),
              value: _auto,
              onChanged: (v) => setState(() => _auto = v),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text(Fr.cancel)),
          TextButton(onPressed: _save, child: const Text(Fr.save)),
        ],
      );
}

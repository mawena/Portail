import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:xterm/xterm.dart';

import '../bridge/fluluks_api.g.dart';
import '../state/host_api.dart';
import 'portail_terminal.dart';

/// Historique gardé par le terminal Dart, en lignes.
const terminalScrollback = 10000;

/// Un terminal vu de Dart : l'état publié par Kotlin ([info]), l'émulateur xterm ([terminal]) et le titre posé par le
/// programme distant (séquence OSC 0 ou 2).
class TerminalEntry {
  TerminalEntry._(this.info, this.terminal);

  TerminalSessionMsg info;
  final Terminal terminal;
  String? oscTitle;

  /// Transforme ce que tape le clavier du téléphone (Ctrl ou Alt de la barre de touches), posé par l'écran.
  String Function(String data)? inputFilter;

  /// Décodage UTF-8 en flux : un caractère coupé entre deux lots reste entier.
  late final ByteConversionSink _decoder =
      const Utf8Decoder(allowMalformed: true).startChunkedConversion(_TerminalSink(terminal));

  String get title => (oscTitle?.trim().isNotEmpty ?? false) ? oscTitle! : info.title;
  bool get isOpen => info.state == 'open';
  bool get isClosed => info.state == 'closed';
}

class _TerminalSink implements Sink<String> {
  _TerminalSink(this.t);
  final Terminal t;

  @override
  void add(String data) => t.write(data);

  @override
  void close() {}
}

/// Sessions de terminal côté Dart (phase 13) : tenues ici, hors de tout écran, pour qu'un écran se ferme et se rouvre
/// sans rien perdre. La sortie arrive par [onOutput], les états par [onChanged] (appelés par `AppState`) ; les octets
/// tapés partent vers Kotlin, encodés en UTF-8.
class TerminalHub extends ChangeNotifier {
  TerminalHub(this.api, {this.onBell});

  final HostApi api;

  /// Sonnerie du terminal (BEL) : vibration si les retours haptiques sont activés.
  final VoidCallback? onBell;

  final _entries = <String, TerminalEntry>{};

  /// Sessions, dans l'ordre d'ouverture.
  List<TerminalEntry> get sessions => List.unmodifiable(_entries.values);

  TerminalEntry? entry(String id) => _entries[id];

  Terminal terminalOf(String id) => _entries[id]!.terminal;

  /// Ouvre un terminal sur [serverId] ; erreurs de connexion rendues telles quelles (`auth`, `hostkey-unknown`…).
  Future<TerminalEntry> open(String serverId, {Uint8List? password, String? startDir}) async {
    final msg = await api.openTerminal(serverId, password, startDir);
    final e = _adopt(msg);
    notifyListeners();
    return e;
  }

  /// Envoie [data] tel quel à la session [id] si elle est ouverte (barre de touches, collage déjà transformé).
  void send(String id, String data) {
    if (_entries[id]?.isOpen ?? false) api.terminalWrite(id, Uint8List.fromList(utf8.encode(data)));
  }

  /// Ferme et oublie [id] (côté Kotlin aussi).
  void close(String id) {
    if (_entries.remove(id) == null) return;
    api.closeTerminal(id);
    notifyListeners();
  }

  /// Après une réouverture de l'application : reprend les sessions encore ouvertes côté Kotlin et leur sortie récente.
  Future<void> restore() async {
    final known = await api.terminalSessions();
    var changed = false;
    for (final msg in known) {
      if (_entries.containsKey(msg.id)) continue;
      final e = _adopt(msg);
      final backlog = await api.terminalBacklog(msg.id);
      e._decoder.add(backlog);
      changed = true;
    }
    if (changed) notifyListeners();
  }

  void onOutput(String id, Uint8List data) {
    _entries[id]?._decoder.add(data);
  }

  void onChanged(TerminalSessionMsg msg) {
    // retirée côté Kotlin (fermée à la demande, « Tout fermer », ouverture qui a échoué) : oubliée ici aussi
    if (msg.state == 'gone') {
      if (_entries.remove(msg.id) != null) notifyListeners();
      return;
    }
    final e = _entries[msg.id];
    if (e == null) {
      // annoncée avant la réponse d'ouverture : adoptée ; fermée sans être connue : rien à montrer
      if (msg.state == 'closed') return;
      _adopt(msg);
    } else {
      e.info = msg;
    }
    notifyListeners();
  }

  TerminalEntry _adopt(TerminalSessionMsg msg) {
    final existing = _entries[msg.id];
    if (existing != null) {
      existing.info = msg;
      return existing;
    }
    final id = msg.id;
    late final TerminalEntry e;
    final t = PortailTerminal(
      maxLines: terminalScrollback,
      onOutput: (data) => send(id, e.inputFilter?.call(data) ?? data),
      onResize: (w, h, pw, ph) {
        if (!e.isClosed) api.terminalResize(id, w, h);
      },
      onTitleChange: (title) {
        e.oscTitle = title;
        notifyListeners();
      },
      onBell: () => onBell?.call(),
    );
    e = TerminalEntry._(msg, t);
    _entries[id] = e;
    return e;
  }
}

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluluks/src/bridge/fluluks_api.g.dart';
import 'package:fluluks/src/state/app_state.dart';
import 'package:fluluks/src/terminal/terminal_hub.dart';
import 'package:xterm/xterm.dart';

import 'fake_host_api.dart';

/// Phase 13, T4 : le hub des terminaux (sessions côté Dart) et le paquet xterm.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  String screen(Terminal t) => t.buffer.lines.toList().map((l) => l.toString().trimRight()).join('\n').trimRight();

  Uint8List bytes(String s) => Uint8List.fromList(utf8.encode(s));

  test('xtermColorsCells', () {
    final t = Terminal();
    t.write('\x1b[31mrouge\x1b[0m');
    final line = t.buffer.lines[0];
    expect(String.fromCharCode(line.getCodePoint(0)), 'r');
    expect(line.getForeground(0), CellColor.named | NamedColor.red);
    expect(line.getForeground(5) & CellColor.typeMask, CellColor.normal); // après la remise à zéro
  });

  test('outputAppearsInTerminal', () async {
    final api = FakeHostApi();
    final hub = TerminalHub(api);
    final e = await hub.open('s1');
    hub.onOutput(e.info.id, bytes('bonjour '));
    // « é » coupé entre deux lots : décodé d'un seul tenant
    hub.onOutput(e.info.id, Uint8List.fromList([0x6c, 0xc3]));
    hub.onOutput(e.info.id, Uint8List.fromList([0xa9, 0x74, 0xc3, 0xa9]));
    expect(screen(hub.terminalOf(e.info.id)), 'bonjour lété');
    expect(hub.sessions.single.info.id, e.info.id);
  });

  test('typedBytesReachBridge', () async {
    final api = FakeHostApi();
    final hub = TerminalHub(api);
    final e = await hub.open('s1');
    hub.terminalOf(e.info.id).textInput('é');
    await Future<void>.delayed(Duration.zero);
    expect(api.terminalWrites.single.$1, e.info.id);
    expect(api.terminalWrites.single.$2, [0xc3, 0xa9]);
  });

  test('titleFromOsc', () async {
    final hub = TerminalHub(FakeHostApi());
    final e = await hub.open('s1');
    expect(e.title, 's1');
    hub.onOutput(e.info.id, bytes('\x1b]0;charles@cloud: ~\x07'));
    expect(hub.sessions.single.title, 'charles@cloud: ~');
  });

  test('reopenRestoresBacklog', () async {
    final api = FakeHostApi()
      ..terminals.add(TerminalSessionMsg(id: 't9', serverId: 's1', title: 'Maison', state: 'open', cols: 80, rows: 24))
      ..terminalBacklogs['t9'] = bytes('déjà là\r\n');
    final hub = TerminalHub(api);
    await hub.restore();
    await hub.restore(); // sans doublon
    expect(hub.sessions.map((s) => s.info.id), ['t9']);
    expect(screen(hub.terminalOf('t9')), 'déjà là');
  });

  test('changesFollowKotlin', () async {
    final hub = TerminalHub(FakeHostApi());
    // une session annoncée avant la réponse d'ouverture est adoptée, sa sortie gardée
    hub.onChanged(TerminalSessionMsg(id: 'tx', serverId: 's1', title: 'Maison', state: 'connecting', cols: 80, rows: 24));
    hub.onOutput('tx', bytes('cd ok'));
    hub.onChanged(TerminalSessionMsg(
        id: 'tx', serverId: 's1', title: 'Maison', state: 'closed', error: 'Connexion au serveur perdue', cols: 80, rows: 24));
    final e = hub.sessions.single;
    expect(e.isOpen, isFalse);
    expect(e.info.error, 'Connexion au serveur perdue');
    expect(screen(e.terminal), 'cd ok');
    // fermée à la demande : retirée, un « closed » tardif n'y revient pas
    hub.close('tx');
    hub.onChanged(TerminalSessionMsg(id: 'tx', serverId: 's1', title: 'Maison', state: 'closed', cols: 80, rows: 24));
    expect(hub.sessions, isEmpty);
  });

  testWidgets('bellVibratesWhenHapticsOn', (tester) async {
    final calls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      calls.add(call.method);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final api = FakeHostApi();
    final state = AppState(api);
    await state.loadUiPrefs();
    final e = await state.terminals.open('s1');
    state.onTerminalOutput(e.info.id, bytes('\x07'));
    expect(calls.where((c) => c == 'HapticFeedback.vibrate'), hasLength(1));
    api.uiPrefs = UiPrefsMsg(theme: 'system', haptics: false, welcomeSeen: true);
    await state.loadUiPrefs();
    state.onTerminalOutput(e.info.id, bytes('\x07'));
    expect(calls.where((c) => c == 'HapticFeedback.vibrate'), hasLength(1));
  });
}

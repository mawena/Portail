import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluluks/src/strings_fr.dart';
import 'package:fluluks/src/terminal/key_bar.dart';
import 'package:fluluks/src/terminal/terminal_screen.dart';
import 'package:xterm/xterm.dart';

import 'remote_test.dart' show api0, pump;

/// Phase 13, T5 : barre de touches du terminal (Échap, Tab, Ctrl, Alt, flèches, Début, Fin, pages, symboles).
void main() {
  /// Barre seule ; rend ce qu'elle envoie. [app] : mode curseur d'application du terminal.
  Future<List<String>> bar(WidgetTester tester, KeyModifiers mods, {bool app = false}) async {
    final sent = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: KeyBar(onInput: sent.add, modifiers: mods, appCursorKeys: () => app),
        ),
      ),
    ));
    return sent;
  }

  Future<void> key(WidgetTester tester, String label) async {
    final f = find.bySemanticsLabel(label);
    await tester.ensureVisible(f);
    await tester.pumpAndSettle();
    await tester.tap(f);
    await tester.pump();
  }

  testWidgets('escTabArrows', (tester) async {
    final sent = await bar(tester, KeyModifiers());
    for (final k in [Fr.keyEsc, Fr.keyTab, Fr.keyUp, Fr.keyDown, Fr.keyRight, Fr.keyLeft]) {
      await key(tester, k);
    }
    expect(sent, ['\x1b', '\t', '\x1b[A', '\x1b[B', '\x1b[C', '\x1b[D']);

    final app = await bar(tester, KeyModifiers(), app: true);
    await key(tester, Fr.keyUp);
    await key(tester, Fr.keyLeft);
    expect(app, ['\x1bOA', '\x1bOD']); // mode curseur d'application (vim, less…)
  });

  testWidgets('homeEndPageKeys', (tester) async {
    final sent = await bar(tester, KeyModifiers());
    for (final k in [Fr.keyHome, Fr.keyEnd, Fr.keyPageUp, Fr.keyPageDown]) {
      await key(tester, k);
    }
    expect(sent, ['\x1b[H', '\x1b[F', '\x1b[5~', '\x1b[6~']);
  });

  testWidgets('symbolsRow', (tester) async {
    final sent = await bar(tester, KeyModifiers());
    for (final k in [Fr.keyTilde, Fr.keyPipe, Fr.keySlash, Fr.keyDash]) {
      await key(tester, k);
    }
    expect(sent, ['~', '|', '/', '-']);
  });

  test('ctrlOnceAppliesToNextKeyOnly', () {
    final m = KeyModifiers();
    m.tapCtrl();
    expect(m.ctrl, ModifierState.once);
    expect(m.apply('c'), '\x03');
    expect(m.ctrl, ModifierState.off);
    expect(m.apply('c'), 'c');
    m.tapCtrl();
    expect(m.apply('['), '\x1b');
    m.tapCtrl();
    expect(m.apply(' '), '\x00');
    m.tapCtrl();
    expect(m.apply('é'), 'é'); // sans équivalent : texte inchangé, Ctrl consommé
    expect(m.ctrl, ModifierState.off);
  });

  test('ctrlLocked', () {
    final m = KeyModifiers();
    m.tapCtrl();
    m.tapCtrl();
    expect(m.ctrl, ModifierState.locked);
    expect(m.apply('c'), '\x03');
    expect(m.apply('d'), '\x04');
    m.tapCtrl();
    expect(m.ctrl, ModifierState.off);
    expect(m.apply('c'), 'c');
  });

  test('altPrefixesEscape', () {
    final m = KeyModifiers();
    m.tapAlt();
    expect(m.apply('x'), '\x1bx');
    expect(m.apply('x'), 'x');
    m.tapAlt();
    m.tapCtrl();
    expect(m.apply('c'), '\x1b\x03'); // Ctrl+Alt+C
  });

  testWidgets('modifiedArrows', (tester) async {
    final mods = KeyModifiers();
    final sent = await bar(tester, mods);
    await key(tester, Fr.keyCtrl);
    await key(tester, Fr.keyRight);
    await key(tester, Fr.keyRight);
    expect(sent, ['\x1b[1;5C', '\x1b[C']); // Ctrl+→ (mot suivant), une fois seulement
  });

  testWidgets('targetsAre48dp', (tester) async {
    tester.view.physicalSize = const Size(2000, 800); // toute la barre construite d'un coup
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await bar(tester, KeyModifiers());
    final keys = find.descendant(of: find.byType(KeyBar), matching: find.byType(InkWell));
    expect(keys, findsNWidgets(16));
    for (final e in keys.evaluate()) {
      final size = (e.renderObject! as RenderBox).size;
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
    }
  });

  testWidgets('ctrlFromBarAppliesToKeyboard', (tester) async {
    final api = api0();
    final state = await pump(tester, api);
    final e = await state.terminals.open('s1');
    tester
        .state<NavigatorState>(find.byType(Navigator).first)
        .push(MaterialPageRoute<void>(builder: (_) => TerminalScreen(state: state, sessionId: e.info.id)));
    await tester.pumpAndSettle();
    expect(find.byType(KeyBar), findsOneWidget);
    await key(tester, Fr.keyCtrl);
    final t = tester.widget<TerminalView>(find.byType(TerminalView)).terminal;
    t.textInput('c'); // lettre du clavier du téléphone
    t.textInput('c');
    await tester.pump();
    expect(api.terminalWrites.map((w) => utf8.decode(w.$2)).toList(), ['\x03', 'c']);
  });
}

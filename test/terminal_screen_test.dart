import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluluks/src/bridge/fluluks_api.g.dart';
import 'package:fluluks/src/state/app_state.dart';
import 'package:fluluks/src/screens/settings_screen.dart';
import 'package:fluluks/src/strings_fr.dart';
import 'package:fluluks/src/terminal/terminal_screen.dart';
import 'package:fluluks/src/terminal/terminal_theme.dart';
import 'package:xterm/xterm.dart';

import 'fake_host_api.dart';
import 'remote_test.dart' show api0, pump;

/// Phase 13, T4 : écran Terminal (xterm) branché sur le hub des terminaux.
void main() {
  Uint8List bytes(String s) => Uint8List.fromList(utf8.encode(s));

  /// Ouvre un terminal sur « Maison » (s1) et pousse son écran ; rend l'identifiant de la session.
  Future<String> openScreen(WidgetTester tester, AppState state) async {
    final e = await state.terminals.open('s1');
    tester
        .state<NavigatorState>(find.byType(Navigator).first)
        .push(MaterialPageRoute<void>(builder: (_) => TerminalScreen(state: state, sessionId: e.info.id)));
    await tester.pumpAndSettle();
    return e.info.id;
  }

  /// Presse-papiers simulé : [text] rendu à la lecture ; ce qui est copié est rendu par la fonction.
  String? Function() clipboard(WidgetTester tester, String? text) {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      switch (call.method) {
        case 'Clipboard.getData':
          return text == null ? null : {'text': text};
        case 'Clipboard.hasStrings':
          return {'value': text != null};
        case 'Clipboard.setData':
          copied = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    return () => copied;
  }

  String written(FakeHostApi api, String id) =>
      utf8.decode([for (final w in api.terminalWrites.where((w) => w.$1 == id)) ...w.$2]);

  Future<void> menu(WidgetTester tester, String item) async {
    await tester.tap(find.byTooltip(Fr.moreOptions));
    await tester.pumpAndSettle();
    await tester.tap(find.text(item).last);
    await tester.pumpAndSettle();
  }

  testWidgets('outputAppearsInTerminal', (tester) async {
    final api = api0();
    final state = await pump(tester, api);
    final id = await openScreen(tester, state);
    state.onTerminalOutput(id, bytes('bonjour\r\n'));
    await tester.pump();
    final view = tester.widget<TerminalView>(find.byType(TerminalView));
    expect(view.terminal.buffer.lines[0].toString().trimRight(), 'bonjour');
    expect(find.bySemanticsLabel(Fr.terminalOf('Maison')), findsOneWidget);
  });

  testWidgets('typedBytesReachBridge', (tester) async {
    final api = api0();
    final state = await pump(tester, api);
    final id = await openScreen(tester, state);
    tester.widget<TerminalView>(find.byType(TerminalView)).terminal.textInput('é');
    await tester.pump();
    expect(api.terminalWrites.last.$1, id);
    expect(api.terminalWrites.last.$2, [0xc3, 0xa9]);
  });

  testWidgets('resizeFollowsView', (tester) async {
    final api = api0();
    final state = await pump(tester, api);
    final id = await openScreen(tester, state);
    expect(api.terminalResizes.where((r) => r.$1 == id), isNotEmpty);
    final portrait = api.terminalResizes.last;
    tester.view.physicalSize = const Size(2400, 1080); // rotation
    await tester.pumpAndSettle();
    final landscape = api.terminalResizes.last;
    expect(landscape.$2, greaterThan(portrait.$2));
    expect(landscape.$3, lessThan(portrait.$3));
  });

  testWidgets('multiLinePasteAsksFirst', (tester) async {
    final api = api0();
    final state = await pump(tester, api);
    final id = await openScreen(tester, state);
    clipboard(tester, 'ls\npwd\n');
    await menu(tester, Fr.terminalPaste);
    expect(find.text(Fr.pasteLines(2)), findsOneWidget);
    await tester.tap(find.text(Fr.cancel));
    await tester.pumpAndSettle();
    expect(written(api, id), isEmpty);
    await menu(tester, Fr.terminalPaste);
    await tester.tap(find.widgetWithText(FilledButton, Fr.terminalPaste));
    await tester.pumpAndSettle();
    expect(written(api, id), 'ls\rpwd\r'); // comme un terminal : retour chariot (Ctrl+J serait « justifier » dans nano)
  });

  testWidgets('singleLinePasteDirect', (tester) async {
    final api = api0();
    final state = await pump(tester, api);
    final id = await openScreen(tester, state);
    clipboard(tester, 'ls -la');
    await menu(tester, Fr.terminalPaste);
    expect(find.byType(AlertDialog), findsNothing);
    expect(written(api, id), 'ls -la');
  });

  testWidgets('pinchChangesFontSizeAndPersists', (tester) async {
    final api = api0();
    final state = await pump(tester, api);
    await openScreen(tester, state);
    double size() => tester.widget<TerminalView>(find.byType(TerminalView)).textStyle.fontSize;
    expect(size(), 13);
    final c = tester.getCenter(find.byType(TerminalView));
    Future<void> pinch(double from, double to) async {
      final a = await tester.startGesture(c - Offset(from, 0), pointer: 1);
      final b = await tester.startGesture(c + Offset(from, 0), pointer: 2);
      for (var i = 1; i <= 5; i++) {
        final d = from + (to - from) * i / 5;
        await a.moveTo(c - Offset(d, 0));
        await b.moveTo(c + Offset(d, 0));
        await tester.pump();
      }
      await a.up();
      await b.up();
      await tester.pumpAndSettle();
    }

    await pinch(40, 60); // ×1,5
    expect(size(), inInclusiveRange(18, 21));
    expect(api.uiPrefs.terminalFontSize, size().round());
    await pinch(20, 300);
    expect(size(), 32); // borne haute
    await pinch(200, 5); // doigts posés dans l'écran (432 dp de large)
    expect(size(), 8); // borne basse
    expect(api.uiPrefs.terminalFontSize, 8);
  });

  testWidgets('fontSizeFromMenu', (tester) async {
    final api = api0();
    final state = await pump(tester, api);
    await openScreen(tester, state);
    await menu(tester, Fr.terminalFontSize);
    expect(find.text(Fr.terminalFontValue(13)), findsOneWidget);
    await tester.drag(find.byType(Slider), const Offset(400, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text(Fr.ok));
    await tester.pumpAndSettle();
    expect(api.uiPrefs.terminalFontSize, 32);
    expect(tester.widget<TerminalView>(find.byType(TerminalView)).textStyle.fontSize, 32);
  });

  testWidgets('closedSessionOffersReconnect', (tester) async {
    final api = api0();
    final state = await pump(tester, api);
    final id = await openScreen(tester, state);
    expect(find.text(Fr.reconnect), findsNothing);
    state.onTerminalChanged(TerminalSessionMsg(
        id: id, serverId: 's1', title: 'Maison', state: 'closed', error: 'Connexion au serveur perdue', cols: 80, rows: 24));
    await tester.pumpAndSettle();
    expect(find.text('Connexion au serveur perdue'), findsOneWidget);
    await tester.tap(find.text(Fr.reconnect));
    await tester.pumpAndSettle();
    expect(api.calls.where((c) => c == 'openTerminal s1'), hasLength(2));
    expect(api.closedTerminals, [id]); // l'ancienne session est oubliée
    expect(find.text(Fr.reconnect), findsNothing);
    expect(state.terminals.sessions.single.info.id, isNot(id));
  });

  testWidgets('closeSessionConfirmed', (tester) async {
    final api = api0();
    final state = await pump(tester, api);
    final id = await openScreen(tester, state);
    await menu(tester, Fr.closeSession);
    expect(find.text(Fr.closeSessionAsk), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, Fr.closeSession));
    await tester.pumpAndSettle();
    expect(api.closedTerminals, [id]);
    expect(find.byType(TerminalScreen), findsNothing);
    expect(state.terminals.sessions, isEmpty);
  });

  testWidgets('ctrlCReachesDuringFlood', (tester) async {
    final api = api0();
    final state = await pump(tester, api);
    final id = await openScreen(tester, state);
    final line = bytes('${'y' * 79}\r\n' * 200);
    for (var i = 0; i < 40; i++) {
      state.onTerminalOutput(id, line);
      if (i % 10 == 0) await tester.pump();
    }
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(api.terminalWrites.where((w) => w.$1 == id).map((w) => w.$2.join(',')), contains('3'));
    final t = state.terminals.terminalOf(id);
    expect(t.buffer.lines.length, lessThanOrEqualTo(10000 + t.viewHeight)); // historique borné
  });

  testWidgets('themeFollowsBrightness', (tester) async {
    expect(terminalTheme(ColorScheme.fromSeed(seedColor: Colors.orange)).background,
        ColorScheme.fromSeed(seedColor: Colors.orange).surface);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    final api = api0();
    final state = await pump(tester, api);
    await openScreen(tester, state);
    expect(tester.widget<TerminalView>(find.byType(TerminalView)).theme.background, terminalDarkBackground);
  });

  testWidgets('titleFromOsc', (tester) async {
    final api = api0();
    final state = await pump(tester, api);
    final id = await openScreen(tester, state);
    expect(find.descendant(of: find.byType(AppBar), matching: find.text('Maison')), findsOneWidget);
    state.onTerminalOutput(id, bytes('\x1b]2;charles@cloud: ~\x07'));
    await tester.pump();
    expect(find.descendant(of: find.byType(AppBar), matching: find.text('charles@cloud: ~')), findsOneWidget);
  });

  testWidgets('secureScreenFollowsSetting', (tester) async {
    final api = api0()..uiPrefs = UiPrefsMsg(theme: 'system', haptics: true, welcomeSeen: true, terminalSecure: true);
    final state = await pump(tester, api);
    await openScreen(tester, state);
    expect(api.secureScreen, isTrue);
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await tester.pumpAndSettle();
    expect(api.secureScreen, isFalse);
  });

  testWidgets('selectionCopies', (tester) async {
    final api = api0();
    final state = await pump(tester, api);
    final id = await openScreen(tester, state);
    state.onTerminalOutput(id, bytes('motcopie suite\r\n'));
    await tester.pump();
    final copied = clipboard(tester, null);
    final topLeft = tester.getTopLeft(find.byType(TerminalView));
    await tester.longPressAt(topLeft + const Offset(20, 8));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(Fr.copy));
    await tester.pumpAndSettle();
    expect(copied(), 'motcopie');
    expect(find.text(Fr.terminalCopied), findsOneWidget);
  });

  testWidgets('settingHidesTerminal', (tester) async {
    final api = api0();
    final state = await pump(tester, api);
    tester
        .state<NavigatorState>(find.byType(Navigator).first)
        .push(MaterialPageRoute<void>(builder: (_) => SettingsScreen(state: state)));
    await tester.pumpAndSettle();
    final tile = find.widgetWithText(SwitchListTile, Fr.terminalSecure);
    await tester.scrollUntilVisible(tile, 200);
    await tester.ensureVisible(tile);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(tile).value, isFalse); // désactivé par défaut
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(api.uiPrefs.terminalSecure, isTrue);
    expect(api.uiPrefs.haptics, isTrue); // les autres préférences restent
  });
}

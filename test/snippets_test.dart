import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluluks/src/bridge/fluluks_api.g.dart';
import 'package:fluluks/src/state/app_state.dart';
import 'package:fluluks/src/strings_fr.dart';
import 'package:fluluks/src/terminal/snippets_sheet.dart';
import 'package:fluluks/src/terminal/terminal_screen.dart';
import 'package:xterm/xterm.dart';

import 'fake_host_api.dart';
import 'remote_test.dart' show api0, pump;

/// Phase 13, T9 : commandes enregistrées, depuis le menu du terminal.
void main() {
  SnippetMsg snip(String name, String command, {String? serverId, bool runNow = true}) =>
      SnippetMsg(id: name, serverId: serverId, name: name, command: command, runNow: runNow);

  Future<String> openTerminal(WidgetTester tester, AppState state) async {
    final e = await state.terminals.open('s1');
    tester
        .state<NavigatorState>(find.byType(Navigator).first)
        .push(MaterialPageRoute<void>(builder: (_) => TerminalScreen(state: state, sessionId: e.info.id)));
    await tester.pumpAndSettle();
    return e.info.id;
  }

  Future<void> openSheet(WidgetTester tester) async {
    await tester.tap(find.byTooltip(Fr.moreOptions));
    await tester.pumpAndSettle();
    await tester.tap(find.text(Fr.snippets));
    await tester.pumpAndSettle();
  }

  String written(FakeHostApi api, String id) =>
      utf8.decode([for (final w in api.terminalWrites.where((w) => w.$1 == id)) ...w.$2]);

  testWidgets('serverThenCommonOrder', (tester) async {
    final api = api0()
      ..snippetList.addAll([
        snip('Disque', 'df -h'),
        snip('Journal', 'journalctl -f', serverId: 's1'),
        snip('Docker', 'docker ps', serverId: 's2'),
      ]);
    final state = await pump(tester, api);
    await openTerminal(tester, state);
    await openSheet(tester);
    final names = tester
        .widgetList<ListTile>(find.descendant(of: find.byType(SnippetsSheet), matching: find.byType(ListTile)))
        .map((t) => (t.title as Text).data)
        .toList();
    expect(names, ['Journal', 'Disque']);
  });

  testWidgets('runNowAppendsEnter', (tester) async {
    final api = api0()..snippetList.add(snip('Disque', 'df -h'));
    final state = await pump(tester, api);
    final id = await openTerminal(tester, state);
    await openSheet(tester);
    await tester.tap(find.text('Disque'));
    await tester.pumpAndSettle();
    expect(written(api, id), 'df -h\r');
    expect(find.byType(SnippetsSheet), findsNothing);
  });

  testWidgets('withoutRunNowOnlyTypes', (tester) async {
    final api = api0()..snippetList.add(snip('Mises à jour', 'sudo apt update', runNow: false));
    final state = await pump(tester, api);
    final id = await openTerminal(tester, state);
    await openSheet(tester);
    await tester.tap(find.text('Mises à jour'));
    await tester.pumpAndSettle();
    expect(written(api, id), 'sudo apt update');
  });

  testWidgets('multiLineSnippetConfirmed', (tester) async {
    final api = api0()..snippetList.add(snip('Aller', 'cd /srv\nls'));
    final state = await pump(tester, api);
    final id = await openTerminal(tester, state);
    await openSheet(tester);
    await tester.tap(find.text('Aller'));
    await tester.pumpAndSettle();
    expect(find.text(Fr.pasteLines(2)), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, Fr.snippetRun));
    await tester.pumpAndSettle();
    expect(written(api, id), 'cd /srv\rls\r');
  });

  testWidgets('addFromSheet', (tester) async {
    final api = api0();
    final state = await pump(tester, api);
    await openTerminal(tester, state);
    await openSheet(tester);
    expect(find.text(Fr.noSnippets), findsOneWidget);
    await tester.tap(find.text(Fr.addSnippet));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, Fr.snippetName), 'Disque');
    await tester.enterText(find.widgetWithText(TextField, Fr.snippetCommand), 'df -h');
    await tester.tap(find.text(Fr.snippetThisServer('Maison')));
    await tester.tap(find.text(Fr.save));
    await tester.pumpAndSettle();
    expect(api.snippetList.single.serverId, 's1');
    expect(api.snippetList.single.runNow, isTrue);
    expect(find.descendant(of: find.byType(SnippetsSheet), matching: find.text('Disque')), findsOneWidget);
  });

  testWidgets('longPressEditsAndDeletes', (tester) async {
    final api = api0()..snippetList.add(snip('Disque', 'df -h'));
    final state = await pump(tester, api);
    await openTerminal(tester, state);
    await openSheet(tester);
    await tester.longPress(find.text('Disque'));
    await tester.pumpAndSettle();
    expect(find.text(Fr.editSnippet), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, Fr.snippetCommand), 'df -hT');
    await tester.tap(find.text(Fr.save));
    await tester.pumpAndSettle();
    expect(api.snippetList.single.command, 'df -hT');
    await tester.longPress(find.text('Disque'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(Fr.delete));
    await tester.pumpAndSettle();
    expect(api.snippetList, isEmpty);
  });

  testWidgets('saveSelectionAsSnippet', (tester) async {
    final api = api0();
    final state = await pump(tester, api);
    final id = await openTerminal(tester, state);
    state.onTerminalOutput(id, utf8.encode('uptime\r\n'));
    await tester.pump();
    await tester.longPressAt(tester.getTopLeft(find.byType(TerminalView)) + const Offset(20, 8));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(Fr.saveAsSnippet));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.widgetWithText(TextField, Fr.snippetCommand)).controller!.text, 'uptime');
  });
}

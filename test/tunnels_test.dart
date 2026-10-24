import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluluks/src/bridge/fluluks_api.g.dart';
import 'package:fluluks/src/state/app_state.dart';
import 'package:fluluks/src/strings_fr.dart';
import 'package:fluluks/src/terminal/terminal_screen.dart';
import 'package:fluluks/src/terminal/tunnels_screen.dart';

import 'remote_test.dart' show api0, formScroll, pump, showServer;

/// Phase 13, T10 : écran « Tunnels » (redirection de port locale), depuis le terminal et la fiche du serveur.
void main() {
  TunnelMsg tun({String id = 'u1', bool auto = false, bool active = false}) => TunnelMsg(
      id: id, serverId: 's1', localPort: 8080, remoteHost: 'localhost', remotePort: 80, auto: auto, active: active);

  Future<void> openTunnels(WidgetTester tester, AppState state, {String? sessionId}) async {
    tester.state<NavigatorState>(find.byType(Navigator).first).push(MaterialPageRoute<void>(
        builder: (_) => TunnelsScreen(state: state, serverId: 's1', sessionId: sessionId)));
    await tester.pumpAndSettle();
  }

  Future<String> session(AppState state) async => (await state.terminals.open('s1')).info.id;

  testWidgets('listToggleAndOpenInBrowser', (tester) async {
    final api = api0()..tunnelList.add(tun());
    final state = await pump(tester, api);
    final id = await session(state);
    await openTunnels(tester, state, sessionId: id);
    expect(find.text(Fr.tunnelLine(8080, 'localhost', 80)), findsOneWidget);
    expect(find.text(Fr.openInBrowser), findsNothing);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(api.calls, contains('startTunnel $id u1'));
    await tester.tap(find.text(Fr.openInBrowser));
    await tester.pumpAndSettle();
    expect(api.openedUrls, ['http://127.0.0.1:8080']);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(api.calls, contains('stopTunnel $id u1'));
    expect(find.text(Fr.openInBrowser), findsNothing);
  });

  testWidgets('addValidatesPorts', (tester) async {
    final api = api0();
    final state = await pump(tester, api);
    await openTunnels(tester, state);
    expect(find.text(Fr.noTunnels), findsOneWidget);
    await tester.tap(find.text(Fr.addTunnel));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.widgetWithText(TextField, Fr.tunnelRemoteHost)).controller!.text, 'localhost');
    await tester.enterText(find.widgetWithText(TextField, Fr.tunnelLocalPort), '80');
    await tester.enterText(find.widgetWithText(TextField, Fr.tunnelRemotePort), '80');
    await tester.tap(find.text(Fr.save));
    await tester.pumpAndSettle();
    expect(find.text(Fr.tunnelLocalPortRange), findsOneWidget);
    expect(api.tunnelList, isEmpty);
    await tester.enterText(find.widgetWithText(TextField, Fr.tunnelLocalPort), '8080');
    await tester.tap(find.text(Fr.tunnelAuto));
    await tester.tap(find.text(Fr.save));
    await tester.pumpAndSettle();
    expect(api.tunnelList.single.localPort, 8080);
    expect(api.tunnelList.single.auto, isTrue);
    expect(find.text(Fr.tunnelLine(8080, 'localhost', 80)), findsOneWidget);
  });

  testWidgets('startErrorShown', (tester) async {
    final api = api0()
      ..tunnelList.add(tun())
      ..startTunnelHook = ((s, t) => throw PlatformException(code: '5', message: 'Le port 8080 est déjà utilisé sur ce téléphone'));
    final state = await pump(tester, api);
    await openTunnels(tester, state, sessionId: await session(state));
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(find.text('Le port 8080 est déjà utilisé sur ce téléphone'), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
  });

  testWidgets('withoutTerminalNoSwitch', (tester) async {
    final api = api0()..tunnelList.add(tun(auto: true));
    final state = await pump(tester, api);
    await openTunnels(tester, state);
    expect(find.text(Fr.tunnelsNeedTerminal), findsOneWidget);
    expect(find.byType(Switch), findsNothing);
    expect(find.text(Fr.tunnelAutoOn), findsOneWidget);
  });

  testWidgets('deleteTunnelConfirmed', (tester) async {
    final api = api0()..tunnelList.add(tun());
    final state = await pump(tester, api);
    await openTunnels(tester, state);
    await tester.tap(find.byTooltip(Fr.tunnelOptions));
    await tester.pumpAndSettle();
    await tester.tap(find.text(Fr.delete));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, Fr.delete));
    await tester.pumpAndSettle();
    expect(api.tunnelList, isEmpty);
  });

  testWidgets('fromTerminalMenu', (tester) async {
    final api = api0();
    final state = await pump(tester, api);
    final id = await session(state);
    tester
        .state<NavigatorState>(find.byType(Navigator).first)
        .push(MaterialPageRoute<void>(builder: (_) => TerminalScreen(state: state, sessionId: id)));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(Fr.moreOptions));
    await tester.pumpAndSettle();
    await tester.tap(find.text(Fr.tunnels));
    await tester.pumpAndSettle();
    expect(tester.widget<TunnelsScreen>(find.byType(TunnelsScreen)).sessionId, id);
  });

  testWidgets('fromServerForm', (tester) async {
    final api = api0();
    await pump(tester, api);
    await showServer(tester);
    await tester.tap(find.byTooltip('Modifier'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text(Fr.tunnels), 200, scrollable: formScroll);
    await tester.ensureVisible(find.text(Fr.tunnels));
    await tester.pumpAndSettle();
    await tester.tap(find.text(Fr.tunnels));
    await tester.pumpAndSettle();
    expect(find.byType(TunnelsScreen), findsOneWidget);
  });
}

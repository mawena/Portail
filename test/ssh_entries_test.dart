import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluluks/src/bridge/fluluks_api.g.dart';
import 'package:fluluks/src/screens/explorer_screen.dart';
import 'package:fluluks/src/state/app_state.dart';
import 'package:fluluks/src/strings_fr.dart';
import 'package:fluluks/src/terminal/terminal_screen.dart';
import 'package:fluluks/src/widgets/ssh_sessions_card.dart';

import 'remote_test.dart' show api0, pump, remoteSrc, server, showServer;

/// Phase 13, T6 : entrées vers le terminal (tuile, accueil, explorateur) et sessions multiples.
void main() {
  Future<void> tapTerminal(WidgetTester tester) async {
    await showServer(tester);
    await tester.tap(find.byTooltip(Fr.terminal));
    await tester.pumpAndSettle();
  }

  String appTitle(WidgetTester tester) => tester
      .widget<Text>(find.descendant(of: find.byType(AppBar), matching: find.byType(Text)).first)
      .data!;

  testWidgets('tileOffersTerminalForSftpOnly', (tester) async {
    await pump(tester, api0());
    await showServer(tester);
    expect(find.byTooltip(Fr.terminal), findsOneWidget);
    expect(find.text('SFTP · SSH · charles@192.168.0.10:22'), findsOneWidget);
    await tapTerminal(tester);
    expect(find.byType(TerminalScreen), findsOneWidget);
  });

  testWidgets('ftpTileHasNoTerminal', (tester) async {
    await pump(tester, api0(s: server(protocol: 'ftp')));
    await showServer(tester);
    expect(find.byTooltip(Fr.terminal), findsNothing);
    expect(find.text('FTP · charles@192.168.0.10:21'), findsOneWidget);
  });

  testWidgets('homeShowsSessionsWhileOpen', (tester) async {
    final api = api0();
    final state = await pump(tester, api);
    expect(find.text(Fr.sshSessions), findsNothing);
    await state.terminals.open('s1');
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byType(SshSessionsCard), 200);
    expect(find.text(Fr.sshSessions), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(SshSessionsCard), matching: find.text('Maison')));
    await tester.pumpAndSettle();
    expect(find.byType(TerminalScreen), findsOneWidget);
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(SshSessionsCard), matching: find.byTooltip(Fr.closeSession)));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, Fr.closeSession));
    await tester.pumpAndSettle();
    expect(api.closedTerminals, hasLength(1));
    expect(find.byType(SshSessionsCard), findsNothing);
  });

  testWidgets('openHereStartsInFolder', (tester) async {
    final api = api0()..sources = [remoteSrc()];
    final state = await pump(tester, api);
    tester.state<NavigatorState>(find.byType(Navigator).first).push(MaterialPageRoute<void>(
        builder: (_) => ExplorerScreen(state: state, sourceId: 'remote:s1', path: '/home/charles')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(Fr.sortBy));
    await tester.pumpAndSettle();
    await tester.tap(find.text(Fr.openTerminalHere));
    await tester.pumpAndSettle();
    expect(api.calls, contains('openTerminal s1 /home/charles'));
    expect(find.byType(TerminalScreen), findsOneWidget);
  });

  testWidgets('openHereOnlyForSftp', (tester) async {
    final api = api0(s: server(protocol: 'ftp'))..sources = [remoteSrc()];
    final state = await pump(tester, api);
    tester.state<NavigatorState>(find.byType(Navigator).first).push(MaterialPageRoute<void>(
        builder: (_) => ExplorerScreen(state: state, sourceId: 'remote:s1', path: '/home/charles')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(Fr.sortBy));
    await tester.pumpAndSettle();
    expect(find.text(Fr.openTerminalHere), findsNothing);
  });

  testWidgets('switchBetweenSessions', (tester) async {
    final api = api0();
    final state = await pump(tester, api);
    await state.terminals.open('s1');
    await tapTerminal(tester); // deuxième session sur le même serveur
    expect(appTitle(tester), 'Maison (2)');
    await tester.tap(find.byTooltip(Fr.sshSessions));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Maison').last);
    await tester.pumpAndSettle();
    expect(appTitle(tester), 'Maison');
    expect(find.byType(TerminalScreen), findsOneWidget); // le même écran, une autre session
  });

  testWidgets('reconnectReusesServer', (tester) async {
    final api = api0();
    final state = await pump(tester, api);
    await tapTerminal(tester);
    final first = state.terminals.sessions.single.info.id;
    // le serveur demande désormais le mot de passe (non mémorisé)
    api.openTerminalHook = (id, pw, dir) {
      if (pw == null) throw PlatformException(code: 'auth', message: 'Mot de passe requis', details: true);
      return TerminalSessionMsg(id: 'tz', serverId: id, title: 'Maison', state: 'open', cols: 80, rows: 24);
    };
    state.onTerminalChanged(TerminalSessionMsg(
        id: first, serverId: 's1', title: 'Maison', state: 'closed', error: 'Connexion au serveur perdue', cols: 80, rows: 24));
    await tester.pumpAndSettle();
    await tester.tap(find.text(Fr.reconnect));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'secret');
    await tester.tap(find.text(Fr.connect));
    await tester.pumpAndSettle();
    expect(state.terminals.sessions.map((s) => s.info.id), ['tz']);
    expect(api.closedTerminals, [first]);
    expect(find.text(Fr.reconnect), findsNothing);
  });

  testWidgets('unknownKeyAskedBeforeTerminal', (tester) async {
    var trusted = false;
    final api = api0()..onTrust = (id, fp) => trusted = true;
    api.openTerminalHook = (id, pw, dir) {
      if (!trusted) throw PlatformException(code: 'hostkey-unknown', message: 'Clé inconnue', details: 'ssh-ed25519 SHA256:abc');
      return TerminalSessionMsg(id: 'tk', serverId: id, title: 'Maison', state: 'open', cols: 80, rows: 24);
    };
    await pump(tester, api);
    await tapTerminal(tester);
    expect(find.byType(TerminalScreen), findsNothing);
    expect(find.textContaining('ssh-ed25519 SHA256:abc'), findsOneWidget);
    await tester.tap(find.text('Faire confiance'));
    await tester.pumpAndSettle();
    expect(find.byType(TerminalScreen), findsOneWidget);
  });

  testWidgets('passwordAskedWhenNotRemembered', (tester) async {
    final passwords = <String?>[];
    final api = api0();
    api.openTerminalHook = (id, pw, dir) {
      passwords.add(pw == null ? null : utf8.decode(pw));
      if (pw == null) throw PlatformException(code: 'auth', message: 'Mot de passe requis', details: true);
      return TerminalSessionMsg(id: 'tp', serverId: id, title: 'Maison', state: 'open', cols: 80, rows: 24);
    };
    await pump(tester, api);
    await tapTerminal(tester);
    expect(find.text(Fr.passwordFor('Maison')), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'secret');
    await tester.tap(find.text(Fr.connect));
    await tester.pumpAndSettle();
    expect(passwords, [null, 'secret']);
    expect(find.byType(TerminalScreen), findsOneWidget);
  });

  testWidgets('tooManySessionsExplained', (tester) async {
    final api = api0()
      ..openTerminalHook = ((id, pw, dir) => throw PlatformException(code: 'FL_EBUSY', message: '8 sessions au plus'));
    await pump(tester, api);
    await tapTerminal(tester);
    expect(find.text('8 sessions au plus'), findsOneWidget);
    expect(find.byType(TerminalScreen), findsNothing);
  });

  // Comme sur le téléphone : Kotlin annonce la session (« connecting ») avant de répondre ; l'accueil se redessine avec
  // la carte des sessions pendant la connexion, au-dessus de la tuile qui a lancé l'ouverture.
  TerminalSessionMsg msg(String id, String state) =>
      TerminalSessionMsg(id: id, serverId: 's1', title: 'Maison', state: state, cols: 80, rows: 24);

  testWidgets('terminalShownWhenAnnouncedWhileConnecting', (tester) async {
    final api = api0();
    late final AppState state;
    final reply = Completer<void>();
    api.openTerminalHook = (id, pw, dir) async {
      state.onTerminalChanged(msg('tc', 'connecting'));
      await reply.future;
      state.onTerminalChanged(msg('tc', 'open'));
      return msg('tc', 'open');
    };
    state = await pump(tester, api);
    await showServer(tester);
    await tester.tap(find.byTooltip(Fr.terminal));
    await tester.pump();
    await tester.pump(); // accueil redessiné pendant la connexion
    reply.complete();
    await tester.pumpAndSettle();
    expect(find.byType(TerminalScreen), findsOneWidget);
  });

  testWidgets('passwordAskedAfterAnnouncedAttempt', (tester) async {
    final api = api0();
    late final AppState state;
    final failed = Completer<void>();
    api.openTerminalHook = (id, pw, dir) async {
      if (pw != null) return msg('tb', 'open');
      state.onTerminalChanged(msg('ta', 'connecting'));
      await failed.future;
      state.onTerminalChanged(msg('ta', 'gone'));
      throw PlatformException(code: 'auth', message: 'Mot de passe requis', details: true);
    };
    state = await pump(tester, api);
    await showServer(tester);
    await tester.tap(find.byTooltip(Fr.terminal));
    await tester.pump();
    await tester.pump(); // carte des sessions affichée pendant la tentative
    failed.complete();
    await tester.pumpAndSettle();
    expect(find.text(Fr.passwordFor('Maison')), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'secret');
    await tester.tap(find.text(Fr.connect));
    await tester.pumpAndSettle();
    expect(find.byType(TerminalScreen), findsOneWidget);
  });

  testWidgets('sameShellTitleSessionsStayDistinct', (tester) async {
    final api = api0();
    final state = await pump(tester, api);
    await state.terminals.open('s1');
    await state.terminals.open('s1');
    for (final e in state.terminals.sessions) {
      state.terminals.onOutput(e.info.id, Uint8List.fromList(utf8.encode('\x1b]0;charles@maison: ~\x07')));
    }
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byType(SshSessionsCard), 200);
    final card = find.byType(SshSessionsCard);
    expect(find.descendant(of: card, matching: find.text('Maison')), findsOneWidget);
    expect(find.descendant(of: card, matching: find.text('Maison (2)')), findsOneWidget);
    expect(find.descendant(of: card, matching: find.text('${Fr.sessionOpen} · charles@maison: ~')), findsNWidgets(2));
    await tester.tap(find.descendant(of: card, matching: find.text('Maison (2)')));
    await tester.pumpAndSettle();
    expect(appTitle(tester), 'Maison (2)');
    expect(find.text('charles@maison: ~'), findsOneWidget); // sous le titre
  });
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluluks/src/screens/explorer_screen.dart';
import 'package:fluluks/src/strings_fr.dart';
import 'package:fluluks/src/widgets/connection_details_sheet.dart';

import 'remote_test.dart' show api0, formScroll, pump, showServer;

/// Phase 13, T1 : « Tester la connexion » dans la fiche d'un serveur, messages d'échec précis et leurs détails.
void main() {
  Future<void> openForm(WidgetTester tester) async {
    await showServer(tester);
    await tester.tap(find.byTooltip('Modifier'));
    await tester.pumpAndSettle();
  }

  Future<void> tapTest(WidgetTester tester) async {
    await tester.scrollUntilVisible(find.text(Fr.testConnection), 200, scrollable: formScroll);
    await tester.ensureVisible(find.text(Fr.testConnection));
    await tester.pumpAndSettle();
    await tester.tap(find.text(Fr.testConnection));
    await tester.pumpAndSettle();
  }

  testWidgets('testButtonShowsResult', (tester) async {
    final api = api0();
    await pump(tester, api);
    await openForm(tester);
    await tapTest(tester);
    expect(api.calls, contains('testServer s1'));
    expect(find.text(Fr.connectionOk), findsOneWidget);
    expect(find.byType(ExplorerScreen), findsNothing); // un test n'ouvre pas le dossier
  });

  testWidgets('testFailureOffersDetails', (tester) async {
    final api = api0()
      ..test = ((id, pw) => throw PlatformException(
          code: 'ssh', message: 'Le serveur a fermé la connexion', details: 'JSchException : connection is closed'))
      ..attemptLog = ['10:00:00.000  Connexion à 192.168.0.10, port 22', '10:00:00.100  Échec : fermé'];
    await pump(tester, api);
    await openForm(tester);
    await tapTest(tester);
    expect(find.text('Le serveur a fermé la connexion'), findsOneWidget);
    await tester.tap(find.widgetWithText(SnackBarAction, Fr.details));
    await tester.pumpAndSettle();
    expect(find.byType(ConnectionDetailsSheet), findsOneWidget);
    expect(find.textContaining('Échec : fermé'), findsOneWidget);
    expect(find.textContaining('JSchException : connection is closed'), findsOneWidget);
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.tap(find.text(Fr.copy));
    await tester.pumpAndSettle();
    expect(copied, contains('Connexion à 192.168.0.10'));
  });

  testWidgets('testUnknownKeyAsksTrustThenRetests', (tester) async {
    var trusted = false;
    final api = api0()
      ..test = (id, pw) {
        if (!trusted) {
          throw PlatformException(code: 'hostkey-unknown', message: 'Clé inconnue', details: 'ssh-ed25519 SHA256:abc');
        }
        return ['Connecté'];
      }
      ..onTrust = (id, fp) => trusted = true;
    await pump(tester, api);
    await openForm(tester);
    await tapTest(tester);
    expect(find.textContaining('ssh-ed25519 SHA256:abc'), findsOneWidget);
    await tester.tap(find.text('Faire confiance'));
    await tester.pumpAndSettle();
    expect(api.calls.where((c) => c == 'testServer s1').length, 2);
    expect(find.text(Fr.connectionOk), findsOneWidget);
  });

  testWidgets('connectFailureOffersDetails', (tester) async {
    final api = api0()
      ..connect = ((id, pw) => throw PlatformException(code: 'ssh', message: 'Connexion refusée', details: 'refused'))
      ..attemptLog = ['10:00:00.000  Échec : refusée'];
    await pump(tester, api);
    await showServer(tester);
    await tester.tap(find.text('Maison'));
    await tester.pumpAndSettle();
    expect(find.text('Connexion refusée'), findsOneWidget);
    await tester.tap(find.widgetWithText(SnackBarAction, Fr.details));
    await tester.pumpAndSettle();
    expect(find.textContaining('Échec : refusée'), findsOneWidget);
  });

  testWidgets('testOnlyForSavedServer', (tester) async {
    final api = api0();
    await pump(tester, api);
    await tester.scrollUntilVisible(find.text(Fr.addServer), 200);
    await tester.tap(find.text(Fr.addServer));
    await tester.pumpAndSettle();
    expect(find.text(Fr.testConnection), findsNothing);
  });
}

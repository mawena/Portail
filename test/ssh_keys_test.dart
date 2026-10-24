import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluluks/src/bridge/fluluks_api.g.dart';
import 'package:fluluks/src/screens/settings_screen.dart';
import 'package:fluluks/src/screens/ssh_keys_screen.dart';
import 'package:fluluks/src/state/app_state.dart';
import 'package:fluluks/src/strings_fr.dart';

import 'fake_host_api.dart';
import 'remote_test.dart' show api0, formScroll, pump, showServer;

/// Phase 13, T7 : écran « Clés SSH » (trousseau) et choix d'une clé pour un serveur.
void main() {
  SshKeyMsg key({String id = 'k1', String name = 'Téléphone', List<String> usedBy = const []}) => SshKeyMsg(
      id: id, name: name, type: 'ssh-ed25519', fingerprint: 'SHA256:abc', encrypted: false, usedBy: usedBy);

  Future<AppState> openKeys(WidgetTester tester, FakeHostApi api) async {
    final state = await pump(tester, api);
    tester
        .state<NavigatorState>(find.byType(Navigator).first)
        .push(MaterialPageRoute<void>(builder: (_) => SshKeysScreen(state: state)));
    await tester.pumpAndSettle();
    return state;
  }

  Future<void> keyMenu(WidgetTester tester, String item) async {
    await tester.tap(find.byTooltip(Fr.keyOptions('Téléphone')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(item));
    await tester.pumpAndSettle();
  }

  String? Function() clipboard(WidgetTester tester) {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    return () => copied;
  }

  testWidgets('settingsOpensKeys', (tester) async {
    final state = await pump(tester, api0());
    tester
        .state<NavigatorState>(find.byType(Navigator).first)
        .push(MaterialPageRoute<void>(builder: (_) => SettingsScreen(state: state)));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text(Fr.sshKeys), 200);
    await tester.ensureVisible(find.text(Fr.sshKeys));
    await tester.pumpAndSettle();
    await tester.tap(find.text(Fr.sshKeys));
    await tester.pumpAndSettle();
    expect(find.byType(SshKeysScreen), findsOneWidget);
    expect(find.text(Fr.noKeysTitle), findsOneWidget);
  });

  testWidgets('generateFlow', (tester) async {
    final api = api0();
    await openKeys(tester, api);
    await tester.tap(find.text(Fr.generateKey));
    await tester.pumpAndSettle();
    expect(find.text(Fr.generateKeyTitle), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, Fr.keyName), 'Téléphone');
    await tester.tap(find.text(Fr.keyTypeRsa));
    await tester.enterText(find.widgetWithText(TextField, Fr.keyPassphraseOptional), 'abc');
    await tester.enterText(find.widgetWithText(TextField, Fr.keyPassphraseConfirm), 'abd');
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.widgetWithText(FilledButton, Fr.generateKey)));
    await tester.pumpAndSettle();
    expect(find.text(Fr.passMismatch), findsOneWidget); // phrases différentes : rien de généré
    expect(api.generatedKeys, isEmpty);
    await tester.enterText(find.widgetWithText(TextField, Fr.keyPassphraseConfirm), 'abc');
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.widgetWithText(FilledButton, Fr.generateKey)));
    await tester.pumpAndSettle();
    expect(api.generatedKeys, [('Téléphone', 'rsa', 'abc')]);
    expect(find.text('Téléphone'), findsOneWidget);
    expect(find.textContaining('ssh-rsa'), findsOneWidget);
    expect(find.text(Fr.keyEncrypted), findsOneWidget);
  });

  testWidgets('importFlow', (tester) async {
    final api = api0();
    await openKeys(tester, api);
    await tester.tap(find.text(Fr.importKeyShort));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Portable');
    await tester.tap(find.text(Fr.ok));
    await tester.pumpAndSettle();
    expect(api.calls, contains('importSshKey Portable'));
    expect(find.text('Portable'), findsOneWidget);
  });

  testWidgets('copyPublicKey', (tester) async {
    final api = api0()..sshKeyList.add(key());
    await openKeys(tester, api);
    final copied = clipboard(tester);
    await keyMenu(tester, Fr.copyPublicKey);
    expect(copied(), 'ssh-ed25519 AAAAC3Nza portail@test');
    expect(find.text(Fr.publicKeyCopied), findsOneWidget);
  });

  testWidgets('sharePublicKey', (tester) async {
    final api = api0()..sshKeyList.add(key());
    await openKeys(tester, api);
    await keyMenu(tester, Fr.sharePublicKey);
    expect(api.sharedTexts, ['ssh-ed25519 AAAAC3Nza portail@test']);
  });

  testWidgets('renameKey', (tester) async {
    final api = api0()..sshKeyList.add(key());
    await openKeys(tester, api);
    await keyMenu(tester, Fr.rename);
    await tester.enterText(find.byType(TextField), 'Pixel');
    await tester.tap(find.text(Fr.ok));
    await tester.pumpAndSettle();
    expect(find.text('Pixel'), findsOneWidget);
  });

  testWidgets('deleteAsksConfirmation', (tester) async {
    final api = api0()..sshKeyList.add(key());
    await openKeys(tester, api);
    await keyMenu(tester, Fr.delete);
    expect(find.text(Fr.deleteKeyAsk('Téléphone')), findsOneWidget);
    await tester.tap(find.text(Fr.cancel));
    await tester.pumpAndSettle();
    expect(api.sshKeyList, hasLength(1));
    await keyMenu(tester, Fr.delete);
    await tester.tap(find.widgetWithText(FilledButton, Fr.delete));
    await tester.pumpAndSettle();
    expect(api.sshKeyList, isEmpty);
    expect(find.text(Fr.noKeysTitle), findsOneWidget);
  });

  testWidgets('usedKeyShowsServersAndRefusal', (tester) async {
    final api = api0()..sshKeyList.add(key(usedBy: ['Maison']));
    await openKeys(tester, api);
    expect(find.textContaining(Fr.keyUsedBy(['Maison'])), findsOneWidget);
    await keyMenu(tester, Fr.delete);
    await tester.tap(find.widgetWithText(FilledButton, Fr.delete));
    await tester.pumpAndSettle();
    expect(find.text('Clé utilisée par : Maison'), findsOneWidget);
    expect(api.sshKeyList, hasLength(1));
  });

  testWidgets('chooseKeyForServer', (tester) async {
    final api = api0()..sshKeyList.add(key());
    await pump(tester, api);
    await showServer(tester);
    await tester.tap(find.byTooltip('Modifier'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text(Fr.chooseKey), 200, scrollable: formScroll);
    await tester.ensureVisible(find.text(Fr.chooseKey));
    await tester.pumpAndSettle();
    await tester.tap(find.text(Fr.chooseKey));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Téléphone'));
    await tester.pumpAndSettle();
    expect(api.calls, contains('setServerKey s1 k1'));
    expect(find.text('ssh-ed25519 SHA256:abc'), findsOneWidget);
  });

  testWidgets('installFromKeysScreen', (tester) async {
    final api = api0()..sshKeyList.add(key());
    await openKeys(tester, api);
    await keyMenu(tester, Fr.installKey);
    await tester.tap(find.text('Maison'));
    await tester.pumpAndSettle();
    expect(api.calls, contains('installPublicKey s1 k1'));
    expect(find.text('Clé installée sur Maison'), findsOneWidget);
    // proposition : utiliser cette clé pour ce serveur
    expect(find.text(Fr.useKeyFor('Maison')), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, Fr.useKey));
    await tester.pumpAndSettle();
    expect(api.calls, contains('setServerKey s1 k1'));
  });

  testWidgets('installAsksPassword', (tester) async {
    final api = api0()..sshKeyList.add(key());
    api.installHook = (id, k, pw) {
      if (pw == null) throw PlatformException(code: 'auth', message: 'Mot de passe requis', details: true);
      return 'Clé déjà installée sur Maison';
    };
    await openKeys(tester, api);
    await keyMenu(tester, Fr.installKey);
    await tester.tap(find.text('Maison'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'mdp');
    await tester.tap(find.text(Fr.connect));
    await tester.pumpAndSettle();
    expect(api.installPasswords, [null, 'mdp']);
    expect(find.text('Clé déjà installée sur Maison'), findsOneWidget);
  });

  testWidgets('installFromServerForm', (tester) async {
    final api = api0()..sshKeyList.add(key());
    await pump(tester, api);
    await showServer(tester);
    await tester.tap(find.byTooltip('Modifier'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text(Fr.installKeyHere), 200, scrollable: formScroll);
    await tester.ensureVisible(find.text(Fr.installKeyHere));
    await tester.pumpAndSettle();
    await tester.tap(find.text(Fr.installKeyHere));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Téléphone'));
    await tester.pumpAndSettle();
    expect(api.calls, contains('installPublicKey s1 k1'));
    await tester.tap(find.widgetWithText(FilledButton, Fr.useKey));
    await tester.pumpAndSettle();
    expect(api.calls, contains('setServerKey s1 k1'));
    expect(find.text('ssh-ed25519 SHA256:abc'), findsOneWidget);
  });
}

import 'dart:convert';

import 'package:fluluks/src/app.dart';
import 'package:fluluks/src/bridge/fluluks_api.g.dart';
import 'package:fluluks/src/screens/explorer_screen.dart';
import 'package:fluluks/src/screens/vault_keys_screen.dart';
import 'package:fluluks/src/state/app_state.dart';
import 'package:fluluks/src/strings_fr.dart';
import 'package:fluluks/src/widgets/vault_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_host_api.dart';

/// Phase 14, T11 : mot de passe et clé de secours d'un coffre.

const goodPass = 'correct horse battery';
const newPass = 'un tout nouveau mot de passe';
const key = 'ABCD-EFGH-JKMN-PQRS-TVWX-YZ01';

VaultMsg vault(String id, String name,
        {String state = 'closed', String? volumeId, bool recovery = false, int luks = 2}) =>
    VaultMsg(id: id, name: name, sourceKey: 'phone', sourceLabel: 'Téléphone', path: '/Coffres/$name.luks',
        sizeBytes: 1 << 30, fs: 'exfat', state: state, volumeId: volumeId, hasRecovery: recovery, biometric: false,
        luksVersion: luks);

SourceMsg phone() => SourceMsg(id: 'phone', stableKey: 'phone', kind: 'phone', label: 'Téléphone',
    totalBytes: 128 << 30, freeBytes: 50 << 30, readOnly: false, roReason: '', encrypted: false);

FakeHostApi api0(List<VaultMsg> vaults) => FakeHostApi()
  ..sources = [phone()]
  ..dirs['phone'] = {'/': []}
  ..vaults = vaults
  ..filePassword = goodPass;

Future<AppState> pump(WidgetTester tester, FakeHostApi api) async {
  tester.view.physicalSize = const Size(600, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final state = AppState(api);
  await state.refresh();
  await tester.pumpWidget(FluLuksApp(state: state));
  await tester.pumpAndSettle();
  return state;
}

Future<void> menu(WidgetTester tester, String name, String item) async {
  final m = find.byTooltip(Fr.sourceMenu(name));
  await tester.scrollUntilVisible(m, 200, scrollable: find.byType(Scrollable).first);
  await tester.tap(m);
  await tester.pumpAndSettle();
  await tester.tap(find.text(item));
  await tester.pumpAndSettle();
}

Finder field(String label) => find.widgetWithText(TextField, label);

/// Saisit [pw] dans le dialogue « mot de passe du coffre » et le valide.
Future<void> confirmWithPassword(WidgetTester tester, String pw) async {
  await tester.enterText(find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField)), pw);
  await tester.pump();
  await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.byType(FilledButton)));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('changeVaultPasswordFromMenu', (tester) async {
    final api = api0([vault('a1', 'Papiers')]);
    await pump(tester, api);
    await menu(tester, 'Papiers', Fr.changePasswordAction);
    expect(find.text(Fr.changeVaultPasswordTitle('Papiers')), findsOneWidget);
    expect(find.text(Fr.oldPasswordOrRecovery), findsOneWidget); // la clé de secours remplace un mot de passe oublié
    await tester.enterText(field(Fr.currentPassword), 'mauvais mot de passe');
    await tester.enterText(field(Fr.password), newPass);
    await tester.enterText(field(Fr.passwordConfirm), newPass);
    await tester.pump();
    await tester.tap(find.text(Fr.changeButton));
    await tester.pumpAndSettle();
    expect(find.text(Fr.badPassword), findsOneWidget); // le dialogue reste
    await tester.enterText(field(Fr.currentPassword), goodPass);
    await tester.pump();
    await tester.tap(find.text(Fr.changeButton));
    await tester.pumpAndSettle();
    expect(api.changedVaultPasswords.single, ('a1', goodPass, newPass));
    expect(find.text(Fr.passwordChanged), findsOneWidget);
  });

  testWidgets('recoveryKeyShownOnce', (tester) async {
    final api = api0([vault('a1', 'Papiers')]);
    await pump(tester, api);
    await menu(tester, 'Papiers', Fr.recoveryKey);
    expect(find.byType(RecoveryKeyScreen), findsOneWidget);
    expect(find.text(Fr.recoveryKeyAbsent), findsOneWidget);
    await tester.tap(find.text(Fr.recoveryKeyCreate));
    await tester.pumpAndSettle();
    await confirmWithPassword(tester, goodPass);
    expect(api.addedRecovery.single, ('a1', goodPass));
    // montrée une fois, avec Copier et « J'ai noté la clé »
    expect(find.text(key), findsOneWidget);
    expect(find.text(Fr.recoveryKeyShownOnce), findsOneWidget);
    await tester.tap(find.text(Fr.copyRecoveryKey));
    await tester.pumpAndSettle();
    expect(utf8.decode(api.secretCopies.single), key);
    await tester.tap(find.text(Fr.recoveryKeyNoted));
    await tester.pumpAndSettle();
    expect(find.text(key), findsNothing); // jamais réaffichée
    expect(api.lastRecoveryBytes!.every((b) => b == 0), isTrue); // octets mis à zéro
    expect(find.text(Fr.recoveryKeyPresent), findsOneWidget);
    expect(find.text(Fr.recoveryKeyCreate), findsNothing);
    expect(find.text(Fr.recoveryKeyReplace), findsOneWidget);
  });

  testWidgets('removeRecoveryKeepsPassword', (tester) async {
    final api = api0([vault('a1', 'Papiers', recovery: true)]);
    await pump(tester, api);
    await menu(tester, 'Papiers', Fr.recoveryKey);
    expect(find.text(Fr.recoveryKeyPresent), findsOneWidget);
    await tester.tap(find.text(Fr.recoveryKeyRemove));
    await tester.pumpAndSettle();
    await confirmWithPassword(tester, goodPass);
    expect(api.removedRecovery.single, ('a1', goodPass));
    expect(find.text(Fr.recoveryKeyAbsent), findsOneWidget);
  });

  testWidgets('openWithRecoveryKey', (tester) async {
    final api = api0([vault('a1', 'Papiers', recovery: true), vault('a2', 'Photos')]);
    await pump(tester, api);
    // sans clé de secours : pas de lien
    final photos = find.descendant(
        of: find.ancestor(of: find.text('Photos'), matching: find.byType(VaultTile)), matching: find.text(Fr.open));
    await tester.scrollUntilVisible(photos, 200, scrollable: find.byType(Scrollable).first);
    await tester.tap(photos);
    await tester.pumpAndSettle();
    expect(find.text(Fr.useRecoveryKey), findsNothing);
    await tester.tap(find.text(Fr.cancel));
    await tester.pumpAndSettle();

    final papiers = find.descendant(
        of: find.ancestor(of: find.text('Papiers'), matching: find.byType(VaultTile)), matching: find.text(Fr.open));
    await tester.tap(papiers);
    await tester.pumpAndSettle();
    await tester.tap(find.text(Fr.useRecoveryKey));
    await tester.pumpAndSettle();
    expect(field(Fr.recoveryKey), findsOneWidget);
    await tester.enterText(field(Fr.recoveryKey), 'abcd efgh jkmn pqrs tvwx yz01');
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text(Fr.open)));
    await tester.pumpAndSettle();
    expect(api.recoveryOpens.last, isTrue);
    expect(api.openedVaults.last.$4, 'abcd efgh jkmn pqrs tvwx yz01'); // remise en forme par Kotlin
    expect(find.byType(ExplorerScreen), findsOneWidget);
  });

  testWidgets('luks1VaultOffersNothing', (tester) async {
    final api = api0([vault('a1', 'Linux', luks: 1)]);
    await pump(tester, api);
    final m = find.byTooltip(Fr.sourceMenu('Linux'));
    await tester.scrollUntilVisible(m, 200, scrollable: find.byType(Scrollable).first);
    await tester.tap(m);
    await tester.pumpAndSettle();
    expect(find.text(Fr.vaultLuks1), findsOneWidget);
    expect(find.text(Fr.changePasswordAction), findsNothing);
    expect(find.text(Fr.recoveryKey), findsNothing);
  });

  testWidgets('keysNeedClosedVault', (tester) async {
    final api = api0([vault('a1', 'Papiers', state: 'open', volumeId: 'vv9')])
      ..sources = [
        phone(),
        SourceMsg(id: 'vv9', stableKey: 'vault:a1', kind: 'vault', label: 'Coffre Papiers', totalBytes: 1 << 30,
            freeBytes: 1 << 29, readOnly: false, roReason: '', encrypted: true),
      ];
    await pump(tester, api);
    await menu(tester, 'Papiers', Fr.recoveryKey);
    expect(find.text(Fr.closeVaultFirst), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, Fr.recoveryKeyCreate)).onPressed, isNull);
    await tester.tap(find.byTooltip('Retour'));
    await tester.pumpAndSettle();
    await menu(tester, 'Papiers', Fr.changePasswordAction);
    expect(find.text(Fr.closeVaultFirst), findsOneWidget);
  });
}

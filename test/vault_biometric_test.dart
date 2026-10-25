import 'package:fluluks/src/app.dart';
import 'package:fluluks/src/bridge/fluluks_api.g.dart';
import 'package:fluluks/src/screens/explorer_screen.dart';
import 'package:fluluks/src/state/app_state.dart';
import 'package:fluluks/src/strings_fr.dart';
import 'package:fluluks/src/widgets/vault_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_host_api.dart';

/// Phase 14, T12 : déverrouillage biométrique d'un coffre.

const goodPass = 'correct horse battery';
const noStrong = "Ce téléphone n'a pas de biométrie forte (visage ou empreinte)";

VaultMsg vault(String id, String name, {String state = 'closed', String? volumeId, bool biometric = false}) => VaultMsg(
    id: id, name: name, sourceKey: 'phone', sourceLabel: 'Téléphone', path: '/Coffres/$name.luks', sizeBytes: 1 << 30,
    fs: 'exfat', state: state, volumeId: volumeId, hasRecovery: false, biometric: biometric, luksVersion: 2);

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

Future<void> openMenu(WidgetTester tester, String name) async {
  final m = find.byTooltip(Fr.sourceMenu(name));
  await tester.scrollUntilVisible(m, 200, scrollable: find.byType(Scrollable).first);
  await tester.tap(m);
  await tester.pumpAndSettle();
}

Future<void> tapOpen(WidgetTester tester, String name) async {
  final b = find.descendant(
      of: find.ancestor(of: find.text(name), matching: find.byType(VaultTile)), matching: find.text(Fr.open));
  await tester.scrollUntilVisible(b, 200, scrollable: find.byType(Scrollable).first);
  await tester.tap(b);
  await tester.pumpAndSettle();
}

Future<void> confirmWithPassword(WidgetTester tester, String pw) async {
  await tester.enterText(find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField)), pw);
  await tester.pump();
  await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.byType(FilledButton)));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('hiddenWithoutStrongBiometric', (tester) async {
    final api = api0([vault('a1', 'Papiers')])..biometricReason = noStrong;
    await pump(tester, api);
    await openMenu(tester, 'Papiers');
    expect(find.text(Fr.biometricEnable), findsNothing);
    expect(find.text(noStrong), findsOneWidget); // la raison, dans une ligne inactive
    expect(tester.widget<PopupMenuItem<String>>(
        find.ancestor(of: find.text(noStrong), matching: find.byType(PopupMenuItem<String>))).enabled, isFalse);
  });

  testWidgets('enableFromMenu', (tester) async {
    final api = api0([vault('a1', 'Papiers')]);
    await pump(tester, api);
    await openMenu(tester, 'Papiers');
    await tester.tap(find.text(Fr.biometricEnable));
    await tester.pumpAndSettle();
    expect(find.text(Fr.biometricEnableHelp), findsOneWidget);
    await confirmWithPassword(tester, goodPass);
    expect(api.enabledBiometric.single, ('a1', goodPass));
    expect(find.text(Fr.biometricEnabled), findsOneWidget);
    expect(find.text(Fr.chipBiometric), findsOneWidget); // puce sur la tuile
  });

  testWidgets('openUsesBiometricFirst', (tester) async {
    final api = api0([vault('a1', 'Papiers', biometric: true)]);
    await pump(tester, api);
    await tapOpen(tester, 'Papiers');
    expect(api.biometricOpens.single, ('a1', true));
    expect(find.text(Fr.vaultOpenTitle('Papiers')), findsNothing); // pas de mot de passe demandé
    expect(find.byType(ExplorerScreen), findsOneWidget);
  });

  testWidgets('cancelFallsBackToPassword', (tester) async {
    final api = api0([vault('a1', 'Papiers', biometric: true)])
      ..biometricError = PlatformException(code: 'biometricCancelled', message: 'Déverrouillage biométrique annulé');
    await pump(tester, api);
    await tapOpen(tester, 'Papiers');
    expect(find.text(Fr.vaultOpenTitle('Papiers')), findsOneWidget);
    expect(find.text('Déverrouillage biométrique annulé'), findsNothing); // pas d'erreur pour une annulation
    await tester.enterText(find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField)), goodPass);
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text(Fr.open)));
    await tester.pumpAndSettle();
    expect(find.byType(ExplorerScreen), findsOneWidget);
  });

  testWidgets('enrollmentChangeDisablesBiometric', (tester) async {
    const msg = 'Déverrouillage biométrique désactivé : la biométrie du téléphone a changé. '
        'Ouvrez le coffre avec son mot de passe.';
    final api = api0([vault('a1', 'Papiers', biometric: true)])
      ..biometricError = PlatformException(code: 'biometricInvalidated', message: msg);
    await pump(tester, api);
    await tapOpen(tester, 'Papiers');
    expect(find.text(msg), findsOneWidget); // dit pourquoi
    expect(find.text(Fr.vaultOpenTitle('Papiers')), findsOneWidget); // et propose le mot de passe
    await tester.tap(find.text(Fr.cancel));
    await tester.pumpAndSettle();
    expect(find.text(Fr.chipBiometric), findsNothing); // désactivée
  });

  testWidgets('disableFromMenu', (tester) async {
    final api = api0([vault('a1', 'Papiers', biometric: true)]);
    await pump(tester, api);
    await openMenu(tester, 'Papiers');
    await tester.tap(find.text(Fr.biometricDisable));
    await tester.pumpAndSettle();
    await confirmWithPassword(tester, goodPass); // coffre fermé : l'emplacement est retiré aussi
    expect(api.disabledBiometric.single, ('a1', goodPass));
    expect(find.text(Fr.biometricDisabled), findsOneWidget);
  });

  testWidgets('disableWhileOpenNeedsNoPassword', (tester) async {
    final api = api0([vault('a1', 'Papiers', state: 'open', volumeId: 'vv9', biometric: true)])
      ..sources = [
        phone(),
        SourceMsg(id: 'vv9', stableKey: 'vault:a1', kind: 'vault', label: 'Coffre Papiers', totalBytes: 1 << 30,
            freeBytes: 1 << 29, readOnly: false, roReason: '', encrypted: true),
      ];
    await pump(tester, api);
    await openMenu(tester, 'Papiers');
    expect(find.text(Fr.biometricEnable), findsNothing);
    await tester.tap(find.text(Fr.biometricDisable));
    await tester.pumpAndSettle();
    expect(find.text(Fr.biometricDisableOpenBody), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, Fr.biometricDisableConfirm));
    await tester.pumpAndSettle();
    expect(api.disabledBiometric.single, ('a1', null));
  });
}

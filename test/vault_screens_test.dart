import 'dart:async';

import 'package:fluluks/src/app.dart';
import 'package:fluluks/src/bridge/fluluks_api.g.dart';
import 'package:fluluks/src/screens/explorer_screen.dart';
import 'package:fluluks/src/screens/vault_create_screen.dart';
import 'package:fluluks/src/state/app_state.dart';
import 'package:fluluks/src/strings_fr.dart';
import 'package:fluluks/src/widgets/vault_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_host_api.dart';

/// Phase 14, T10 : écrans des coffres (création, section « Coffres » de l'accueil, ouvrir, fermer, parcourir).

const goodPass = 'correct horse battery';
const mib = 1 << 20;
const gib = 1 << 30;

EntryMsg f(String path) => EntryMsg(name: path.split('/').last, path: path, type: 'file', size: gib, mtime: 1700000000);
EntryMsg d(String path) => EntryMsg(name: path.split('/').last, path: path, type: 'dir', size: 0, mtime: 1700000000);

SourceMsg src(String id, {String kind = 'phone', String label = 'Téléphone', int total = 128 * gib, int free = 50 * gib}) =>
    SourceMsg(id: id, stableKey: id, kind: kind, label: label, totalBytes: total, freeBytes: free, readOnly: false,
        roReason: '', encrypted: false);

VaultMsg vault(String id, String name,
        {String state = 'closed', String? volumeId, String sourceKey = 'phone', String sourceLabel = 'Téléphone'}) =>
    VaultMsg(id: id, name: name, sourceKey: sourceKey, sourceLabel: sourceLabel, path: '/Coffres/$name.luks',
        sizeBytes: gib, fs: 'exfat', state: state, volumeId: volumeId, hasRecovery: false, biometric: false,
        luksVersion: 2);

FakeHostApi api0() => FakeHostApi()
  ..sources = [src('phone'), src('r1', kind: 'remote', label: 'Serveur', total: -1, free: -1)]
  ..dirs['phone'] = {
    '/': [d('/Coffres'), d('/Documents'), f('/Photos.luks'), f('/disque.img')],
    '/Coffres': [],
    '/Documents': [],
  }
  ..dirs['r1'] = {'/': []}
  ..encryptedInfos['/disque.img'] = EncryptedInfoMsg(format: 'luks', folder: false)
  ..filePassword = goodPass;

/// Application sur un écran haut (moins de défilement), et [page] par-dessus l'accueil si donnée.
Future<AppState> pump(WidgetTester tester, FakeHostApi api, {Widget Function(AppState)? page}) async {
  tester.view.physicalSize = const Size(600, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final state = AppState(api);
  await state.refresh();
  await tester.pumpWidget(FluLuksApp(state: state));
  if (page != null) {
    tester.state<NavigatorState>(find.byType(Navigator)).push(MaterialPageRoute<void>(builder: (_) => page(state)));
  }
  await tester.pumpAndSettle();
  return state;
}

Finder scrollable() {
  final create = find.byType(VaultCreateScreen);
  return create.evaluate().isNotEmpty
      ? find.descendant(of: create, matching: find.byType(Scrollable)).first
      : find.byType(Scrollable).first;
}

Future<void> seek(WidgetTester tester, Finder f) async {
  if (f.evaluate().isEmpty) await tester.scrollUntilVisible(f, 200, scrollable: scrollable());
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
}

Future<void> tapVisible(WidgetTester tester, Finder f) async {
  await seek(tester, f);
  await tester.tap(f);
  await tester.pumpAndSettle();
}

Finder chip(int bytes) => find.byKey(ValueKey('vault-size-$bytes'));
bool chipEnabled(WidgetTester tester, int bytes) => tester.widget<ChoiceChip>(chip(bytes)).onSelected != null;
bool chipSelected(WidgetTester tester, int bytes) => tester.widget<ChoiceChip>(chip(bytes)).selected;

Future<void> typeNewPassword(WidgetTester tester, String pw) async {
  final p = find.widgetWithText(TextField, Fr.password);
  await seek(tester, p);
  await tester.enterText(p, pw);
  final c = find.widgetWithText(TextField, Fr.passwordConfirm);
  await seek(tester, c);
  await tester.enterText(c, pw);
  await tester.pump();
}

Finder createButton() => find.widgetWithText(FilledButton, Fr.createVaultButton);

/// Bouton [label] d'une tuile de coffre ([name]).
Finder tileButton(String name, String label) => find.descendant(
      of: find.ancestor(of: find.text(name), matching: find.byType(VaultTile)),
      matching: find.text(label),
    );

/// Saisit [pw] dans le dialogue d'ouverture et l'envoie.
Future<void> submitUnlock(WidgetTester tester, String pw) async {
  await tester.enterText(find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField)), pw);
  await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text(Fr.open)));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('createFormDefaults', (tester) async {
    final api = api0();
    await pump(tester, api, page: (s) => VaultCreateScreen(state: s, sourceId: 'phone', dir: '/Documents'));
    expect(chipSelected(tester, gib), isTrue); // 1 Gio
    expect(tester.widget<RadioGroup<String>>(find.byType(RadioGroup<String>)).groupValue, 'exfat');
    expect(find.text(Fr.destChosen('Téléphone', '/Documents')), findsOneWidget); // dossier ouvert
    await tester.enterText(find.byKey(const ValueKey('vault-name')), 'Photos');
    await typeNewPassword(tester, goodPass);
    await tapVisible(tester, createButton());
    expect(api.createdVaults.single, ('phone', '/Documents', 'Photos', gib, 'exfat', goodPass));
    expect(find.byType(VaultCreateScreen), findsNothing);
    expect(find.text(Fr.vaultCreated('Photos')), findsOneWidget);
  });

  testWidgets('sizeChoicesRespectFreeSpace', (tester) async {
    // 2 Gio libres, réserve de 256 Mio : 1,75 Gio au plus
    var api = api0()..sources = [src('phone', free: 2 * gib)];
    await pump(tester, api, page: (s) => VaultCreateScreen(state: s, sourceId: 'phone'));
    expect(chipEnabled(tester, 256 * mib), isTrue);
    expect(chipEnabled(tester, gib), isTrue);
    expect(chipEnabled(tester, 4 * gib), isFalse);
    expect(chipEnabled(tester, 16 * gib), isFalse);

    // 600 Mio libres : 344 Mio au plus, 256 Mio choisi d'office
    api = api0()..sources = [src('phone', free: 600 * mib, total: 10 * gib)];
    await tester.pumpWidget(const SizedBox.shrink());
    await pump(tester, api, page: (s) => VaultCreateScreen(state: s, sourceId: 'phone'));
    expect(chipEnabled(tester, gib), isFalse);
    expect(chipSelected(tester, 256 * mib), isTrue);
    await tapVisible(tester, find.byKey(const ValueKey('vault-size-other')));
    await tester.enterText(find.byKey(const ValueKey('vault-size-custom')), '400');
    await typeNewPassword(tester, goodPass);
    await seek(tester, find.text(Fr.vaultSizeRange(32, 344)));
    expect(tester.widget<FilledButton>(createButton()).onPressed, isNull);
    await tester.enterText(find.byKey(const ValueKey('vault-size-custom')), '300');
    await tester.pump();
    await tapVisible(tester, createButton());
    expect(api.createdVaults.single.$4, 300 * mib);

    // moins de 32 Mio de place : rien ne se crée
    api = api0()..sources = [src('phone', free: 200 * mib, total: 4 * gib)];
    await tester.pumpWidget(const SizedBox.shrink());
    await pump(tester, api, page: (s) => VaultCreateScreen(state: s, sourceId: 'phone'));
    expect(find.text(Fr.vaultNoSpace), findsOneWidget);
  });

  testWidgets('fat32HostCapsSize', (tester) async {
    final api = api0()
      ..sources = [src('v1', kind: 'disk', label: 'Clé', free: 100 * gib, total: 120 * gib)]
      ..disks = [disk([part(index: 1, content: 'FAT32', encrypted: false, volumeId: 'v1')])];
    await pump(tester, api, page: (s) => VaultCreateScreen(state: s, sourceId: 'v1'));
    expect(find.text(Fr.vaultFatLimit), findsOneWidget);
    expect(chipEnabled(tester, 16 * gib), isFalse);
    expect(chipEnabled(tester, 4 * gib), isTrue);
    await tapVisible(tester, chip(4 * gib));
    await typeNewPassword(tester, goodPass);
    await tapVisible(tester, createButton());
    expect(api.createdVaults.single.$4, (4 << 30) - 512); // 4 Gio moins un secteur
  });

  testWidgets('ext4ExplainsLinuxOwnership', (tester) async {
    final api = api0();
    await pump(tester, api, page: (s) => VaultCreateScreen(state: s, sourceId: 'phone'));
    expect(find.text(Fr.vaultExt4Owner), findsNothing);
    await tapVisible(tester, find.text('ext4'));
    await seek(tester, find.text(Fr.vaultExt4Owner));
    expect(find.text(Fr.vaultExt4Owner), findsOneWidget);
    await typeNewPassword(tester, goodPass);
    await tapVisible(tester, createButton());
    expect(api.createdVaults.single.$5, 'ext4');
  });

  testWidgets('noRecoveryWarningAlwaysShown', (tester) async {
    await pump(tester, api0(), page: (s) => VaultCreateScreen(state: s, sourceId: 'phone'));
    await seek(tester, find.text(Fr.vaultNoRecovery));
    expect(find.text(Fr.vaultNoRecovery), findsOneWidget);
    await typeNewPassword(tester, goodPass);
    await seek(tester, find.text(Fr.vaultNoRecovery));
    expect(find.text(Fr.vaultNoRecovery), findsOneWidget);
  });

  testWidgets('createShowsProgressAndCancel', (tester) async {
    final api = api0()..createVaultGate = Completer<void>();
    final state = await pump(tester, api, page: (s) => VaultCreateScreen(state: s, sourceId: 'phone'));
    await tester.enterText(find.byKey(const ValueKey('vault-name')), 'Photos');
    await typeNewPassword(tester, goodPass);
    await seek(tester, createButton());
    await tester.tap(createButton());
    await tester.pump(); // barre indéterminée jusqu'à la première progression : pas de pumpAndSettle
    state.onTransferChanged(TransferMsg(kind: 'vault', move: false, currentName: 'Photos.luks', fileIndex: 1,
        fileCount: 1, doneBytes: 50, totalBytes: 100, finished: false, cancelled: false, elapsedMs: 1000,
        badPassword: false));
    await tester.pump();
    final screen = find.byType(VaultCreateScreen);
    expect(find.descendant(of: screen, matching: find.text(Fr.transferLine('vault', 'Photos.luks', 1, 1, 50))),
        findsOneWidget);
    expect(
        find.descendant(
            of: screen, matching: find.byWidgetPredicate((w) => w is LinearProgressIndicator && w.value == 0.5)),
        findsOneWidget);
    await tester.tap(find.descendant(of: screen, matching: find.text(Fr.cancel)));
    await tester.pump();
    expect(api.transferCancels, 1);
    api.createVaultError = PlatformException(code: 'io', message: 'Création du coffre annulée');
    api.createVaultGate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('Création du coffre annulée'), findsOneWidget); // l'écran reste, le bouton revient
    expect(createButton(), findsOneWidget);
  });

  testWidgets('homeListsVaultsWithState', (tester) async {
    final api = api0()
      ..sources = [
        src('phone'),
        SourceMsg(id: 'vv9', stableKey: 'vault:a2', kind: 'vault', label: 'Coffre Photos', totalBytes: gib,
            freeBytes: mib, readOnly: false, roReason: '', encrypted: true),
      ]
      ..vaults = [
        vault('a1', 'Papiers'),
        vault('a2', 'Photos', state: 'open', volumeId: 'vv9'),
        vault('a3', 'Ancien', state: 'unavailable', sourceKey: 'sd:x', sourceLabel: 'Carte SD'),
      ];
    await pump(tester, api);
    await seek(tester, find.text(Fr.vaults));
    for (final n in ['Papiers', 'Photos', 'Ancien']) {
      expect(find.descendant(of: find.byType(VaultTile), matching: find.text(n)), findsOneWidget);
    }
    expect(tileButton('Papiers', Fr.vaultClosed), findsOneWidget);
    expect(tileButton('Photos', Fr.vaultOpen), findsOneWidget);
    expect(tileButton('Ancien', Fr.vaultUnavailable('Carte SD')), findsOneWidget);
    expect(tileButton('Ancien', Fr.open), findsNothing);
    expect(find.text('Coffre Photos'), findsNothing); // pas dans « Stockage » : sa tuile est dans « Coffres »
  });

  testWidgets('homeCreateOpensForm', (tester) async {
    await pump(tester, api0());
    await tapVisible(tester, find.text(Fr.createVault));
    final s = tester.widget<VaultCreateScreen>(find.byType(VaultCreateScreen));
    expect((s.sourceId, s.dir), ('phone', '/'));
  });

  testWidgets('openThenBrowse', (tester) async {
    final api = api0()..vaults = [vault('a1', 'Papiers')];
    await pump(tester, api);
    await tapVisible(tester, tileButton('Papiers', Fr.open));
    expect(find.text(Fr.vaultOpenTitle('Papiers')), findsOneWidget);
    await submitUnlock(tester, 'mauvais mot de passe');
    expect(find.text(Fr.badPassword), findsOneWidget); // le dialogue reste
    await submitUnlock(tester, goodPass);
    expect(api.openedVaults.last, ('a1', null, null, goodPass, true));
    final e = tester.widget<ExplorerScreen>(find.byType(ExplorerScreen));
    expect(e.sourceId, 'vv2'); // racine du coffre ouvert
  });

  testWidgets('closeFromTile', (tester) async {
    final api = api0()
      ..sources = [
        src('phone'),
        SourceMsg(id: 'vv9', stableKey: 'vault:a2', kind: 'vault', label: 'Coffre Photos', totalBytes: gib,
            freeBytes: mib, readOnly: false, roReason: '', encrypted: true),
      ]
      ..vaults = [vault('a2', 'Photos', state: 'open', volumeId: 'vv9')];
    await pump(tester, api);
    await tapVisible(tester, tileButton('Photos', Fr.vaultClose));
    expect(api.closedVaults, ['a2']);
    expect(tileButton('Photos', Fr.vaultClosed), findsOneWidget);
  });

  testWidgets('forgetKeepsFile', (tester) async {
    final api = api0()..vaults = [vault('a1', 'Papiers')];
    await pump(tester, api);
    await tapVisible(tester, find.byTooltip(Fr.sourceMenu('Papiers')));
    await tapVisible(tester, find.text(Fr.vaultForget));
    expect(find.text(Fr.vaultForgetBody), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, Fr.vaultForgetConfirm));
    await tester.pumpAndSettle();
    expect(api.forgottenVaults, ['a1']);
    expect(api.calls.where((c) => c.startsWith('delete')), isEmpty); // le fichier reste
    expect(find.text('Papiers'), findsNothing);
  });

  testWidgets('tapLuksFileOffersOpen', (tester) async {
    final api = api0();
    await pump(tester, api, page: (s) => ExplorerScreen(state: s, sourceId: 'phone'));
    // fichier LUKS sans l'extension .luks : reconnu par ses premiers octets
    await tester.tap(find.text('disque.img'));
    await tester.pumpAndSettle();
    expect(find.text(Fr.vaultOpenAction), findsOneWidget);
    expect(find.text(Fr.openWith), findsOneWidget);
    await tester.tap(find.text(Fr.vaultOpenAction));
    await tester.pumpAndSettle();
    expect(find.text(Fr.vaultOpenTitle('disque.img')), findsOneWidget);
    await tester.tap(find.text(Fr.cancel));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Photos.luks'));
    await tester.pumpAndSettle();
    expect(find.text(Fr.vaultOpenTitle('Photos')), findsOneWidget);
    await submitUnlock(tester, goodPass);
    expect(api.openedVaults.single, (null, 'phone', '/Photos.luks', goodPass, true));
    expect(tester.widget<ExplorerScreen>(find.byType(ExplorerScreen).last).sourceId, 'vv1');
  });

  testWidgets('readOnlyCheckboxHonoursSetting', (tester) async {
    final api = api0()
      ..vaults = [vault('a1', 'Papiers')]
      ..readOnlyPreference = true;
    await pump(tester, api);
    await tapVisible(tester, tileButton('Papiers', Fr.open));
    expect(tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value, isTrue);
    await submitUnlock(tester, goodPass);
    expect(api.openedVaults.single.$5, isFalse);
  });

  testWidgets('newVaultFromExplorerMenu', (tester) async {
    await pump(tester, api0(), page: (s) => ExplorerScreen(state: s, sourceId: 'phone'));
    await tester.tap(find.byTooltip(Fr.create));
    await tester.pumpAndSettle();
    expect(find.text(Fr.newFolder), findsOneWidget);
    await tester.tap(find.text(Fr.newVault));
    await tester.pumpAndSettle();
    final s = tester.widget<VaultCreateScreen>(find.byType(VaultCreateScreen));
    expect((s.sourceId, s.dir), ('phone', '/'));
  });

  testWidgets('noVaultOnRemoteFolder', (tester) async {
    await pump(tester, api0(), page: (s) => ExplorerScreen(state: s, sourceId: 'r1'));
    expect(find.byTooltip(Fr.create), findsNothing);
    expect(find.byTooltip(Fr.newFolder), findsOneWidget); // un dossier, directement
  });
}

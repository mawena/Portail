import 'dart:convert';

import 'package:fluluks/src/app.dart';
import 'package:fluluks/src/bridge/fluluks_api.g.dart';
import 'package:fluluks/src/screens/encrypt_sheet.dart';
import 'package:fluluks/src/screens/explorer_screen.dart';
import 'package:fluluks/src/state/app_state.dart';
import 'package:fluluks/src/strings_fr.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_host_api.dart';

EntryMsg f(String path, {int size = 1000}) =>
    EntryMsg(name: path.split('/').last, path: path, type: 'file', size: size, mtime: 1700000000);
EntryMsg d(String path) => EntryMsg(name: path.split('/').last, path: path, type: 'dir', size: 0, mtime: 1700000000);

SourceMsg src(String id, {String kind = 'phone', String label = 'Téléphone', bool readOnly = false}) => SourceMsg(
      id: id, stableKey: id, kind: kind, label: label, totalBytes: 1000, freeBytes: 500, readOnly: readOnly,
      roReason: readOnly ? 'protégé en écriture' : '', encrypted: false);

const goodPass = 'correct horse battery';

FakeHostApi api0() => FakeHostApi()
  ..sources = [src('phone'), src('r1', kind: 'remote', label: 'Serveur')]
  ..dirs['phone'] = {
    '/': [d('/DCIM'), f('/b.txt'), f('/notes.txt'), f('/rapport.pdf.age'), f('/photos.zip.age'), f('/secret.zip')],
  }
  ..dirs['r1'] = {
    '/': [d('/partage'), f('/lisez-moi.txt')],
    '/partage': [],
  }
  ..encryptedInfos['/rapport.pdf.age'] = EncryptedInfoMsg(format: 'age', folder: false)
  ..encryptedInfos['/photos.zip.age'] = EncryptedInfoMsg(format: 'age', folder: true)
  ..encryptedInfos['/secret.zip'] = EncryptedInfoMsg(format: 'zip-aes', folder: false)
  ..filePassword = goodPass;

Future<AppState> pump(WidgetTester tester, FakeHostApi api) async {
  final state = AppState(api);
  await state.refresh();
  await tester.pumpWidget(FluLuksApp(state: state));
  tester.state<NavigatorState>(find.byType(Navigator)).push(
      MaterialPageRoute<void>(builder: (_) => ExplorerScreen(state: state, sourceId: 'phone')));
  await tester.pumpAndSettle();
  return state;
}

Future<void> itemAction(WidgetTester tester, String name, String action) async {
  await tester.tap(find.bySemanticsLabel(Fr.actionsOf(name)));
  await tester.pumpAndSettle();
  await tapVisible(tester, find.text(action)); // feuille d'actions longue : défilée jusqu'à l'action
}

Future<void> typePassword(WidgetTester tester, String pw, {bool confirm = true}) async {
  final p = find.widgetWithText(TextField, Fr.password);
  if (confirm) await seek(tester, p);
  await tester.enterText(p, pw);
  if (confirm) {
    final c = find.widgetWithText(TextField, Fr.passwordConfirm);
    await seek(tester, c);
    await tester.enterText(c, pw);
  }
  await tester.pump();
}

/// Liste qui défile : celle de l'écran Chiffrer s'il est ouvert (et non celle d'un champ de texte), sinon la
/// dernière (feuille d'actions).
Finder scrollable() {
  final sheet = find.byType(EncryptSheet);
  return sheet.evaluate().isNotEmpty
      ? find.descendant(of: sheet, matching: find.byType(Scrollable)).first
      : find.byType(Scrollable).last;
}

/// Fait défiler jusqu'à [f] (une liste ne construit pas ce qui est hors de la vue).
Future<void> seek(WidgetTester tester, Finder f) async {
  if (f.evaluate().isEmpty) {
    await tester.scrollUntilVisible(f, 200, scrollable: scrollable());
  }
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
}

Future<void> tapVisible(WidgetTester tester, Finder f) async {
  await seek(tester, f);
  await tester.tap(f);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('encryptSheetDefaults', (tester) async {
    final api = api0();
    await pump(tester, api);
    await itemAction(tester, 'b.txt', Fr.encryptAction);
    expect(find.text(Fr.encryptTitle), findsWidgets);
    expect(tester.widget<RadioGroup<String>>(find.byKey(const ValueKey('encrypt-format'))).groupValue, 'age');
    expect(tester.widget<RadioGroup<String>>(find.byKey(const ValueKey('encrypt-dest'))).groupValue, 'here');
    await seek(tester, find.widgetWithText(CheckboxListTile, Fr.deleteOriginal));
    expect(tester.widget<CheckboxListTile>(find.widgetWithText(CheckboxListTile, Fr.deleteOriginal)).value, isFalse);
    expect(find.text(Fr.together), findsNothing); // un seul élément
    await seek(tester, find.text(Fr.passwordNoRecovery));
    final button = find.widgetWithText(FilledButton, Fr.encryptButton);
    await seek(tester, button);
    expect(tester.widget<FilledButton>(button).onPressed, isNull); // pas de mot de passe
    await typePassword(tester, goodPass);
    await tapVisible(tester, button);
    final e = api.encrypts.single;
    expect([e.srcId, e.paths, e.dstId, e.dstDir, e.format, e.together, e.name, e.deleteOriginal],
        ['phone', ['/b.txt'], 'phone', '/', 'age', false, null, false]);
    expect(e.password, goodPass);
    expect(find.text(Fr.encryptTitle), findsNothing); // écran fermé
  });

  testWidgets('passwordSurvivesScroll', (tester) async {
    // petit écran : remonter en haut sort le champ de la zone que la liste garde construite
    tester.view.physicalSize = const Size(1080, 1200);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    final api = api0();
    await pump(tester, api);
    await itemAction(tester, 'b.txt', Fr.encryptAction);
    await typePassword(tester, goodPass);
    // remonter en haut de l'écran, puis redescendre : le champ n'est ni démonté ni vidé
    FocusManager.instance.primaryFocus?.unfocus(); // clavier fermé : un champ sans le focus n'est plus gardé
    await tester.pump();
    await tester.drag(scrollable(), const Offset(0, 3000));
    await tester.pumpAndSettle();
    expect(find.text(Fr.formatStrong).hitTestable(), findsOneWidget); // en haut de l'écran
    await tester.pumpAndSettle();
    await tapVisible(tester, find.widgetWithText(FilledButton, Fr.encryptButton));
    expect(api.encrypts.single.password, goodPass);
  });

  testWidgets('zipFormatShowsNamesWarning', (tester) async {
    final api = api0();
    await pump(tester, api);
    await itemAction(tester, 'b.txt', Fr.encryptAction);
    expect(find.text(Fr.zipNamesWarning), findsNothing);
    await tapVisible(tester, find.text(Fr.formatZip));
    expect(find.text(Fr.zipNamesWarning), findsOneWidget);
    await typePassword(tester, goodPass);
    await tapVisible(tester, find.widgetWithText(FilledButton, Fr.encryptButton));
    expect(api.encrypts.single.format, 'zip');
  });

  testWidgets('deleteOriginalExplainsFlash', (tester) async {
    final api = api0();
    await pump(tester, api);
    await itemAction(tester, 'b.txt', Fr.encryptAction);
    expect(find.text(Fr.deleteOriginalFlash), findsNothing);
    await tapVisible(tester, find.widgetWithText(CheckboxListTile, Fr.deleteOriginal));
    await seek(tester, find.text(Fr.deleteOriginalFlash));
    await typePassword(tester, goodPass);
    await tapVisible(tester, find.widgetWithText(FilledButton, Fr.encryptButton));
    expect(api.encrypts.single.deleteOriginal, isTrue);
  });

  testWidgets('severalSelectedOffersTogether', (tester) async {
    final api = api0();
    await pump(tester, api);
    await tester.longPress(find.text('b.txt'));
    await tester.pump();
    await tester.tap(find.text('notes.txt'));
    await tester.pump();
    await tester.tap(find.byTooltip(Fr.moreActions));
    await tester.pumpAndSettle();
    await tester.tap(find.text(Fr.encryptAction));
    await tester.pumpAndSettle();
    await tapVisible(tester, find.widgetWithText(SwitchListTile, Fr.together));
    await seek(tester, find.widgetWithText(TextField, Fr.togetherName));
    expect(find.text(Fr.archiveDefault), findsWidgets);
    await typePassword(tester, goodPass);
    await tapVisible(tester, find.widgetWithText(FilledButton, Fr.encryptButton));
    final e = api.encrypts.single;
    expect(e.paths.toSet(), {'/b.txt', '/notes.txt'});
    expect(e.together, isTrue);
    expect(e.name, Fr.archiveDefault);
  });

  testWidgets('destinationPickerIncludesRemote', (tester) async {
    final api = api0();
    await pump(tester, api);
    await itemAction(tester, 'b.txt', Fr.encryptAction);
    await tapVisible(tester, find.text(Fr.destOther));
    expect(find.text(Fr.pickFolderTitle), findsOneWidget);
    expect(find.text('Serveur'), findsOneWidget); // dossier distant proposé
    await tester.tap(find.text('Serveur'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('partage'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(Fr.pickHere));
    await tester.pumpAndSettle();
    expect(find.text(Fr.destChosen('Serveur', '/partage')), findsOneWidget);
    await typePassword(tester, goodPass);
    await tapVisible(tester, find.widgetWithText(FilledButton, Fr.encryptButton));
    expect([api.encrypts.single.dstId, api.encrypts.single.dstDir], ['r1', '/partage']);
  });

  testWidgets('tapAgeFileAsksPasswordThenOffersOpenDecryptVerify', (tester) async {
    final api = api0();
    await pump(tester, api);
    await tester.tap(find.text('rapport.pdf.age'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, Fr.password), findsOneWidget);
    for (final a in [Fr.openDecrypted, Fr.decryptHere, Fr.decryptTo, Fr.verifyAction]) {
      expect(find.text(a), findsOneWidget, reason: a);
    }
    await typePassword(tester, goodPass, confirm: false);
    await tester.tap(find.text(Fr.openDecrypted));
    await tester.pumpAndSettle();
    expect(api.openDecryptedPasswords, [goodPass]);
    // un PDF ne s'ouvre pas dans Portail : « Ouvrir avec » sur la vue déchiffrée
    expect(api.calls, contains('openWith dec:1 /rapport.pdf'));

    await tester.tap(find.text('rapport.pdf.age'));
    await tester.pumpAndSettle();
    await typePassword(tester, goodPass, confirm: false);
    await tester.tap(find.text(Fr.verifyAction));
    await tester.pumpAndSettle();
    expect(api.verifies, [('phone', '/rapport.pdf.age', goodPass)]);

    await tester.tap(find.text('rapport.pdf.age'));
    await tester.pumpAndSettle();
    await typePassword(tester, goodPass, confirm: false);
    await tester.tap(find.text(Fr.decryptHere));
    await tester.pumpAndSettle();
    final x = api.decrypts.single;
    expect([x.srcId, x.path, x.dstId, x.dstDir, x.extractFolder, x.password], ['phone', '/rapport.pdf.age', 'phone', '/', true, goodPass]);
  });

  testWidgets('tapZipAgeOffersExtract', (tester) async {
    final api = api0();
    await pump(tester, api);
    await tester.tap(find.text('photos.zip.age'));
    await tester.pumpAndSettle();
    expect(find.text(Fr.openDecrypted), findsNothing); // un dossier chiffré ne s'ouvre pas en vue
    expect(find.text(Fr.extractHere), findsOneWidget);
    expect(find.text(Fr.extractTo), findsOneWidget);
    expect(find.text(Fr.verifyAction), findsOneWidget);
    await typePassword(tester, goodPass, confirm: false);
    await tester.tap(find.text(Fr.extractHere));
    await tester.pumpAndSettle();
    expect([api.decrypts.single.path, api.decrypts.single.extractFolder], ['/photos.zip.age', true]);
  });

  testWidgets('tapProtectedZipAsksPassword', (tester) async {
    final api = api0();
    await pump(tester, api);
    await tester.tap(find.text('secret.zip'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(Fr.extractHere));
    await tester.pumpAndSettle();
    expect(find.text(Fr.protectedArchive), findsOneWidget);
    await typePassword(tester, 'motdepasse1', confirm: false);
    await tester.tap(find.widgetWithText(FilledButton, Fr.extractButton));
    await tester.pumpAndSettle();
    expect(api.extracts.single, ('phone', '/secret.zip', 'phone', '/', true));
    expect(api.extractPasswords, ['motdepasse1']);
  });

  testWidgets('badPasswordStaysInDialog', (tester) async {
    final api = api0();
    await pump(tester, api);
    await tester.tap(find.text('rapport.pdf.age'));
    await tester.pumpAndSettle();
    await typePassword(tester, 'mauvais mot', confirm: false);
    await tester.tap(find.text(Fr.openDecrypted));
    await tester.pumpAndSettle();
    expect(find.text(Fr.badPassword), findsOneWidget);
    expect(tester.widget<TextField>(find.widgetWithText(TextField, Fr.password)).controller!.text, isEmpty);
    expect(find.text(Fr.openDecrypted), findsOneWidget); // toujours dans le dialogue
    await typePassword(tester, goodPass, confirm: false);
    await tester.tap(find.text(Fr.openDecrypted));
    await tester.pumpAndSettle();
    expect(find.text(Fr.openDecrypted), findsNothing);
    expect(api.openDecryptedPasswords, ['mauvais mot', goodPass]);
  });

  testWidgets('resultOffersShare', (tester) async {
    final api = api0();
    final state = await pump(tester, api);
    await itemAction(tester, 'b.txt', Fr.encryptAction);
    await typePassword(tester, goodPass);
    await tapVisible(tester, find.widgetWithText(FilledButton, Fr.encryptButton));
    state.onTransferChanged(TransferMsg(
        badPassword: false, kind: 'encrypt', move: false, currentName: 'b.txt.age', fileIndex: 1, fileCount: 1,
        doneBytes: 1000, totalBytes: 1000, finished: true, cancelled: false, elapsedMs: 10));
    await tester.pump();
    expect(find.text(Fr.shareHintAge), findsOneWidget);
    await tester.tap(find.text(Fr.shareEncrypted));
    await tester.pumpAndSettle();
    expect(api.calls, contains('share phone /b.txt.age'));

    // ZIP chiffré : le destinataire l'ouvre avec 7-Zip
    await itemAction(tester, 'notes.txt', Fr.encryptAction);
    await tapVisible(tester, find.text(Fr.formatZip));
    await typePassword(tester, goodPass);
    await tapVisible(tester, find.widgetWithText(FilledButton, Fr.encryptButton));
    state.onTransferChanged(TransferMsg(
        badPassword: false, kind: 'encrypt', move: false, currentName: 'notes.zip', fileIndex: 1, fileCount: 1,
        doneBytes: 1000, totalBytes: 1000, finished: true, cancelled: false, elapsedMs: 10));
    await tester.pump();
    expect(find.text(Fr.shareHintZip), findsOneWidget);
  });

  testWidgets('passwordBytesZeroedAfterCall', (tester) async {
    final api = api0();
    await pump(tester, api);
    await itemAction(tester, 'b.txt', Fr.encryptAction);
    await typePassword(tester, goodPass);
    await tapVisible(tester, find.widgetWithText(FilledButton, Fr.encryptButton));
    expect(api.encrypts.single.password, goodPass); // reçu en clair par le moteur…
    expect(api.encrypts.single.bytes.every((b) => b == 0), isTrue); // …puis mis à zéro par l'écran
    await tester.tap(find.text('rapport.pdf.age'));
    await tester.pumpAndSettle();
    await typePassword(tester, goodPass, confirm: false);
    await tester.tap(find.text(Fr.openDecrypted));
    await tester.pumpAndSettle();
    expect(api.passwordBuffers.isNotEmpty, isTrue);
    expect(api.passwordBuffers.every((b) => b.every((x) => x == 0)), isTrue);
  });

  testWidgets('lockIconOnEncryptedFiles', (tester) async {
    await pump(tester, api0());
    final age = find.ancestor(of: find.text('rapport.pdf.age'), matching: find.byType(ListTile));
    expect(find.descendant(of: age, matching: find.byIcon(Icons.lock_rounded)), findsOneWidget);
    final plain = find.ancestor(of: find.text('b.txt'), matching: find.byType(ListTile));
    expect(find.descendant(of: plain, matching: find.byIcon(Icons.lock_rounded)), findsNothing);
  });

  testWidgets('changePasswordFromMenu', (tester) async {
    final api = api0();
    await pump(tester, api);
    await itemAction(tester, 'rapport.pdf.age', Fr.changePasswordAction);
    await tester.enterText(find.widgetWithText(TextField, Fr.currentPassword), 'mauvais mot');
    await tester.enterText(find.widgetWithText(TextField, Fr.password), 'nouveau mot de passe');
    await tester.enterText(find.widgetWithText(TextField, Fr.passwordConfirm), 'nouveau mot de passe');
    await tester.pump();
    await tapVisible(tester, find.widgetWithText(FilledButton, Fr.changeButton));
    expect(find.text(Fr.badPassword), findsOneWidget); // reste ouvert
    await tester.enterText(find.widgetWithText(TextField, Fr.currentPassword), goodPass);
    await tester.pump();
    await tapVisible(tester, find.widgetWithText(FilledButton, Fr.changeButton));
    expect(api.changedPasswords.last, ('phone', '/rapport.pdf.age', goodPass, 'nouveau mot de passe'));
    expect(find.text(Fr.passwordChanged), findsOneWidget);
  });

  testWidgets('decryptedShareAsksConfirmation', (tester) async {
    final api = api0()..dirs['phone']!['/']!.add(f('/photo.png.age'));
    api.encryptedInfos['/photo.png.age'] = EncryptedInfoMsg(format: 'age', folder: false);
    await pump(tester, api);
    await tester.tap(find.text('photo.png.age'));
    await tester.pumpAndSettle();
    await typePassword(tester, goodPass, confirm: false);
    await tester.tap(find.text(Fr.openDecrypted));
    await tester.pumpAndSettle();
    expect(api.calls, contains('readImage dec:1 /photo.png')); // visionneuse de Portail, sur la vue déchiffrée
    await tester.tap(find.byTooltip(Fr.share));
    await tester.pumpAndSettle();
    expect(find.text(Fr.sharePlainBody), findsOneWidget);
    await tester.tap(find.text(Fr.cancel));
    await tester.pumpAndSettle();
    expect(api.calls.where((c) => c.startsWith('share')), isEmpty);
    await tester.tap(find.byTooltip(Fr.share));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, Fr.share));
    await tester.pumpAndSettle();
    expect(api.calls, contains('share dec:1 /photo.png'));
    // quitter la visionneuse ferme la vue déchiffrée
    await tester.tap(find.byTooltip('Retour'));
    await tester.pumpAndSettle();
    expect(api.closedDecrypted, ['dec:1']);
  });

  test('transferLinesForCrypt', () {
    expect(Fr.transferLine('encrypt', 'a.txt', 1, 2, 50), 'Chiffrement de a.txt — 1 sur 2 · 50 %');
    expect(Fr.transferLine('decrypt', 'a.txt', 1, 1, 50), 'Déchiffrement de a.txt — 1 sur 1 · 50 %');
    expect(Fr.transferLine('verify', 'a.txt', 1, 1, 50), 'Vérification de a.txt — 1 sur 1 · 50 %');
    expect(utf8.encode(goodPass).length, goodPass.length);
  });
}

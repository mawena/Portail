import 'dart:convert';
import 'dart:typed_data';

import 'package:fluluks/src/crypto/password_generator.dart';
import 'package:fluluks/src/strings_fr.dart';
import 'package:fluluks/src/widgets/password_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late TextEditingController pass;
  late TextEditingController confirm;
  late List<bool> validity;
  late List<String> generated;
  late List<Uint8List> copied;

  setUp(() {
    pass = TextEditingController();
    confirm = TextEditingController();
    validity = [];
    generated = [];
    copied = [];
  });

  Future<void> pump(WidgetTester tester, {bool withConfirm = true, bool strength = false, bool generate = false}) async {
    await tester.runAsync(loadEffWords); // ressource lue pour de vrai : chargée hors du temps simulé
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: PasswordField(
            controller: pass,
            confirm: withConfirm ? confirm : null,
            showStrength: strength,
            allowGenerate: generate,
            onValidChanged: validity.add,
            onGenerated: generated.add,
            copySecret: (b) async => copied.add(Uint8List.fromList(b)),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Finder field(String label) => find.widgetWithText(TextField, label);

  testWidgets('confirmMismatchBlocks', (tester) async {
    await pump(tester);
    expect(find.text(Fr.passwordNoRecovery), findsOneWidget); // avertissement permanent à la création
    await tester.enterText(field(Fr.password), 'abcdefgh1');
    await tester.enterText(field(Fr.passwordConfirm), 'abcdefgh2');
    await tester.pump();
    expect(find.text(Fr.passwordMismatch), findsOneWidget);
    expect(validity.last, isFalse);
    await tester.enterText(field(Fr.passwordConfirm), 'abcdefgh1');
    await tester.pump();
    expect(find.text(Fr.passwordMismatch), findsNothing);
    expect(validity.last, isTrue);
    expect(PasswordField.problem('abcdefgh1', 'abcdefgh1'), isNull);
    expect(PasswordField.problem('abcdefgh1', 'x'), Fr.passwordMismatch);
  });

  testWidgets('under8Blocks', (tester) async {
    await pump(tester);
    await tester.enterText(field(Fr.password), 'abc1234');
    await tester.enterText(field(Fr.passwordConfirm), 'abc1234');
    await tester.pump();
    expect(find.text(Fr.passwordTooShort), findsOneWidget);
    expect(validity.last, isFalse);
    // 8 caractères (et non 8 octets) : les lettres accentuées comptent pour un
    expect(PasswordField.problem('éééééééé', 'éééééééé'), isNull);
    expect(PasswordField.problem('abc\u0000defgh', 'abc\u0000defgh'), Fr.passwordNul);
    expect(PasswordField.problem('', ''), Fr.passwordTooShort);
  });

  testWidgets('generateFillsBothFields', (tester) async {
    await pump(tester, generate: true);
    await tester.tap(find.byTooltip(Fr.generatePassword));
    await tester.pumpAndSettle();
    await tester.tap(find.text(Fr.generateChars));
    await tester.pumpAndSettle();
    expect(pass.text.length, 20);
    expect(confirm.text, pass.text);
    expect(generated, [pass.text]);
    expect(validity.last, isTrue);
    expect(find.text(pass.text), findsWidgets); // affiché, pour pouvoir le noter

    await tester.tap(find.byTooltip(Fr.generatePassword));
    await tester.pumpAndSettle();
    await tester.tap(find.text(Fr.generateWords));
    await tester.pumpAndSettle();
    expect(pass.text.split('-').length, 6);
    expect(confirm.text, pass.text);
  });

  testWidgets('copySecretSendsBytes', (tester) async {
    await pump(tester, generate: true);
    await tester.tap(find.byTooltip(Fr.generatePassword));
    await tester.pumpAndSettle();
    await tester.tap(find.text(Fr.generateChars));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(Fr.copyPassword));
    await tester.pumpAndSettle();
    expect(copied.length, 1);
    expect(utf8.decode(copied.single), pass.text);
    expect(find.text(Fr.passwordCopied), findsOneWidget);
  });

  testWidgets('strengthAnnouncedToTalkBack', (tester) async {
    final h = tester.ensureSemantics();
    await pump(tester, strength: true);
    await tester.enterText(field(Fr.password), 'Kx7#mQ2vLp');
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel(Fr.strength(Fr.strengthGood)), findsOneWidget);
    await tester.enterText(field(Fr.password), 'motdepasse');
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel(Fr.strength(Fr.strengthVeryWeak)), findsOneWidget);
    h.dispose();
  });

  testWidgets('fieldClearedOnDispose', (tester) async {
    await pump(tester, generate: true);
    await tester.enterText(field(Fr.password), 'secret-de-test');
    await tester.enterText(field(Fr.passwordConfirm), 'secret-de-test');
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    expect(pass.text, isEmpty);
    expect(confirm.text, isEmpty);
  });

  testWidgets('unlockModeHasNoRules', (tester) async {
    await pump(tester, withConfirm: false);
    expect(find.text(Fr.passwordNoRecovery), findsNothing);
    expect(find.byTooltip(Fr.generatePassword), findsNothing);
    await tester.enterText(field(Fr.password), 'abc');
    await tester.pump();
    expect(find.text(Fr.passwordTooShort), findsNothing); // phrase LUKS existante : aucune règle
  });
}

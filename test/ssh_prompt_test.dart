import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluluks/src/bridge/fluluks_api.g.dart';
import 'package:fluluks/src/strings_fr.dart';

import 'remote_test.dart' show api0, pump;

/// Phase 13, T1 : invites keyboard-interactive d'un serveur SSH posées à l'utilisateur, réponses en octets.
void main() {
  SshPromptMsg prompt(String id, {bool echo = false}) => SshPromptMsg(
        requestId: id,
        name: 'portail@mawena.cloud',
        instruction: 'Double facteur',
        prompts: ['Verification code: '],
        echo: [echo],
      );

  testWidgets('promptDialogSendsBytesAndCancels', (tester) async {
    final api = api0();
    final state = await pump(tester, api);
    state.onSshPrompt(prompt('r1'));
    await tester.pumpAndSettle();
    expect(find.text('Double facteur'), findsOneWidget);
    expect(find.textContaining('Verification code'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).obscureText, isTrue); // sans écho : masqué
    await tester.enterText(find.byType(TextField), '123456');
    await tester.tap(find.text(Fr.sendAnswer));
    await tester.pumpAndSettle();
    expect(api.promptAnswers.single.$1, 'r1');
    expect(api.promptAnswers.single.$2, ['123456']);

    state.onSshPrompt(prompt('r2', echo: true));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).obscureText, isFalse);
    await tester.tap(find.text(Fr.cancel));
    await tester.pumpAndSettle();
    expect(api.promptAnswers.last.$1, 'r2');
    expect(api.promptAnswers.last.$2, isNull);
  });
}

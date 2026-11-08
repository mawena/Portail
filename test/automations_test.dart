import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluluks/src/ai/ai_servers_screen.dart';
import 'package:fluluks/src/ai/automation_form.dart';
import 'package:fluluks/src/ai/automation_runs_screen.dart';
import 'package:fluluks/src/ai/automations_screen.dart';
import 'package:fluluks/src/app.dart';
import 'package:fluluks/src/bridge/fluluks_api.g.dart';
import 'package:fluluks/src/state/app_state.dart';
import 'package:fluluks/src/strings_fr.dart';
import 'package:fluluks/src/ui/root.dart';

import 'fake_ai_api.dart';
import 'fake_host_api.dart';

/// Phase 15, T9 : écrans des automatisations (liste, fiche et historique, formulaire, exécution suivie en direct).
void main() {
  /// Une seconde par pas de 100 ms : l'indicateur d'une exécution en cours tourne sans fin.
  Future<void> settle(WidgetTester t) async {
    for (var i = 0; i < 10; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  Future<AppState> pumpPage(WidgetTester t, FakeHostApi api, Widget Function(AppState)? page) async {
    final state = AppState(api);
    await state.loadUiPrefs();
    await state.refresh();
    await t.pumpWidget(const SizedBox.shrink());
    await t.pumpWidget(PortailRoot(state: state, builder: (_) => FluLuksApp(state: state)));
    await settle(t);
    if (page != null) {
      t.state<NavigatorState>(find.byType(Navigator).first).push(MaterialPageRoute<void>(builder: (_) => page(state)));
      await settle(t);
    }
    return state;
  }

  FakeHostApi withServer() => FakeHostApi()
    ..aiServerList.add(aiServer('a1', 'Atelier', 'https://atelier.mawena.cloud', isDefault: true, model: 'essai-court'));

  /// « Météo » (variable ville, défaut Lomé), à la demande.
  Future<FakeHostApi> withAutomation({String template = 'Météo à {{ville}} le {{date}}', String trigger = 'manual'}) async {
    final api = withServer();
    await api.saveAutomation(AutomationMsg(
      id: 0,
      name: 'Météo',
      template: template,
      variables: [AutomationVarMsg(name: 'ville', defaultValue: 'Lomé')],
      serverId: 'a1',
      model: 'essai-court',
      trigger: trigger,
      intervalMinutes: trigger == 'periodic' ? 60 : null,
      enabled: true,
    ));
    api.aiCalls.clear();
    return api;
  }

  Future<void> scrollTo(WidgetTester t, Finder f) async {
    await t.scrollUntilVisible(f, 200, scrollable: find.byType(Scrollable).first);
    await settle(t);
  }

  String allText(WidgetTester t) =>
      t.widgetList<RichText>(find.byType(RichText)).map((r) => r.text.toPlainText()).join('\n');

  testWidgets('aiModuleOpensAutomations', (t) async {
    await pumpPage(t, withServer(), null);
    // 800 dp de large : le rail des modules
    await t.tap(find.descendant(of: find.byType(NavigationRail), matching: find.text(Fr.moduleAi)));
    await settle(t);
    await t.tap(find.text(Fr.automations));
    await settle(t);
    expect(find.byType(AutomationsScreen), findsOneWidget);
  });

  testWidgets('noServerLeadsToAiServers', (t) async {
    await pumpPage(t, FakeHostApi(), (s) => AutomationsScreen(state: s));
    expect(find.text(Fr.automationNoServersBody), findsOneWidget);
    await t.tap(find.widgetWithText(FilledButton, Fr.aiServers));
    await settle(t);
    expect(find.byType(AiServersScreen), findsOneWidget);
  });

  testWidgets('createManualWithDetectedVariables', (t) async {
    final api = withServer();
    await pumpPage(t, api, (s) => AutomationsScreen(state: s));
    expect(find.text(Fr.automationNoneTitle), findsOneWidget);
    await t.tap(find.text(Fr.automationNew));
    await settle(t);
    expect(find.byType(AutomationForm), findsOneWidget);
    expect(find.text('Atelier · essai-court'), findsOneWidget); // serveur et modèle par défaut
    await t.enterText(find.widgetWithText(TextFormField, Fr.automationName), 'Météo');
    await t.enterText(find.widgetWithText(TextFormField, Fr.automationTemplate), 'Météo à {{ville}} le {{date}}');
    await settle(t);
    final field = find.widgetWithText(TextFormField, Fr.automationDefaultFor('ville'));
    expect(field, findsOneWidget);
    expect(find.widgetWithText(TextFormField, Fr.automationDefaultFor('date')), findsNothing, reason: 'fournie');
    await t.enterText(field, 'Lomé');
    await scrollTo(t, find.text(Fr.save));
    await t.tap(find.text(Fr.save));
    await settle(t);
    expect(api.aiCalls, contains('saveAutomation 0 Météo manual null'));
    expect(api.automationList.single.variables.single.defaultValue, 'Lomé');
    expect(find.byType(AutomationForm), findsNothing);
    expect(find.text('Météo'), findsOneWidget);
  });

  testWidgets('createPeriodicWithInterval', (t) async {
    final api = withServer();
    await pumpPage(t, api, (s) => AutomationForm(state: s));
    await t.enterText(find.widgetWithText(TextFormField, Fr.automationName), 'Résumé');
    await t.enterText(find.widgetWithText(TextFormField, Fr.automationTemplate), 'Résume les nouvelles du {{date}}');
    await scrollTo(t, find.text(Fr.automationPeriodic));
    await t.tap(find.text(Fr.automationPeriodic));
    await settle(t);
    await scrollTo(t, find.text(Fr.automationInterval(15)));
    await t.tap(find.text(Fr.automationInterval(15)));
    await settle(t);
    await t.tap(find.text(Fr.automationInterval(60)).last);
    await settle(t);
    await scrollTo(t, find.text(Fr.save));
    await t.tap(find.text(Fr.save));
    await settle(t);
    expect(api.aiCalls, contains('saveAutomation 0 Résumé periodic 60'));
  });

  testWidgets('saveErrorShownAndFormKept', (t) async {
    final api = withServer()
      ..automationSaveError = PlatformException(code: '-13', message: '20 automatisations au plus');
    await pumpPage(t, api, (s) => AutomationForm(state: s));
    await t.enterText(find.widgetWithText(TextFormField, Fr.automationName), 'Une de trop');
    await t.enterText(find.widgetWithText(TextFormField, Fr.automationTemplate), 'Bonjour');
    await scrollTo(t, find.text(Fr.save));
    await t.tap(find.text(Fr.save));
    await settle(t);
    expect(find.text('20 automatisations au plus'), findsOneWidget);
    expect(find.byType(AutomationForm), findsOneWidget);
  });

  testWidgets('nameAndTemplateRequired', (t) async {
    final api = withServer();
    await pumpPage(t, api, (s) => AutomationForm(state: s));
    await scrollTo(t, find.text(Fr.save));
    await t.tap(find.text(Fr.save));
    await settle(t);
    expect(api.aiCalls.where((c) => c.startsWith('saveAutomation')), isEmpty);
    await t.scrollUntilVisible(find.text(Fr.automationNameRequired), -200, scrollable: find.byType(Scrollable).first);
    expect(find.text(Fr.automationNameRequired), findsOneWidget); // en haut du formulaire
  });

  testWidgets('enableSwitchOnPeriodic', (t) async {
    final api = await withAutomation(trigger: 'periodic');
    await pumpPage(t, api, (s) => AutomationsScreen(state: s));
    await t.tap(find.byType(Switch));
    await settle(t);
    expect(api.aiCalls, contains('setAutomationEnabled 1 false'));
  });

  testWidgets('editDuplicateDeleteFromDetail', (t) async {
    final api = await withAutomation();
    await pumpPage(t, api, (s) => AutomationsScreen(state: s));
    await t.tap(find.text('Météo'));
    await settle(t);
    expect(find.byType(AutomationRunsScreen), findsOneWidget);

    await t.tap(find.byTooltip(Fr.automationEdit));
    await settle(t);
    expect(find.byType(AutomationForm), findsOneWidget);
    expect(find.widgetWithText(TextFormField, Fr.automationDefaultFor('ville')), findsOneWidget);
    await t.enterText(find.widgetWithText(TextFormField, Fr.automationName), 'Météo du jour');
    await scrollTo(t, find.text(Fr.save));
    await t.tap(find.text(Fr.save));
    await settle(t);
    expect(api.aiCalls, contains('saveAutomation 1 Météo du jour manual null'));
    expect(find.text('Météo du jour'), findsWidgets);

    await t.tap(find.byTooltip(Fr.moreOptions));
    await settle(t);
    await t.tap(find.text(Fr.automationDuplicate));
    await settle(t);
    expect(api.aiCalls, contains('duplicateAutomation 1'));

    await t.tap(find.byTooltip(Fr.moreOptions));
    await settle(t);
    await t.tap(find.text(Fr.delete));
    await settle(t);
    expect(find.text(Fr.automationDeleteTitle), findsOneWidget);
    await t.tap(find.widgetWithText(FilledButton, Fr.delete));
    await settle(t);
    expect(api.aiCalls, contains('deleteAutomation 1'));
    expect(find.byType(AutomationRunsScreen), findsNothing);
    expect(find.text('Météo du jour (copie)'), findsOneWidget);
  });

  testWidgets('runAsksVariablesStreamsCopiesAndShares', (t) async {
    final api = await withAutomation();
    String? copied;
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
    addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final state = await pumpPage(t, api, (s) => AutomationRunsScreen(state: s, automationId: 1));
    await t.tap(find.widgetWithText(FilledButton, Fr.automationRun));
    await settle(t);
    final field = find.widgetWithText(TextField, 'ville');
    expect(t.widget<TextField>(field).controller!.text, 'Lomé'); // valeur par défaut proposée
    await t.enterText(field, 'Kara');
    await t.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text(Fr.automationRun)));
    await settle(t);
    expect(api.aiCalls, contains('runAutomation 1 ville=Kara'));
    expect(find.byTooltip(Fr.chatStop), findsOneWidget);
    expect(find.text('Météo à Kara le {{date}}'), findsOneWidget); // prompt envoyé (le faux pont ne remplit pas la date)

    state.automations.onRunDelta(1, 'Il fait **beau**');
    await settle(t);
    expect(allText(t), contains('Il fait beau'));

    state.automations.onRunState(api.finishFakeRun(1, 'Il fait **beau** à Kara.'));
    await settle(t);
    expect(find.byTooltip(Fr.chatStop), findsNothing);
    expect(allText(t), contains('Il fait beau à Kara.'));
    await t.tap(find.byTooltip(Fr.automationCopyResult));
    await t.pump();
    expect(copied, 'Il fait **beau** à Kara.');
    await settle(t);
    await t.tap(find.byTooltip(Fr.automationShareResult));
    await settle(t);
    expect(api.sharedTexts, ['Il fait **beau** à Kara.']);
  });

  testWidgets('runWithoutVariablesStartsAtOnceAndStops', (t) async {
    final api = await withAutomation(template: 'Une blague, vite');
    await pumpPage(t, api, (s) => AutomationRunsScreen(state: s, automationId: 1));
    await t.tap(find.widgetWithText(FilledButton, Fr.automationRun));
    await settle(t);
    expect(find.byType(AlertDialog), findsNothing);
    expect(api.aiCalls, contains('runAutomation 1 '));
    await t.tap(find.byTooltip(Fr.chatStop));
    await settle(t);
    expect(api.aiCalls, contains('stopAutomationRun 1'));
  });

  testWidgets('historyShowsRunsDetailAndClears', (t) async {
    final api = await withAutomation();
    await api.runAutomation(1, const {});
    api.finishFakeRun(1, 'Ensoleillé', scheduled: true);
    await api.runAutomation(1, const {});
    api.finishFakeRun(2, null, state: 'failed', error: 'Le serveur ne répond pas', errorDetail: 'Connection refused');
    api.aiCalls.clear();
    await pumpPage(t, api, (s) => AutomationRunsScreen(state: s, automationId: 1));
    expect(find.text(Fr.automationRunState('done')), findsWidgets);
    expect(find.text(Fr.automationRunState('failed')), findsWidgets);

    await t.tap(find.text(Fr.automationRunState('failed')).last);
    await settle(t);
    expect(find.text('Le serveur ne répond pas'), findsOneWidget);
    expect(find.text('Connection refused'), findsOneWidget);
    t.state<NavigatorState>(find.byType(Navigator).first).pop();
    await settle(t);

    await t.tap(find.byTooltip(Fr.moreOptions));
    await settle(t);
    await t.tap(find.text(Fr.automationClearHistory));
    await settle(t);
    await t.tap(find.widgetWithText(FilledButton, Fr.automationClearHistory));
    await settle(t);
    expect(api.aiCalls, contains('clearAutomationRuns 1'));
    expect(find.text(Fr.automationNoRuns), findsOneWidget);
  });
}

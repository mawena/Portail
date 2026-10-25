import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluluks/src/ai/ai_server_form.dart';
import 'package:fluluks/src/ai/ai_servers_screen.dart';
import 'package:fluluks/src/ai/ai_status_dot.dart';
import 'package:fluluks/src/app.dart';
import 'package:fluluks/src/bridge/fluluks_api.g.dart';
import 'package:fluluks/src/screens/settings_screen.dart';
import 'package:fluluks/src/state/app_state.dart';
import 'package:fluluks/src/strings_fr.dart';
import 'package:fluluks/src/ui/root.dart';
import 'package:fluluks/src/widgets/connection_details_sheet.dart';

import 'fake_ai_api.dart';
import 'fake_host_api.dart';

/// Phase 15, T4 : écrans des serveurs IA.
void main() {
  Future<AppState> pumpPage(WidgetTester t, FakeHostApi api, Widget Function(AppState) page) async {
    final state = AppState(api);
    await state.loadUiPrefs();
    await state.refresh();
    await t.pumpWidget(const SizedBox.shrink()); // arbre neuf : rien ne reste d'un écran précédent
    await t.pumpWidget(PortailRoot(state: state, builder: (_) => FluLuksApp(state: state)));
    await t.pumpAndSettle();
    t.state<NavigatorState>(find.byType(Navigator).first).push(MaterialPageRoute<void>(builder: (_) => page(state)));
    await t.pumpAndSettle();
    return state;
  }

  FakeHostApi withServers() => FakeHostApi()
    ..aiServerList.addAll([
      aiServer('a1', 'Atelier', 'https://atelier.mawena.cloud', isDefault: true, model: 'essai-court'),
      aiServer('a2', 'PC du salon', 'http://192.168.0.20:11434', hasKey: false),
    ]);

  Future<void> scrollTo(WidgetTester t, Finder f) async {
    await t.scrollUntilVisible(f, 200, scrollable: find.byType(Scrollable).first);
    await t.pumpAndSettle();
  }

  testWidgets('settingsOpensAiServers', (t) async {
    await pumpPage(t, FakeHostApi(), (s) => SettingsScreen(state: s));
    await scrollTo(t, find.text(Fr.aiServers));
    await t.tap(find.text(Fr.aiServers));
    await t.pumpAndSettle();
    expect(find.byType(AiServersScreen), findsOneWidget);
  });

  testWidgets('emptyStateLeadsToAdd', (t) async {
    await pumpPage(t, FakeHostApi(), (s) => AiServersScreen(state: s));
    expect(find.text(Fr.aiNoServers), findsOneWidget);
    expect(find.text(Fr.aiNoServersBody), findsOneWidget);
    await t.tap(find.text(Fr.aiAddServer).first);
    await t.pumpAndSettle();
    expect(find.byType(AiServerForm), findsOneWidget);
  });

  testWidgets('addServerSavesAndZeroesKey', (t) async {
    final api = FakeHostApi();
    await pumpPage(t, api, (s) => AiServerForm(state: s));
    await t.enterText(find.widgetWithText(TextFormField, Fr.aiServerName), 'Atelier');
    await t.enterText(find.widgetWithText(TextFormField, Fr.aiServerUrl), 'https://atelier.mawena.cloud');
    await t.enterText(find.widgetWithText(TextFormField, Fr.aiApiKey), 'cle-secrete');
    await t.tap(find.text(Fr.save));
    await t.pumpAndSettle();
    expect(api.aiCalls, contains('saveAiServer  Atelier https://atelier.mawena.cloud clé'));
    expect(api.aiKeyCopy, 'cle-secrete');
    expect(api.aiKeyRef!.every((b) => b == 0), isTrue, reason: 'clé mise à zéro après l’appel');
    expect(find.byType(AiServerForm), findsNothing);
  });

  testWidgets('urlRequiredAndSaveErrorShown', (t) async {
    final api = FakeHostApi()..aiSaveError = PlatformException(code: '-22', message: 'Un serveur IA porte déjà ce nom');
    await pumpPage(t, api, (s) => AiServerForm(state: s));
    await t.tap(find.text(Fr.save));
    await t.pumpAndSettle();
    expect(find.text(Fr.aiUrlRequired), findsOneWidget);
    expect(api.aiCalls, isEmpty);
    await t.enterText(find.widgetWithText(TextFormField, Fr.aiServerUrl), 'atelier.mawena.cloud');
    await t.tap(find.text(Fr.save));
    await t.pumpAndSettle();
    expect(find.text(Fr.aiUrlScheme), findsOneWidget);
    await t.enterText(find.widgetWithText(TextFormField, Fr.aiServerUrl), 'https://atelier.mawena.cloud');
    await t.tap(find.text(Fr.save));
    await t.pumpAndSettle();
    expect(find.text('Un serveur IA porte déjà ce nom'), findsOneWidget);
    expect(find.byType(AiServerForm), findsOneWidget);
  });

  testWidgets('clearTextWarningOnlyForPublicHttp', (t) async {
    await pumpPage(t, FakeHostApi(), (s) => AiServerForm(state: s));
    final url = find.widgetWithText(TextFormField, Fr.aiServerUrl);
    for (final (u, warn) in [
      ('http://example.com', true),
      ('http://203.0.113.5:8080', true),
      ('http://192.168.0.20:11434', false),
      ('http://10.1.2.3', false),
      ('http://172.20.0.1', false),
      ('http://172.32.0.1', true),
      ('http://127.0.0.1:8765', false),
      ('http://localhost:8765', false),
      ('http://nas.local', false),
      ('https://example.com', false),
    ]) {
      await t.enterText(url, u);
      await t.pump();
      expect(find.text(Fr.aiClearTextWarning), warn ? findsOneWidget : findsNothing, reason: u);
    }
  });

  testWidgets('editKeepsKeyRemoveKeyAndDefault', (t) async {
    final api = withServers();
    await pumpPage(t, api, (s) => AiServerForm(state: s, server: api.aiServerList.first));
    expect(find.text(Fr.aiApiKeyKeep), findsOneWidget);
    await t.tap(find.text(Fr.save));
    await t.pumpAndSettle();
    expect(api.aiCalls, contains('saveAiServer a1 Atelier https://atelier.mawena.cloud sans clé'));

    await pumpPage(t, api, (s) => AiServerForm(state: s, server: api.aiServerList[0]));
    await scrollTo(t, find.text(Fr.aiRemoveKey));
    await t.tap(find.text(Fr.aiRemoveKey));
    await t.pumpAndSettle();
    expect(api.aiCalls, contains('removeAiServerKey a1'));
    expect(find.text(Fr.aiApiKeyKeep), findsNothing);

    await pumpPage(t, api, (s) => AiServerForm(state: s, server: api.aiServerList[1]));
    await scrollTo(t, find.text(Fr.aiDefaultServer));
    await t.tap(find.text(Fr.aiDefaultServer));
    await t.pumpAndSettle();
    expect(api.aiCalls, contains('setDefaultAiServer a2'));
  });

  testWidgets('deleteAsksConfirmation', (t) async {
    final api = withServers();
    await pumpPage(t, api, (s) => AiServerForm(state: s, server: api.aiServerList.first));
    await t.tap(find.byTooltip(Fr.aiDeleteServer));
    await t.pumpAndSettle();
    expect(find.text(Fr.aiDeleteServerBody('Atelier')), findsOneWidget);
    await t.tap(find.text(Fr.cancel));
    await t.pumpAndSettle();
    expect(api.aiCalls.where((c) => c.startsWith('delete')), isEmpty);
    await t.tap(find.byTooltip(Fr.aiDeleteServer));
    await t.pumpAndSettle();
    await t.tap(find.widgetWithText(FilledButton, Fr.delete));
    await t.pumpAndSettle();
    expect(api.aiCalls, contains('deleteAiServer a1'));
    expect(find.byType(AiServerForm), findsNothing);
  });

  testWidgets('testConnectionSuccessAndFailureWithDetails', (t) async {
    final api = withServers();
    await pumpPage(t, api, (s) => AiServerForm(state: s, server: api.aiServerList.first));
    await scrollTo(t, find.text(Fr.testConnection));
    await t.tap(find.text(Fr.testConnection));
    await t.pumpAndSettle();
    expect(find.text(Fr.aiConnectionOk('0.1.0', 2)), findsOneWidget);
    expect(Fr.aiConnectionOk('0.1.0', 2), 'Connexion réussie (version 0.1.0, 2 modèles)');
    expect(Fr.aiConnectionOk(null, 1), 'Connexion réussie (1 modèle)');

    api.aiTestResult = AiTestResultMsg(
      ok: false,
      models: [],
      log: ['10:00:00.000  GET /v1/models → 401 (20 ms, 80 car.)'],
      error: 'Clé API refusée : vérifiez la clé enregistrée pour ce serveur',
      detail: 'Authentication Error, No api key passed in.',
    );
    await t.tap(find.text(Fr.testConnection));
    await t.pumpAndSettle();
    expect(find.text('Clé API refusée : vérifiez la clé enregistrée pour ce serveur'), findsOneWidget);
    await t.tap(find.widgetWithText(SnackBarAction, Fr.details));
    await t.pumpAndSettle();
    expect(find.byType(ConnectionDetailsSheet), findsOneWidget);
    expect(find.textContaining('Authentication Error, No api key passed in.'), findsOneWidget);
    expect(find.textContaining('GET /v1/models → 401'), findsOneWidget);
  });

  testWidgets('modelsListedDefaultChosenEmptyExplained', (t) async {
    final api = withServers();
    await pumpPage(t, api, (s) => AiServerForm(state: s, server: api.aiServerList.first));
    expect(api.aiCalls, contains('aiModels a1'));
    await scrollTo(t, find.text('essai-long'));
    expect(find.text('essai-court'), findsOneWidget);
    await t.tap(find.text('essai-long'));
    await t.pumpAndSettle();
    expect(api.aiCalls, contains('setAiDefaultModel a1 essai-long'));
    expect(api.aiServerList.first.defaultModel, 'essai-long');

    api.aiModelsById['a2'] = [];
    await pumpPage(t, api, (s) => AiServerForm(state: s, server: api.aiServerList[1]));
    await scrollTo(t, find.text(Fr.aiNoModels));
    expect(find.text(Fr.aiNoModels), findsOneWidget);
  });

  testWidgets('statusReadableWithoutColor', (t) async {
    final api = withServers();
    api.aiServerList.add(aiServer('a3', 'Ancien', 'http://10.0.0.9:8000'));
    api.aiHealthById['a2'] = AiHealthMsg(serverId: 'a2', state: 'offline', error: 'Connexion refusée');
    api.aiHealthById['a3'] = AiHealthMsg(serverId: 'a3', state: 'key-refused');
    await pumpPage(t, api, (s) => AiServersScreen(state: s));
    expect(find.text(Fr.aiStatusOnline), findsOneWidget);
    expect(find.text(Fr.aiStatusOffline), findsOneWidget);
    expect(find.text(Fr.aiStatusKeyRefused), findsOneWidget);
    // chaque état a sa propre icône
    final icons = t.widgetList<AiStatusDot>(find.byType(AiStatusDot)).map((d) => AiStatusDot.iconFor(d.state)).toSet();
    expect(icons.length, 3);
    expect(AiStatusDot.iconFor('unknown'), isNot(isIn(icons)));
    expect(find.text('Atelier'), findsOneWidget);
    expect(find.text(Fr.aiDefaultBadge), findsOneWidget);
  });

  testWidgets('healthCheckedOnOpenThenEvery60sWhileShown', (t) async {
    final api = withServers();
    await pumpPage(t, api, (s) => AiServersScreen(state: s));
    int checks() => api.aiCalls.where((c) => c == 'aiHealth a1').length;
    expect(checks(), 1);
    await t.pump(const Duration(seconds: 59));
    expect(checks(), 1);
    await t.pump(const Duration(seconds: 2));
    await t.pumpAndSettle();
    expect(checks(), 2);
    t.state<NavigatorState>(find.byType(Navigator).first).pop();
    await t.pumpAndSettle();
    await t.pump(const Duration(seconds: 130));
    expect(checks(), 2, reason: 'plus de vérification une fois l’écran fermé');
  });
}

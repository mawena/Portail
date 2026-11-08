import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluluks/src/analyzer/analysis_exclusions_screen.dart';
import 'package:fluluks/src/analyzer/analyzer_home_screen.dart';
import 'package:fluluks/src/analyzer/analyzer_screen.dart';
import 'package:fluluks/src/app.dart';
import 'package:fluluks/src/bridge/fluluks_api.g.dart';
import 'package:fluluks/src/screens/explorer_screen.dart';
import 'package:fluluks/src/screens/module_shell.dart';
import 'package:fluluks/src/screens/settings_screen.dart';
import 'package:fluluks/src/state/app_state.dart';
import 'package:fluluks/src/strings_fr.dart';
import 'package:fluluks/src/ui/root.dart';
import 'package:fluluks/src/ui/states.dart';
import 'package:fluluks/src/ui/widgets.dart';

import 'demo_data.dart';
import 'fake_host_api.dart';

/// Phase 16, T10 : accueil de l'analyseur (module de la barre), points d'entrée, emplacements exclus ; plus rien de
/// l'analyse de l'espace de la phase 9.
void main() {
  Future<AppState> pump(WidgetTester t, FakeHostApi api, {Size size = const Size(412, 1400)}) async {
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    final state = AppState(api);
    await state.loadUiPrefs();
    await state.refresh();
    await t.pumpWidget(const SizedBox.shrink());
    await t.pumpWidget(PortailRoot(state: state, builder: (_) => FluLuksApp(state: state)));
    await t.pumpAndSettle();
    return state;
  }

  final bar = find.byType(NavigationBar);
  final home = find.byType(AnalyzerHomeScreen);

  ModuleShellState shell(WidgetTester t) => t.state<ModuleShellState>(find.byType(ModuleShell));

  Future<void> tapModule(WidgetTester t, String label) async {
    await t.tap(find.descendant(of: bar, matching: find.text(label)));
    await t.pumpAndSettle();
  }

  Future<void> back(WidgetTester t) async {
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
  }

  Future<void> tapIn(WidgetTester t, Finder scope, String text) async {
    final f = find.descendant(of: scope, matching: find.text(text));
    await t.ensureVisible(f.first);
    await t.pumpAndSettle();
    await t.tap(f.first);
    await t.pumpAndSettle();
  }

  Future<void> menu(WidgetTester t, String tooltip, String item) async {
    final m = find.byTooltip(tooltip);
    await t.ensureVisible(m.first);
    await t.pumpAndSettle();
    await t.tap(m.first);
    await t.pumpAndSettle();
    await t.tap(find.text(item).last);
    await t.pumpAndSettle();
  }

  AnalysisProgressMsg running(String sourceId, {String scanId = 'a1', double fraction = 0.4}) => AnalysisProgressMsg(
      scanId: scanId, sourceId: sourceId, path: '/', running: true, cancelled: false, files: 1200, dirs: 80,
      bytes: 3 << 30, usedBytes: 8 << 30, current: '/DCIM/Camera', inaccessible: 0, elapsedMs: 4000,
      fraction: fraction);

  /// Un coffre ouvert et un fichier déchiffré en mémoire, en plus des stockages de démonstration.
  FakeHostApi withVaultAndDecrypted(FakeHostApi api) => api
    ..sources = [
      ...api.sources,
      SourceMsg(id: 'vv1', stableKey: 'vault:a2', kind: 'vault', label: 'Coffre Photos', totalBytes: 1 << 30,
          freeBytes: 1 << 29, readOnly: false, roReason: '', encrypted: true),
      SourceMsg(id: 'dec:1', stableKey: 'dec:1', kind: 'decrypted', label: 'rapport.pdf', totalBytes: 1 << 20,
          freeBytes: 0, readOnly: true, roReason: '', encrypted: true),
    ];

  testWidgets('analyzerIsAModule', (t) async {
    await pump(t, demoApi());
    final labels = t.widgetList<NavigationDestination>(find.byType(NavigationDestination)).map((d) => d.label);
    expect(labels, [Fr.moduleFiles, Fr.moduleVaults, Fr.moduleAnalyzer, Fr.moduleRemote, Fr.moduleAi]);
    await tapModule(t, Fr.moduleAnalyzer);
    expect(shell(t).current, PortailModule.analyzer);
    expect(home, findsOneWidget);
    // lancée depuis une tuile de Fichiers : l'analyse s'ouvre dans le module Analyseur
    await tapModule(t, Fr.moduleFiles);
    await menu(t, Fr.sourceMenu('Téléphone'), Fr.analyzeStorage);
    expect(shell(t).current, PortailModule.analyzer);
    expect(find.byType(AnalyzerScreen), findsOneWidget);
    expect(bar.hitTestable(), findsOneWidget);
    // « Afficher dans l'explorateur » ramène au module Fichiers
    await t.longPress(find.byKey(const ValueKey('ligne-1')));
    await t.pumpAndSettle();
    await t.tap(find.text(Fr.showInExplorer));
    await t.pumpAndSettle();
    expect(shell(t).current, PortailModule.files);
    expect(t.widget<ExplorerScreen>(find.byType(ExplorerScreen)).path, '/DCIM');
  });

  testWidgets('listsLocationsWithUsage', (t) async {
    final api = withVaultAndDecrypted(demoApi());
    await pump(t, api);
    await tapModule(t, Fr.moduleAnalyzer);
    for (final l in ['Téléphone', 'Carte SD', 'Données', 'Coffre Photos']) {
      expect(find.descendant(of: home, matching: find.text(l)), findsOneWidget, reason: l);
    }
    // ni dossier distant ni fichier déchiffré : seulement par l'explorateur (distant) ou jamais (déchiffré)
    for (final l in ['Maison', 'rapport.pdf']) {
      expect(find.descendant(of: home, matching: find.text(l)), findsNothing, reason: l);
    }
    expect(find.descendant(of: home, matching: find.byType(UsageBar)), findsNWidgets(4));
    await tapIn(t, home, 'Carte SD');
    expect(find.byType(AnalyzerScreen), findsOneWidget);
    expect(api.calls, contains('startAnalysis sd:1 /'));
  });

  testWidgets('analyzeFolderUsesPicker', (t) async {
    final api = demoApi()..dirs['remote:s1'] = {'/': []};
    await pump(t, api);
    await tapModule(t, Fr.moduleAnalyzer);
    await tapIn(t, home, Fr.analyzeFolder);
    await t.tap(find.text('Téléphone').last);
    await t.pumpAndSettle();
    await t.tap(find.text('DCIM').last);
    await t.pumpAndSettle();
    await t.tap(find.text(Fr.pickHere));
    await t.pumpAndSettle();
    expect(api.calls, contains('startAnalysis phone /DCIM'));
    expect(find.byType(AnalyzerScreen), findsOneWidget);
    await back(t);
    // dossier distant : avertissement d'abord ; Annuler ne lance rien
    for (final go in [false, true]) {
      await tapIn(t, home, Fr.analyzeFolder);
      await t.tap(find.text('Maison').last);
      await t.pumpAndSettle();
      await t.tap(find.text(Fr.pickHere));
      await t.pumpAndSettle();
      expect(find.text(Fr.analysisRemoteWarning), findsOneWidget);
      await t.tap(find.text(go ? Fr.analyze : Fr.cancel));
      await t.pumpAndSettle();
      expect(api.calls.contains('startAnalysis remote:s1 /'), go);
    }
  });

  testWidgets('keptAnalysesListed', (t) async {
    final api = demoApi();
    api.analysisTrees['a7'] = demoAnalysisTree();
    await pump(t, api);
    await tapModule(t, Fr.moduleAnalyzer);
    final card = find.byKey(const ValueKey('analyse-a7'));
    expect(card, findsOneWidget);
    final bytes = api.analysisTrees['a7']!.first.alloc;
    expect(find.descendant(of: card, matching: find.textContaining(Fr.humanSize(bytes))), findsOneWidget);
    // toucher : rouvre l'analyse gardée
    await t.tap(card);
    await t.pumpAndSettle();
    expect(t.widget<AnalyzerScreen>(find.byType(AnalyzerScreen)).scanId, 'a7');
    await back(t);
    await menu(t, Fr.analysisMenu('Téléphone'), Fr.reanalyze);
    expect(api.calls, contains('startAnalysis phone /'));
    await back(t);
    await menu(t, Fr.analysisMenu('Téléphone'), Fr.forgetAnalysis);
    expect(api.calls, contains('forgetAnalysis a7'));
    expect(find.byKey(const ValueKey('analyse-a7')), findsNothing);
  });

  testWidgets('runningAnalysisCard', (t) async {
    final api = demoApi();
    api.analysisTrees['a1'] = demoAnalysisTree();
    final state = await pump(t, api);
    await tapModule(t, Fr.moduleAnalyzer);
    state.onAnalysisProgress(running('phone'));
    await t.pump();
    await t.pump();
    final card = find.byKey(const ValueKey('analyse-en-cours'));
    expect(card, findsOneWidget);
    expect(find.descendant(of: card, matching: find.text(Fr.analysisRunning)), findsOneWidget);
    final bar = t.widget<LinearProgressIndicator>(find.descendant(of: card, matching: find.byType(LinearProgressIndicator)));
    expect(bar.value, closeTo(0.4, 1e-9));
    // l'analyse gardée en cours n'est pas montrée deux fois
    expect(find.byKey(const ValueKey('analyse-a1')), findsNothing);
    await t.tap(card);
    await t.pump();
    await t.pump(const Duration(milliseconds: 600));
    expect(t.widget<AnalyzerScreen>(find.byType(AnalyzerScreen)).scanId, 'a1');
    state.onAnalysisProgress(null);
    await t.pumpAndSettle();
  });

  testWidgets('startWhileRunningAsks', (t) async {
    final api = demoApi();
    api.analysisTrees['a1'] = demoAnalysisTree();
    final state = await pump(t, api);
    await tapModule(t, Fr.moduleAnalyzer);
    state.onAnalysisProgress(running('phone'));
    await t.pump();
    for (final go in [false, true]) {
      await tapIn(t, home, 'Carte SD');
      expect(find.text(Fr.stopAnalysisTitle('Téléphone')), findsOneWidget);
      await t.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text(go ? Fr.analyze : Fr.cancel)));
      await t.pump();
      await t.pump(const Duration(milliseconds: 600));
      expect(api.calls.contains('startAnalysis sd:1 /'), go);
    }
    state.onAnalysisProgress(null);
    await t.pumpAndSettle();
  });

  testWidgets('entryPointsOpenAnalysis', (t) async {
    final api = withVaultAndDecrypted(demoApi())
      ..vaults = [
        VaultMsg(id: 'a2', name: 'Photos', sourceKey: 'phone', sourceLabel: 'Téléphone', path: '/Coffres/Photos.luks',
            sizeBytes: 1 << 30, fs: 'exfat', state: 'open', volumeId: 'vv1', hasRecovery: false, biometric: false,
            luksVersion: 2),
      ];
    await pump(t, api);
    // tuile de stockage, tuile de partition (Fichiers), tuile de coffre (Coffres)
    await menu(t, Fr.sourceMenu('Données'), Fr.analyzeStorage);
    expect(api.calls, contains('startAnalysis v1 /'));
    await tapModule(t, Fr.moduleVaults);
    await menu(t, Fr.sourceMenu('Photos'), Fr.analyzeStorage);
    expect(api.calls, contains('startAnalysis vv1 /'));
    expect(shell(t).current, PortailModule.analyzer);
    // explorateur, dans /DCIM : « Analyser ce dossier » ; à la racine : « Analyser le stockage »
    await tapModule(t, Fr.moduleFiles);
    await tapIn(t, find.byType(ModuleShell), 'Téléphone');
    await menu(t, Fr.sortBy, Fr.analyzeStorage);
    expect(api.calls.where((c) => c == 'startAnalysis phone /'), hasLength(1));
    await tapModule(t, Fr.moduleFiles);
    await t.tap(find.text('DCIM').first);
    await t.pumpAndSettle();
    await menu(t, Fr.sortBy, Fr.analyzeThisFolder);
    expect(api.calls, contains('startAnalysis phone /DCIM'));
  });

  testWidgets('remoteFolderWarnsFromExplorer', (t) async {
    final api = demoApi()..dirs['remote:s1'] = {'/home/charles': []};
    await pump(t, api);
    await tapModule(t, Fr.moduleRemote);
    await t.tap(find.text('Maison'));
    await t.pumpAndSettle();
    await menu(t, Fr.sortBy, Fr.analyzeThisFolder);
    expect(find.text(Fr.analysisRemoteWarning), findsOneWidget);
    await t.tap(find.text(Fr.analyze));
    await t.pumpAndSettle();
    expect(api.calls, contains('startAnalysis remote:s1 /home/charles'));
  });

  testWidgets('exclusionsListedAndRemovable', (t) async {
    final api = demoApi()
      ..analysisExclusionList.add(AnalysisExclusionMsg(stableKey: 'phone', sourceLabel: 'Téléphone', path: '/Android/media'));
    await pump(t, api);
    await t.tap(find.byTooltip(Fr.settings).hitTestable());
    await t.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
    await tapIn(t, find.byType(SettingsScreen), Fr.analysisExclusions);
    final screen = find.byType(AnalysisExclusionsScreen);
    expect(find.descendant(of: screen, matching: find.text('/Android/media')), findsOneWidget);
    expect(find.descendant(of: screen, matching: find.textContaining('Téléphone')), findsOneWidget);
    await t.tap(find.byTooltip(Fr.removeExclusion));
    await t.pumpAndSettle();
    expect(api.calls, contains('removeAnalysisExclusion phone /Android/media'));
    expect(find.descendant(of: screen, matching: find.byType(EmptyState)), findsOneWidget);
    expect(find.text(Fr.noAnalysisExclusions), findsOneWidget);
  });

  test('noOldSpaceApiLeft', () {
    final hits = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      final text = f.readAsStringSync();
      for (final w in ['analyzeSpace', 'spaceChildren', 'SpaceReportMsg', 'SpaceItemMsg', 'space_screen', 'SpaceScreen']) {
        if (text.contains(w)) hits.add('${f.path}: $w');
      }
    }
    expect(hits, isEmpty);
  });
}

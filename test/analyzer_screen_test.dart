import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluluks/src/analyzer/analysis_chart.dart';
import 'package:fluluks/src/analyzer/analysis_tree.dart';
import 'package:fluluks/src/analyzer/analyzer_controller.dart';
import 'package:fluluks/src/analyzer/analyzer_screen.dart';
import 'package:fluluks/src/bridge/fluluks_api.g.dart';
import 'package:fluluks/src/screens/explorer_screen.dart';
import 'package:fluluks/src/state/app_state.dart';
import 'package:fluluks/src/strings_fr.dart';
import 'package:fluluks/src/ui/theme.dart';

import 'demo_data.dart';
import 'fake_host_api.dart';

/// Écran d'une analyse (phase 16, T9) sur l'arbre de démonstration du téléphone.
void main() {
  late FakeHostApi api;
  late AppState state;

  setUp(() {
    api = FakeHostApi();
    state = AppState(api);
  });

  Future<void> show(WidgetTester t, {Size size = const Size(412, 869)}) async {
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      theme: portailTheme(Brightness.light),
      home: AnalyzerScreen(state: state, sourceId: 'phone'),
    ));
    await t.pumpAndSettle();
  }

  Finder row(int id) => find.byKey(ValueKey('ligne-$id'));
  final treeScroll = find.descendant(of: find.byType(AnalysisTree), matching: find.byType(Scrollable));

  /// Appui long sur la ligne [id], amenée à l'écran d'abord (l'arbre ne construit que ce qui se voit).
  Future<void> holdRow(WidgetTester t, int id) async {
    await t.scrollUntilVisible(row(id), 200, scrollable: treeScroll);
    await t.longPress(row(id));
    await t.pumpAndSettle();
  }

  /// Laisse passer le message du bas, qui couvrirait les lignes.
  Future<void> dismissMessage(WidgetTester t) async {
    await t.pump(const Duration(seconds: 5));
    await t.pumpAndSettle();
  }

  AnalyzerController ctrl(WidgetTester t) =>
      (t.state(find.byType(AnalyzerScreen)) as dynamic).c as AnalyzerController;

  AnalysisProgressMsg prog({required bool running, bool cancelled = false, int? used = 9000000000}) =>
      AnalysisProgressMsg(
          scanId: 'a1',
          sourceId: 'phone',
          path: '/',
          running: running,
          cancelled: cancelled,
          files: 12345,
          dirs: 300,
          bytes: 4200000000,
          usedBytes: used,
          current: '/DCIM/Camera',
          inaccessible: 0,
          elapsedMs: 4000,
          fraction: running ? 0.47 : 1);

  testWidgets('progressShownThenLiveResults', (t) async {
    await show(t);
    state.onAnalysisProgress(prog(running: true));
    await t.pump();
    final bar = t.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator).first);
    expect(bar.value, 0.47);
    expect(find.text('12345 fichiers · 4,2 Go'), findsOneWidget);
    expect(find.text('/DCIM/Camera'), findsOneWidget);
    state.onAnalysisProgress(prog(running: true, used: null)); // sans place de référence : indéterminée
    await t.pump();
    expect(t.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator).first).value, isNull);
    await t.tap(find.widgetWithText(TextButton, Fr.cancel));
    expect(api.calls, contains('cancelAnalysis'));
    state.onAnalysisProgress(prog(running: false, cancelled: true));
    await t.pumpAndSettle();
    expect(find.text(Fr.analysisPartial), findsOneWidget);
    await t.tap(find.widgetWithText(TextButton, Fr.reanalyze));
    await t.pumpAndSettle();
    expect(api.calls.where((c) => c == 'startAnalysis phone /').length, 2);
  });

  testWidgets('treeSortedBySizeWithColumns', (t) async {
    await show(t);
    final ys = [for (final id in [-1, 1, 6, 8]) t.getTopLeft(row(id)).dy];
    expect(ys, orderedEquals([...ys]..sort()));
    expect(find.descendant(of: row(1), matching: find.text('DCIM')), findsOneWidget);
    expect(find.descendant(of: row(1), matching: find.text('2,5 Go')), findsOneWidget);
    expect(find.descendant(of: row(1), matching: find.textContaining('4 éléments')), findsOneWidget);
    expect(find.descendant(of: row(1), matching: find.byType(LinearProgressIndicator)), findsOneWidget);
    expect(find.descendant(of: row(1), matching: find.textContaining(' %')), findsOneWidget);
  });

  testWidgets('expandRowLoadsChildrenPaged', (t) async {
    api.nextAnalysisTree = () {
      final tree = demoAnalysisTree();
      final d = tree.firstWhere((n) => n.id == 8)..hasChildren = true; // Download : 450 fichiers
      for (var i = 0; i < 450; i++) {
        tree.add(AnalysisNodeMsg(
            id: 100 + i, parent: 8, name: 'f$i', path: '/Download/f$i', kind: 'file', alloc: 1000 + i, apparent: 1000 + i,
            items: 0, mtime: 0, hasChildren: false, complete: true, depth: 2));
      }
      d.items += 450;
      return tree;
    };
    await show(t, size: const Size(412, 4000));
    await t.tap(find.descendant(of: row(8), matching: find.byTooltip(Fr.expand)));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('ligne-549')), findsOneWidget); // le plus gros d'abord
    expect(find.byKey(const ValueKey('ligne-349')), findsNothing);
    expect(api.calls, contains('analysisChildren a1 8 size 0'));
    await t.scrollUntilVisible(find.text(Fr.showMore), 500, scrollable: treeScroll);
    await t.tap(find.text(Fr.showMore));
    await t.pumpAndSettle();
    expect(api.calls, contains('analysisChildren a1 8 size 200'));
  });

  testWidgets('sortMenuChangesOrder', (t) async {
    await show(t);
    await t.tap(find.byKey(analyzerMenuKey));
    await t.pumpAndSettle();
    await t.tap(find.text(Fr.sortName).last);
    await t.pumpAndSettle();
    expect(api.calls, contains('analysisChildren a1 0 name 0'));
    expect(t.getTopLeft(row(14)).dy, lessThan(t.getTopLeft(row(1)).dy)); // Android avant DCIM
  });

  testWidgets('biggestFilesTab', (t) async {
    await show(t);
    await t.tap(find.text(Fr.biggestFiles));
    await t.pumpAndSettle();
    final first = find.byKey(const ValueKey('gros-/DCIM/Camera/VID_20251009.mp4'));
    expect(first, findsOneWidget);
    expect(find.descendant(of: first, matching: find.text('/DCIM/Camera')), findsOneWidget);
    expect(api.calls, contains('analysisBiggest a1 0'));
  });

  testWidgets('tapRowZoomsChartAndBreadcrumb', (t) async {
    await show(t);
    await t.tap(row(1));
    await t.pumpAndSettle();
    expect(ctrl(t).view!.root, 1);
    expect(t.widget<AnalysisChart>(find.byType(AnalysisChart)).view.root, 1);
    expect(find.widgetWithText(TextButton, 'Téléphone'), findsOneWidget);
    expect(row(2), findsOneWidget); // Camera, dans l'arbre de DCIM
    await t.tap(row(2));
    await t.pumpAndSettle();
    expect(ctrl(t).trail.map((n) => n.id), [0, 1, 2]);
    await t.tap(find.byTooltip(Fr.pickUp));
    await t.pumpAndSettle();
    expect(ctrl(t).view!.root, 1);
    await t.binding.handlePopRoute(); // Retour : remonte
    await t.pumpAndSettle();
    expect(ctrl(t).view!.root, 0);
    expect(find.byType(AnalyzerScreen), findsOneWidget);
  });

  testWidgets('depthButtonsBounded', (t) async {
    api.uiPrefs = UiPrefsMsg(theme: 'system', haptics: true, welcomeSeen: true, analyzerDepth: 8);
    await state.loadUiPrefs();
    await show(t);
    await t.tap(find.byKey(analyzerMenuKey));
    await t.pumpAndSettle();
    PopupMenuItem<dynamic> item(String label) =>
        t.widget<PopupMenuItem<dynamic>>(find.ancestor(of: find.text(label), matching: find.byWidgetPredicate((w) => w is PopupMenuItem)));
    expect(item(Fr.moreLevels).enabled, isFalse);
    expect(item(Fr.fewerLevels).enabled, isTrue);
    await t.tap(find.text(Fr.fewerLevels));
    await t.pumpAndSettle();
    expect(api.uiPrefs.analyzerDepth, 7);
  });

  testWidgets('chartToggleRingsTreemapHidden', (t) async {
    await show(t);
    expect(t.widget<AnalysisChart>(find.byType(AnalysisChart)).kind, ChartKind.rings);
    Future<void> pick(String label) async {
      await t.tap(find.byTooltip(Fr.chartChoice));
      await t.pumpAndSettle();
      await t.tap(find.text(label).last);
      await t.pumpAndSettle();
    }

    await pick(Fr.chartTreemap);
    expect(t.widget<AnalysisChart>(find.byType(AnalysisChart)).kind, ChartKind.treemap);
    await pick(Fr.chartNone);
    expect(find.byType(AnalysisChart), findsNothing);
    expect(find.byType(AnalysisTree), findsOneWidget);
    expect(api.uiPrefs.analyzerChart, 'none');
  });

  testWidgets('menuActions', (t) async {
    final copied = <String>[];
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
      return null;
    });
    addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    api.detailsByPath['/DCIM/Camera'] =
        DetailsMsg(name: 'Camera', path: '/DCIM/Camera', type: 'dir', size: 0, mtime: 1700000000, fs: 'ext4');
    api.folderSizes['/DCIM/Camera'] = FolderSizeMsg(size: 2411 << 20, files: 3, dirs: 0, truncated: false);
    await show(t);
    await t.tap(row(1));
    await t.pumpAndSettle();
    await holdRow(t, 2);
    for (final a in [Fr.showInExplorer, Fr.copyPath, Fr.properties, Fr.excludeFromAnalyses, Fr.delete]) {
      expect(find.text(a), findsOneWidget, reason: a);
    }
    await t.tap(find.text(Fr.copyPath));
    await t.pumpAndSettle();
    expect(copied, ['/DCIM/Camera']);
    expect(find.text(Fr.pathCopied), findsOneWidget);
    await dismissMessage(t);
    await holdRow(t, 2);
    await t.tap(find.text(Fr.properties));
    await t.pumpAndSettle();
    expect(api.calls, contains('details phone /DCIM/Camera'));
    await t.tapAt(const Offset(10, 10)); // ferme la feuille
    await t.pumpAndSettle();
    await holdRow(t, 2);
    await t.tap(find.text(Fr.excludeFromAnalyses));
    await t.pumpAndSettle();
    expect(api.calls, contains('analysisExclude a1 2'));
    await dismissMessage(t);
    await holdRow(t, 2);
    await t.tap(find.text(Fr.showInExplorer));
    await t.pumpAndSettle();
    expect(find.byType(ExplorerScreen), findsOneWidget);
  });

  testWidgets('deleteAsksConfirmationWithNameAndSize', (t) async {
    await show(t);
    await holdRow(t, 6);
    await t.tap(find.text(Fr.delete));
    await t.pumpAndSettle();
    expect(find.text('Supprimer « Movies » (1,9 Go) ?'), findsOneWidget);
    expect(find.text(Fr.deleteToTrashBody), findsOneWidget);
    expect(find.text(Fr.deletePermanently), findsOneWidget);
    await t.tap(find.widgetWithText(FilledButton, Fr.delete));
    await t.pumpAndSettle();
    expect(api.calls, contains('analysisDelete a1 6 false'));
    expect(find.text(Fr.trashedFromAnalysis), findsOneWidget);
    expect(find.text(Fr.openTrash), findsOneWidget);
    expect(row(6), findsNothing);
    await dismissMessage(t);
    // définitif
    await holdRow(t, 8);
    await t.tap(find.text(Fr.delete));
    await t.pumpAndSettle();
    await t.tap(find.text(Fr.deletePermanently));
    await t.pumpAndSettle();
    expect(api.calls, contains('analysisDelete a1 8 true'));
  });

  testWidgets('remoteDeleteIsPermanentOnly', (t) async {
    api.analysisSizeKind = 'apparent';
    await show(t);
    await holdRow(t, 6);
    await t.tap(find.text(Fr.delete));
    await t.pumpAndSettle();
    expect(find.text(Fr.deleteRemoteBody), findsOneWidget);
    expect(find.text(Fr.deletePermanently), findsNothing);
    await t.tap(find.widgetWithText(FilledButton, Fr.delete));
    await t.pumpAndSettle();
    expect(api.calls, contains('analysisDelete a1 6 true'));
  });

  testWidgets('rootAndPseudoNodesHaveNoDestructiveActions', (t) async {
    api.nextAnalysisTree = () => demoAnalysisTree()
      ..add(AnalysisNodeMsg(
          id: 16, parent: 0, name: '.Portail-corbeille', path: '/.Portail-corbeille', kind: 'trash', alloc: 5 << 20,
          apparent: 5 << 20, items: 3, mtime: 0, hasChildren: true, complete: true, depth: 1));
    await show(t);
    for (final id in [-1, -2]) { // de haut en bas : le défilement ne fait que descendre
      await holdRow(t, id);
      expect(find.text(Fr.delete), findsNothing);
      expect(find.text(Fr.excludeFromAnalyses), findsNothing);
      await t.tapAt(const Offset(10, 10));
      await t.pumpAndSettle();
    }
    await holdRow(t, 16);
    expect(find.text(Fr.openTrash), findsOneWidget);
    expect(find.text(Fr.delete), findsNothing);
    await t.tapAt(const Offset(10, 10));
    await t.pumpAndSettle();
    // la racine, depuis le centre des anneaux : appui long sans menu
    await t.longPressAt(t.getCenter(find.byKey(analysisChartPaintKey)));
    await t.pumpAndSettle();
    expect(find.text(Fr.delete), findsNothing);
  });

  testWidgets('inaccessibleExplained', (t) async {
    await show(t);
    await t.scrollUntilVisible(row(14), 200, scrollable: treeScroll);
    await t.tap(find.descendant(of: row(14), matching: find.byTooltip(Fr.expand)));
    await t.pumpAndSettle();
    await t.scrollUntilVisible(row(15), 200, scrollable: treeScroll);
    expect(find.descendant(of: row(15), matching: find.textContaining(Fr.analysisInaccessible)), findsOneWidget);
    await holdRow(t, 15);
    expect(find.textContaining(Fr.analysisInaccessible), findsWidgets);
    expect(find.text(Fr.delete), findsNothing);
  });

  testWidgets('remoteShowsApparentNotice', (t) async {
    api.analysisSizeKind = 'apparent';
    await show(t);
    expect(find.text(Fr.analysisRemoteNotice), findsOneWidget);
  });

  testWidgets('simplifiedBanner', (t) async {
    api.analysisSimplified = true;
    await show(t);
    expect(find.text(Fr.analysisSimplified), findsOneWidget);
  });

  testWidgets('wideLayoutSideBySide', (t) async {
    await show(t, size: const Size(1000, 700));
    final chart = t.getRect(find.byType(AnalysisChart));
    final tree = t.getRect(find.byType(AnalysisTree));
    expect(chart.right, lessThanOrEqualTo(tree.left + 1));
    expect((chart.top - tree.top).abs(), lessThan(100));
  });

  testWidgets('rowSemanticsComplete', (t) async {
    final h = t.ensureSemantics();
    await show(t);
    final node = t.getSemantics(row(1));
    expect(node.label, matches(RegExp(r'^DCIM, dossier, 2,5 Go, \d+ % de Téléphone, 4 éléments, modifié .+$'.replaceAll(' %', ' %'))));
    final actions = node.getSemanticsData().customSemanticsActionIds!
        .map((id) => CustomSemanticsAction.getAction(id)!.label)
        .toList();
    expect(actions, containsAll([Fr.expand, Fr.actions]));
    expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    h.dispose();
  });
}

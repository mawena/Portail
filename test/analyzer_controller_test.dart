import 'package:flutter_test/flutter_test.dart';
import 'package:fluluks/src/analyzer/analyzer_controller.dart';
import 'package:fluluks/src/bridge/fluluks_api.g.dart';
import 'package:fluluks/src/state/app_state.dart';
import 'package:fluluks/src/strings_fr.dart';

import 'fake_host_api.dart';

/// Contrôleur de l'écran d'analyse (phase 16, T6) sur le faux pont et l'arbre de démonstration.
void main() {
  late FakeHostApi api;
  late AppState state;

  setUp(() {
    api = FakeHostApi();
    state = AppState(api);
  });

  AnalysisProgressMsg prog(String id, {required bool running, int dirs = 1}) => AnalysisProgressMsg(
      scanId: id,
      sourceId: 'phone',
      path: '/',
      running: running,
      cancelled: false,
      files: dirs * 3,
      dirs: dirs,
      bytes: dirs * 4096,
      current: '/d$dirs',
      inaccessible: 0,
      elapsedMs: dirs * 100,
      fraction: running ? 0.5 : 1);

  int views() => api.calls.where((c) => c.startsWith('analysisView ')).length;

  testWidgets('startShowsLiveViewThrottled', (tester) async {
    final c = AnalyzerController(state);
    await c.start('phone', '/');
    expect(api.calls, contains('startAnalysis phone /'));
    expect(c.view!.root, 0);
    expect(c.trail.map((n) => n.id), [0]);
    final before = views();
    // un événement toutes les 100 ms pendant 2 s
    for (var i = 1; i <= 20; i++) {
      state.onAnalysisProgress(prog(c.scanId!, running: true, dirs: i));
      await tester.pump(const Duration(milliseconds: 100));
    }
    final during = views() - before;
    expect(during, inInclusiveRange(4, 5)); // 0, 500, 1 000, 1 500 (et 2 000) ms
    expect(c.running, isTrue);
    await tester.pump(const Duration(seconds: 1)); // dernier rechargement différé
    final settled = views();
    state.onAnalysisProgress(prog(c.scanId!, running: false, dirs: 21));
    await tester.pump();
    expect(views(), settled + 1); // une fois à la fin
    expect(c.running, isFalse);
    // une autre analyse n'est pas suivie
    state.onAnalysisProgress(prog('autre', running: true));
    await tester.pump(const Duration(seconds: 1));
    expect(views(), settled + 1);
    c.dispose();
  });

  testWidgets('zoomAndUpKeepTrail', (tester) async {
    final c = AnalyzerController(state);
    await c.start('phone', '/');
    await c.zoom(2); // Camera, deux niveaux plus bas : DCIM entre aussi dans le fil
    expect(c.trail.map((n) => n.name), ['', 'DCIM', 'Camera']);
    expect(c.view!.root, 2);
    expect(api.calls.last, startsWith('analysisView a1 2 '));
    await c.zoom(-2); // contenu résumé : rien
    await c.zoom(3); // un fichier : rien
    expect(c.trail.length, 3);
    await c.up();
    expect(c.trail.map((n) => n.name), ['', 'DCIM']);
    expect(c.view!.root, 1);
    await c.up();
    await c.up(); // déjà à la racine
    expect(c.trail.map((n) => n.id), [0]);
    c.dispose();
  });

  testWidgets('goToBreadcrumb', (tester) async {
    final c = AnalyzerController(state);
    await c.start('phone', '/');
    await c.zoom(2);
    c.select(3);
    await c.goTo(1);
    expect(c.trail.map((n) => n.name), ['', 'DCIM']);
    expect(c.selected, isNull);
    await c.goTo(0);
    expect(c.view!.root, 0);
    await c.goTo(5); // hors du fil : rien
    expect(c.trail.length, 1);
    c.dispose();
  });

  testWidgets('depthBounded2to8', (tester) async {
    final c = AnalyzerController(state);
    expect(c.depth, 4);
    await c.start('phone', '/');
    expect(api.calls.last, 'analysisView a1 0 4');
    await c.setDepth(12);
    expect(c.depth, 8);
    expect(api.uiPrefs.analyzerDepth, 8);
    expect(api.calls.last, 'analysisView a1 0 8');
    await c.setDepth(1);
    expect(c.depth, 2);
    expect(api.uiPrefs.analyzerDepth, 2);
    expect(c.view!.nodes.map((n) => n.depth).reduce((a, b) => a > b ? a : b), lessThanOrEqualTo(2));
    c.dispose();
  });

  testWidgets('chartKindRemembered', (tester) async {
    final c = AnalyzerController(state);
    expect(c.chart, ChartKind.rings);
    await c.setChart(ChartKind.treemap);
    expect(api.uiPrefs.analyzerChart, 'treemap');
    expect(AnalyzerController(state).chart, ChartKind.treemap);
    await c.setChart(ChartKind.none);
    expect(c.chart, ChartKind.none);
    c.dispose();
  });

  testWidgets('deleteRefreshesView', (tester) async {
    final c = AnalyzerController(state);
    await c.start('phone', '/');
    final total = c.view!.nodes.first.alloc;
    final video = c.view!.nodes.firstWhere((n) => n.id == 3);
    c.select(3);
    await c.delete(3, permanent: true);
    expect(api.calls, contains('analysisDelete a1 3 true'));
    expect(c.view!.nodes.first.alloc, total - video.alloc);
    expect(c.view!.nodes.any((n) => n.id == 3), isFalse);
    expect(c.selected, isNull);
    await c.exclude(6);
    expect(api.calls, contains('analysisExclude a1 6'));
    expect(api.analysisExclusionList.single.path, '/Movies');
    c.dispose();
  });

  testWidgets('forgottenScanReturnsToHome', (tester) async {
    final c = AnalyzerController(state);
    await c.start('phone', '/');
    api.analysisTrees.clear(); // oubliée par Kotlin (quatrième analyse, volume fermé…)
    await c.zoom(1);
    expect(c.error, Fr.analysisGone);
    expect(c.scanId, isNull);
    expect(c.view, isNull);
    expect(c.trail, isEmpty);
    expect(await c.children(0), isEmpty);
    // une analyse gardée se rouvre
    await c.start('phone', '/');
    final id = c.scanId!;
    final other = AnalyzerController(state);
    await other.open(id);
    expect(other.view!.root, 0);
    await other.open('inconnue');
    expect(other.error, Fr.analysisGone);
    c.dispose();
    other.dispose();
  });

  testWidgets('progressEventUpdatesAppState', (tester) async {
    var notified = 0;
    state.addListener(() => notified++);
    final p = prog('a1', running: true);
    state.onAnalysisProgress(p);
    expect(state.analysisProgress, same(p));
    expect(notified, 1);
    state.onAnalysisProgress(null);
    expect(state.analysisProgress, isNull);
    final c = AnalyzerController(state);
    await c.start('phone', '/');
    state.onAnalysisProgress(prog(c.scanId!, running: true));
    expect(c.progress!.scanId, c.scanId);
    expect((await c.children(0, sort: 'name')).map((n) => n.name).first, '');
    expect((await c.biggest(0)).first.name, 'VID_20251009.mp4');
    await tester.pump(const Duration(seconds: 1));
    c.dispose();
  });
}

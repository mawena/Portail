import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluluks/src/analyzer/analysis_chart.dart';
import 'package:fluluks/src/analyzer/analyzer_controller.dart';
import 'package:fluluks/src/analyzer/sunburst_layout.dart';
import 'package:fluluks/src/analyzer/treemap_layout.dart';
import 'package:fluluks/src/bridge/fluluks_api.g.dart';
import 'package:fluluks/src/ui/theme.dart';

/// Graphiques de l'analyseur à l'écran : gestes, bande d'information, TalkBack (phase 16, T8).
void main() {
  AnalysisNodeMsg n(int id, int parent, String name, int alloc, int depth,
          {String kind = 'dir', bool kids = false, int? apparent, int items = 0}) =>
      AnalysisNodeMsg(
          id: id,
          parent: parent,
          name: name,
          path: '/$name',
          kind: kind,
          alloc: alloc,
          apparent: apparent ?? alloc,
          items: items,
          mtime: 0,
          hasChildren: kids,
          complete: true,
          depth: depth);

  /// Téléphone (27,3 Go) : Photos (12,3 Go, deux fichiers), film.mkv (9 Go), Autres (3 Go), hors analyse (3 Go).
  AnalysisViewMsg sample({int root = 0, String scan = 'a1'}) => AnalysisViewMsg(
      scanId: scan,
      root: root,
      rootLabel: 'Téléphone',
      nodes: [
        n(0, -1, '', 27300000000, 0, kids: true, items: 1240),
        n(1, 0, 'Photos', 12300000000, 1, kids: true, items: 1234),
        n(2, 0, 'film.mkv', 9000000000, 1, kind: 'file'),
        n(-2, 0, '', 3000000000, 1, kind: 'others', items: 5),
        n(-1, 0, 'Applications, système et dossiers protégés', 3000000000, 1, kind: 'unscanned'),
        n(3, 1, 'IMG.jpg', 8200000000, 2, kind: 'file'),
        n(4, 1, 'creux.bin', 4096, 2, kind: 'file', apparent: 1),
      ],
      running: false,
      truncated: false,
      simplified: false,
      sizeKind: 'allocated');

  final zoomed = <int>[], selected = <int?>[], menus = <int>[];
  var ups = 0;

  Widget host(AnalysisViewMsg v,
      {ChartKind kind = ChartKind.rings, int? sel, double scale = 1, bool noAnim = false, Size size = const Size(400, 520)}) {
    return MaterialApp(
      theme: portailTheme(Brightness.light),
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale), disableAnimations: noAnim),
          child: Scaffold(
            body: Center(
              child: SizedBox.fromSize(
                size: size,
                child: AnalysisChart(
                  view: v,
                  kind: kind,
                  selected: sel,
                  onZoom: zoomed.add,
                  onUp: () => ups++,
                  onSelect: selected.add,
                  onMenu: menus.add,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  setUp(() {
    zoomed.clear();
    selected.clear();
    menus.clear();
    ups = 0;
  });

  /// Point au milieu du segment [id] (anneaux) ou de la cellule (carte), en coordonnées de l'écran.
  Offset pointOf(WidgetTester tester, AnalysisViewMsg v, int id, {ChartKind kind = ChartKind.rings, bool band = false}) {
    final area = tester.getRect(find.byKey(analysisChartPaintKey));
    if (kind == ChartKind.treemap) {
      final c = layoutTreemap(v, Offset.zero & area.size).firstWhere((c) => c.id == id).rect;
      return area.topLeft + (band ? c.topLeft + const Offset(8, 6) : c.center);
    }
    final radius = math.min(area.width, area.height) / 2 - 4;
    final s = layoutRings(v, radius: radius).firstWhere((s) => s.id == id);
    final a = s.start + s.sweep / 2;
    final r = (s.inner + s.outer) / 2;
    return area.center + Offset(math.sin(a), -math.cos(a)) * r;
  }

  testWidgets('tapDirZooms', (tester) async {
    final v = sample();
    await tester.pumpWidget(host(v));
    await tester.tapAt(pointOf(tester, v, 1));
    expect(zoomed, [1]);
    expect(selected, isEmpty);
  });

  testWidgets('tapFileSelectsOnly', (tester) async {
    final v = sample();
    await tester.pumpWidget(host(v));
    for (final id in [2, -2, -1, 3]) {
      await tester.tapAt(pointOf(tester, v, id));
    }
    expect(selected, [2, -2, -1, 3]);
    expect(zoomed, isEmpty);
  });

  testWidgets('tapCenterGoesUp', (tester) async {
    await tester.pumpWidget(host(sample()));
    await tester.tapAt(tester.getRect(find.byKey(analysisChartPaintKey)).center);
    expect(ups, 1);
    expect(zoomed, isEmpty);
  });

  testWidgets('dragUpdatesInfoStrip', (tester) async {
    final v = sample();
    await tester.pumpWidget(host(v));
    expect(find.text('Téléphone — 27,3 Go — 1240 éléments'), findsOneWidget);
    final g = await tester.startGesture(pointOf(tester, v, 1) - const Offset(0, 20));
    await g.moveTo(pointOf(tester, v, 1));
    await tester.pump();
    expect(find.text('Photos — 12,3 Go — 45 % de Téléphone — 1234 éléments'), findsOneWidget);
    await g.moveTo(pointOf(tester, v, 2));
    await tester.pump();
    expect(find.text('film.mkv — 9,0 Go — 33 % de Téléphone'), findsOneWidget);
    await g.up();
    await tester.pump();
    expect(find.text('Téléphone — 27,3 Go — 1240 éléments'), findsOneWidget);
    expect(zoomed, isEmpty);
  });

  testWidgets('apparentShownWhenDifferent', (tester) async {
    await tester.pumpWidget(host(sample(), sel: 4));
    expect(find.text('4,1 ko sur le disque (1 octet de données)'), findsOneWidget);
    await tester.pumpWidget(host(sample(), sel: 2));
    expect(find.textContaining('sur le disque'), findsNothing);
  });

  testWidgets('longPressOpensMenu', (tester) async {
    final v = sample();
    await tester.pumpWidget(host(v));
    await tester.longPressAt(pointOf(tester, v, 2));
    await tester.longPressAt(pointOf(tester, v, 1));
    expect(menus, [2, 1]);
    expect(zoomed, isEmpty);
  });

  testWidgets('treemapSameGestures', (tester) async {
    final v = sample();
    await tester.pumpWidget(host(v, kind: ChartKind.treemap));
    await tester.tapAt(pointOf(tester, v, 1, kind: ChartKind.treemap, band: true)); // bande de titre de Photos
    await tester.tapAt(pointOf(tester, v, 2, kind: ChartKind.treemap));
    await tester.tapAt(pointOf(tester, v, 3, kind: ChartKind.treemap)); // fichier dans Photos : le plus profond
    await tester.longPressAt(pointOf(tester, v, 2, kind: ChartKind.treemap));
    expect(zoomed, [1]);
    expect(selected, [2, 3]);
    expect(menus, [2]);
  });

  testWidgets('selectedOutlined', (tester) async {
    final primary = portailScheme(Brightness.light).primary;
    /// Un tracé ou un rectangle en contour de 2 dp de la couleur primaire.
    PaintPattern outlined(Symbol call) => paints
      ..something((method, args) {
        if (method != call || args.isEmpty || args.last is! Paint) return false;
        final p = args.last as Paint;
        return p.color.toARGB32() == primary.toARGB32() && p.style == PaintingStyle.stroke && p.strokeWidth == 2;
      });
    RenderObject chart() => tester.renderObject(
        find.byWidgetPredicate((w) => w is CustomPaint && w.child?.key == analysisChartPaintKey));
    // sans fondu : un seul dessin à la fois
    await tester.pumpWidget(host(sample(), sel: 2, noAnim: true));
    expect(chart(), outlined(#drawPath));
    await tester.pumpWidget(host(sample(), kind: ChartKind.treemap, sel: 2, noAnim: true));
    expect(chart(), outlined(#drawRect));
    await tester.pumpWidget(host(sample(), noAnim: true));
    expect(chart(), isNot(outlined(#drawPath)));
  });

  testWidgets('semanticsSummaryTopFive', (tester) async {
    final h = tester.ensureSemantics();
    final names = ['A', 'B', 'C', 'D', 'E', 'F', 'G'];
    final v = AnalysisViewMsg(
        scanId: 'a1',
        root: 0,
        rootLabel: 'Téléphone',
        nodes: [
          n(0, -1, '', 28000, 0, kids: true),
          for (var i = 0; i < 7; i++) n(i + 1, 0, names[i], (7 - i) * 1000, 1),
        ],
        running: false,
        truncated: false,
        simplified: false,
        sizeKind: 'allocated');
    await tester.pumpWidget(host(v));
    final label = 'Graphique en anneaux de Téléphone : A, 7,0 ko, 25 % ; B, 6,0 ko, 21 % ; '
        'C, 5,0 ko, 18 % ; D, 4,0 ko, 14 % ; E, 3,0 ko, 11 %';
    expect(find.bySemanticsLabel(label), findsOneWidget);
    // le dessin n'a pas de nœud sémantique à lui
    final node = tester.getSemantics(find.byKey(analysisChartPaintKey));
    expect(node.label, label);
    await tester.pumpWidget(host(v, kind: ChartKind.treemap));
    expect(find.bySemanticsLabel(RegExp('^Carte proportionnelle de Téléphone')), findsOneWidget);
    h.dispose();
  });

  testWidgets('disabledAnimationsNoTransition', (tester) async {
    Finder fades() => find.descendant(of: find.byType(AnalysisChart), matching: find.byType(FadeTransition));
    await tester.pumpWidget(host(sample(), noAnim: true));
    await tester.pumpWidget(host(sample(root: 1), noAnim: true));
    expect(fades(), findsNothing);
    expect(find.byKey(analysisChartPaintKey), findsOneWidget);
    // animations permises : fondu entre les deux vues
    await tester.pumpWidget(host(sample()));
    await tester.pumpWidget(host(sample(root: 1)));
    await tester.pump(const Duration(milliseconds: 50));
    expect(fades(), findsWidgets);
    expect(find.byKey(analysisChartPaintKey), findsNWidgets(2));
    await tester.pumpAndSettle();
    expect(find.byKey(analysisChartPaintKey), findsOneWidget);
  });

  testWidgets('paintsWithoutOverflowAt200Percent', (tester) async {
    for (final kind in ChartKind.values.where((k) => k != ChartKind.none)) {
      for (final size in [const Size(400, 520), const Size(240, 200)]) {
        await tester.pumpWidget(host(sample(), kind: kind, scale: 2, sel: 4, size: size));
        expect(tester.takeException(), isNull, reason: '$kind $size');
      }
    }
  });
}

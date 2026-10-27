import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluluks/src/analyzer/chart_palette.dart';
import 'package:fluluks/src/analyzer/sunburst_layout.dart';
import 'package:fluluks/src/analyzer/treemap_layout.dart';
import 'package:fluluks/src/bridge/fluluks_api.g.dart';
import 'package:fluluks/src/ui/theme.dart';

ColorScheme lightScheme() => portailScheme(Brightness.light);
ColorScheme darkScheme() => portailScheme(Brightness.dark);

/// Géométrie des anneaux et de la carte proportionnelle, palette (phase 16, T7).
void main() {
  AnalysisNodeMsg n(int id, int parent, int alloc, int depth, {String kind = 'dir'}) => AnalysisNodeMsg(
      id: id,
      parent: parent,
      name: 'n$id',
      path: '/n$id',
      kind: kind,
      alloc: alloc,
      apparent: alloc,
      items: 0,
      mtime: 0,
      hasChildren: false,
      complete: true,
      depth: depth);

  AnalysisViewMsg view(List<AnalysisNodeMsg> nodes) => AnalysisViewMsg(
      scanId: 'a1',
      root: nodes.isEmpty ? 0 : nodes.first.id,
      rootLabel: 'Téléphone',
      nodes: nodes,
      running: false,
      truncated: false,
      simplified: false,
      sizeKind: 'allocated');

  /// 0 (1000) → 1 (600 : 3 (400), 4 (200)), 2 (300), -2 (100, others) ; profondeur 2.
  AnalysisViewMsg sample() => view([
        n(0, -1, 1000, 0),
        n(1, 0, 600, 1),
        n(2, 0, 300, 1),
        n(-2, 0, 100, 1, kind: 'others'),
        n(3, 1, 400, 2),
        n(4, 1, 200, 2, kind: 'file'),
      ]);

  test('ringsAnglesProportional', () {
    final s = layoutRings(sample(), radius: 100);
    final byId = {for (final g in s) g.id: g};
    expect(byId[1]!.sweep, closeTo(2 * math.pi * 0.6, 1e-9));
    expect(byId[2]!.sweep, closeTo(2 * math.pi * 0.3, 1e-9));
    expect(byId[-2]!.sweep, closeTo(2 * math.pi * 0.1, 1e-9));
    expect(byId[3]!.sweep, closeTo(byId[1]!.sweep * 400 / 600, 1e-9));
    for (final c in [byId[3]!, byId[4]!]) {
      expect(c.start, greaterThanOrEqualTo(byId[1]!.start - 1e-9));
      expect(c.end, lessThanOrEqualTo(byId[1]!.end + 1e-9));
    }
    final level1 = s.where((g) => g.depth == 1).fold<double>(0, (a, g) => a + g.sweep);
    expect(level1, lessThanOrEqualTo(2 * math.pi + 1e-9));
  });

  test('ringsDepthRadii', () {
    final s = layoutRings(sample(), radius: 100);
    final byId = {for (final g in s) g.id: g};
    // centre : 25 de rayon ; deux anneaux de 37,5
    expect(byId[1]!.inner, 25);
    expect(byId[1]!.outer, 62.5);
    expect(byId[3]!.inner, 62.5);
    expect(byId[3]!.outer, 100);
  });

  test('ringsTinySegmentsDropped', () {
    final v = view([n(0, -1, 100000, 0), n(1, 0, 99999, 1), n(2, 0, 1, 1), n(3, 2, 1, 2)]);
    final s = layoutRings(v, radius: 100);
    expect(s.map((g) => g.id), [1]); // 2 : 6e-5 rad, ni lui ni son enfant
  });

  test('ringsHitTest', () {
    final s = layoutRings(sample(), radius: 100);
    expect(hitRing(s, const Offset(0, 10), 25)!.center, isTrue);
    // juste après midi, premier anneau : le premier enfant (1)
    expect(hitRing(s, const Offset(5, -40), 25), (center: false, id: 1));
    // à 6 h (π, dans 1 qui couvre [0 ; 1,2π)), deuxième anneau : 3 couvre [0 ; 0,8π), 4 [0,8π ; 1,2π)
    expect(hitRing(s, const Offset(0, 80), 25), (center: false, id: 4));
    // à 9 h (1,5π), premier anneau : 2 couvre [1,2π ; 1,8π)
    expect(hitRing(s, const Offset(-40, 0), 25), (center: false, id: 2));
    expect(hitRing(s, const Offset(-80, 0), 25), isNull); // 2 n'a pas d'enfant dessiné
    expect(hitRing(s, const Offset(0, 150), 25), isNull);
  });

  test('treemapAreasProportional', () {
    const bounds = Rect.fromLTWH(0, 0, 400, 300);
    final cells = layoutTreemap(sample(), bounds, header: 18, pad: 1);
    final byId = {for (final c in cells) c.id: c};
    double area(Rect r) => r.width * r.height;
    for (final (id, frac) in [(1, 0.6), (2, 0.3), (-2, 0.1)]) {
      expect(area(byId[id]!.rect) / area(bounds), closeTo(frac, 0.01));
    }
    // sous 1 : aire utile = cellule moins la marge et la bande de titre
    final r1 = byId[1]!.rect.deflate(1);
    final content = r1.width * (r1.height - 18);
    expect(area(byId[3]!.rect) / content, closeTo(400 / 600, 0.01));
    expect(area(byId[4]!.rect) / content, closeTo(200 / 600, 0.01));
    expect(byId[1]!.labelled, isTrue);
  });

  test('treemapSquarifiedAspect', () {
    final rects = squarify([6, 6, 4, 3, 2, 2, 1], const Rect.fromLTWH(0, 0, 6, 4));
    double aspect(Rect r) => math.max(r.width / r.height, r.height / r.width);
    expect(rects.map(aspect).reduce(math.max), lessThanOrEqualTo(3));
    expect(rects.fold<double>(0, (a, r) => a + r.width * r.height), closeTo(24, 1e-9));
    for (var i = 0; i < rects.length; i++) {
      for (var j = i + 1; j < rects.length; j++) {
        expect(rects[i].intersect(rects[j]).width * rects[i].intersect(rects[j]).height <= 1e-9 ||
            rects[i].intersect(rects[j]).width <= 0 || rects[i].intersect(rects[j]).height <= 0, isTrue);
      }
    }
  });

  test('treemapNestedInsideParent', () {
    final cells = layoutTreemap(sample(), const Rect.fromLTWH(0, 0, 400, 300));
    final byId = {for (final c in cells) c.id: c};
    for (final id in [3, 4]) {
      final r = byId[id]!.rect;
      final p = byId[1]!.rect;
      expect(r.left >= p.left - 1e-9 && r.right <= p.right + 1e-9 && r.top >= p.top + 18 && r.bottom <= p.bottom + 1e-9,
          isTrue);
    }
  });

  test('treemapHitDeepest', () {
    final cells = layoutTreemap(sample(), const Rect.fromLTWH(0, 0, 400, 300));
    final byId = {for (final c in cells) c.id: c};
    expect(hitTreemap(cells, byId[3]!.rect.center), 3);
    expect(hitTreemap(cells, byId[1]!.rect.topLeft + const Offset(5, 5)), 1); // bande de titre
    expect(hitTreemap(cells, byId[2]!.rect.center), 2);
    expect(hitTreemap(cells, const Offset(-5, -5)), isNull);
  });

  test('zeroSizeAndEmptyView', () {
    expect(layoutRings(view([]), radius: 100), isEmpty);
    expect(layoutTreemap(view([]), const Rect.fromLTWH(0, 0, 10, 10)), isEmpty);
    final zero = view([n(0, -1, 0, 0), n(1, 0, 0, 1)]);
    expect(layoutRings(zero, radius: 100), isEmpty);
    expect(layoutTreemap(zero, const Rect.fromLTWH(0, 0, 100, 100)), isEmpty);
    expect(layoutRings(sample(), radius: 0), isEmpty);
    expect(layoutTreemap(sample(), Rect.zero), isEmpty);
    for (final g in layoutRings(view([n(0, -1, 10, 0), n(1, 0, 10, 1), n(2, 1, 0, 2)]), radius: 50)) {
      expect(g.sweep.isNaN || g.inner.isNaN, isFalse);
    }
  });

  test('paletteContrastAtLeast3to1', () {
    for (final s in [lightScheme(), darkScheme()]) {
      for (var top = 0; top < 8; top++) {
        for (var depth = 1; depth <= 4; depth++) {
          final c = segmentColor(s, topIndex: top, depth: depth, kind: 'dir');
          expect(contrastRatio(c, s.surface), greaterThanOrEqualTo(3),
              reason: '${s.brightness} teinte $top profondeur $depth');
          final f = segmentColor(s, topIndex: top, depth: depth, kind: 'file');
          expect(contrastRatio(f, s.surface), greaterThanOrEqualTo(3),
              reason: '${s.brightness} fichier $top profondeur $depth');
        }
      }
    }
  });

  test('paletteTopLevelHuesDistinct', () {
    final s = lightScheme();
    final hues = [for (var i = 0; i < 8; i++) HSLColor.fromColor(segmentColor(s, topIndex: i, depth: 1, kind: 'dir')).hue];
    for (var i = 0; i < 8; i++) {
      for (var j = i + 1; j < 8; j++) {
        final d = (hues[i] - hues[j]).abs();
        expect(math.min(d, 360 - d), greaterThanOrEqualTo(20));
      }
    }
    expect(segmentColor(s, topIndex: 0, depth: 1, kind: 'others'), s.outline);
    expect(segmentColor(s, topIndex: 0, depth: 1, kind: 'unscanned'), s.surfaceContainerHighest);
  });
}

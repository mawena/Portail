import 'dart:math' as math;
import 'dart:ui';

import '../bridge/fluluks_api.g.dart';
import 'chart_layout.dart';

/// Segment des anneaux : angles en radians depuis midi, sens des aiguilles d'une montre ; rayons en pixels.
class RingSegment {
  const RingSegment({
    required this.id,
    required this.depth,
    required this.start,
    required this.sweep,
    required this.inner,
    required this.outer,
  });

  final int id;
  final int depth;
  final double start, sweep, inner, outer;

  double get end => start + sweep;
}

/// Anneaux concentriques (comme Baobab) : la racine de la vue au centre (disque de [centerFraction] du rayon), l'anneau
/// de profondeur `d` entre `r0 + (d − 1)·w` et `r0 + d·w`, `w = (radius − r0) / profondeur de la vue` ; chaque enfant
/// dans la plage angulaire de son parent, en proportion de sa place. Un segment de moins de [minSweep] radians n'est
/// pas dessiné, ni rien dessous.
List<RingSegment> layoutRings(AnalysisViewMsg v, {required double radius, double centerFraction = 0.25, double minSweep = 0.01}) {
  if (v.nodes.isEmpty || radius <= 0) return const [];
  final root = v.nodes.first;
  final kids = childrenOf(v);
  final maxDepth = v.nodes.fold<int>(0, (m, n) => math.max(m, n.depth));
  if (maxDepth == 0 || root.alloc <= 0) return const [];
  final r0 = radius * centerFraction;
  final w = (radius - r0) / maxDepth;
  final out = <RingSegment>[];
  // parcours en largeur : (nœud, début, balayage)
  final queue = <(AnalysisNodeMsg, double, double)>[(root, 0, 2 * math.pi)];
  for (var i = 0; i < queue.length; i++) {
    final (n, start, sweep) = queue[i];
    final children = kids[n.id] ?? const [];
    final total = totalOf(n, children);
    if (total <= 0) continue;
    var a = start;
    for (final c in children) {
      if (c.alloc <= 0) continue;
      final s = sweep * c.alloc / total;
      if (s >= minSweep) {
        final d = c.depth;
        out.add(RingSegment(id: c.id, depth: d, start: a, sweep: s, inner: r0 + (d - 1) * w, outer: r0 + d * w));
        queue.add((c, a, s));
      }
      a += s;
    }
  }
  return out;
}

/// Ce qui est sous [fromCenter] (décalage depuis le centre) : le disque central (`center` vrai, `id` sans objet), un
/// segment, ou null hors du graphique. Les identifiants virtuels (`others`, `unscanned`) sont négatifs.
({bool center, int id})? hitRing(List<RingSegment> s, Offset fromCenter, double centerRadius) {
  final r = fromCenter.distance;
  if (r <= centerRadius) return (center: true, id: 0);
  // angle depuis midi, sens des aiguilles d'une montre (y vers le bas), dans [0, 2π)
  var a = math.atan2(fromCenter.dx, -fromCenter.dy);
  if (a < 0) a += 2 * math.pi;
  for (final g in s) {
    if (r >= g.inner && r < g.outer && a >= g.start && a < g.end) return (center: false, id: g.id);
  }
  return null;
}

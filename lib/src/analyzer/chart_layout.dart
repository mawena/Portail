import '../bridge/fluluks_api.g.dart';

/// Enfants de chaque nœud d'une vue, dans l'ordre de la vue (place décroissante, puis `others` et `unscanned`).
Map<int, List<AnalysisNodeMsg>> childrenOf(AnalysisViewMsg v) {
  final out = <int, List<AnalysisNodeMsg>>{};
  for (final n in v.nodes.skip(1)) {
    (out[n.parent] ??= []).add(n);
  }
  return out;
}

/// Total qui sert de tour complet ou d'aire entière pour les enfants de [n] : sa place, ou la somme de ses enfants si
/// elle la dépasse (jamais plus de 100 %).
int totalOf(AnalysisNodeMsg n, List<AnalysisNodeMsg> kids) {
  final sum = kids.fold<int>(0, (a, k) => a + (k.alloc > 0 ? k.alloc : 0));
  return n.alloc > sum ? n.alloc : sum;
}

/// Index (0 à 7) de l'ancêtre de [id] parmi les enfants directs de la racine de la vue, pour la couleur ; 0 pour la
/// racine elle-même.
Map<int, int> topIndexes(AnalysisViewMsg v) {
  final out = <int, int>{};
  if (v.nodes.isEmpty) return out;
  final root = v.nodes.first.id;
  out[root] = 0;
  var i = 0;
  for (final n in v.nodes.skip(1)) {
    out[n.id] = n.parent == root ? i++ % 8 : (out[n.parent] ?? 0);
  }
  return out;
}

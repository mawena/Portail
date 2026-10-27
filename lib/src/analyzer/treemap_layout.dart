import 'dart:math' as math;
import 'dart:ui';

import '../bridge/fluluks_api.g.dart';
import 'chart_layout.dart';

/// Cellule de la carte proportionnelle ; [labelled] : assez grande pour son nom (bande de titre d'un dossier, ou
/// cellule d'un fichier).
class TreemapCell {
  const TreemapCell({required this.id, required this.depth, required this.rect, required this.labelled});

  final int id;
  final int depth;
  final Rect rect;
  final bool labelled;
}

/// Largeur minimale d'une cellule pour y écrire un nom.
const _labelMinWidth = 40.0;

/// Carte proportionnelle imbriquée, « squarified » (Bruls, Huizing et van Wijk, 2000) : chaque enfant reçoit une aire
/// proportionnelle à sa place dans l'aire utile de son parent (moins une marge de [pad] et, pour un dossier assez haut,
/// une bande de titre de [header]) ; une cellule de moins de [minSide] de côté n'est pas dessinée, ni rien dessous.
List<TreemapCell> layoutTreemap(AnalysisViewMsg v, Rect bounds, {double header = 18, double pad = 1, double minSide = 2}) {
  if (v.nodes.isEmpty || bounds.width <= 0 || bounds.height <= 0) return const [];
  final kids = childrenOf(v);
  final out = <TreemapCell>[];
  final queue = <(AnalysisNodeMsg, Rect)>[(v.nodes.first, bounds)];
  for (var i = 0; i < queue.length; i++) {
    final (n, r) = queue[i];
    final children = (kids[n.id] ?? const <AnalysisNodeMsg>[]).where((c) => c.alloc > 0).toList();
    final isRoot = i == 0;
    var content = isRoot ? r : r.deflate(pad);
    if (!isRoot && children.isNotEmpty && content.height >= 2 * header) {
      content = Rect.fromLTRB(content.left, content.top + header, content.right, content.bottom);
    }
    final total = totalOf(n, children);
    if (children.isEmpty || total <= 0 || content.width <= 0 || content.height <= 0) continue;
    final scale = content.width * content.height / total;
    final rects = squarify([for (final c in children) c.alloc * scale], content);
    for (var k = 0; k < children.length; k++) {
      final c = children[k];
      final cr = rects[k];
      if (cr.width < minSide || cr.height < minSide) continue;
      final hasKids = (kids[c.id] ?? const []).isNotEmpty;
      final labelled = cr.width >= _labelMinWidth && cr.height >= (hasKids ? 2 * header : header);
      out.add(TreemapCell(id: c.id, depth: c.depth, rect: cr, labelled: labelled));
      if (hasKids) queue.add((c, cr));
    }
  }
  return out;
}

/// Rectangles des [areas] (déjà à l'échelle, triées ou non) dans [r], dans le même ordre, par l'algorithme
/// « squarified » : une rangée le long du côté court se remplit tant que son pire rapport des côtés ne se dégrade pas.
List<Rect> squarify(List<double> areas, Rect r) {
  final order = List<int>.generate(areas.length, (i) => i)..sort((a, b) => areas[b].compareTo(areas[a]));
  final out = List<Rect>.filled(areas.length, Rect.zero);
  var rect = r;
  var i = 0;
  while (i < order.length) {
    final side = math.min(rect.width, rect.height);
    if (side <= 0) break;
    final row = <int>[order[i]];
    var rowSum = areas[order[i]];
    var j = i + 1;
    while (j < order.length) {
      final next = areas[order[j]];
      if (_worst(row.map((k) => areas[k]), rowSum + next, side, extra: next) >
          _worst(row.map((k) => areas[k]), rowSum, side)) {
        break;
      }
      row.add(order[j]);
      rowSum += next;
      j++;
    }
    final thick = rowSum / side;
    var pos = 0.0;
    final horizontal = rect.width >= rect.height; // rangée verticale à gauche, sinon horizontale en haut
    for (final k in row) {
      final len = areas[k] / thick;
      out[k] = horizontal
          ? Rect.fromLTWH(rect.left, rect.top + pos, thick, len)
          : Rect.fromLTWH(rect.left + pos, rect.top, len, thick);
      pos += len;
    }
    rect = horizontal
        ? Rect.fromLTRB(rect.left + thick, rect.top, rect.right, rect.bottom)
        : Rect.fromLTRB(rect.left, rect.top + thick, rect.right, rect.bottom);
    i = j;
  }
  return out;
}

/// Pire rapport des côtés d'une rangée de somme [sum] le long d'un côté [side] (avec [extra] en plus des [row]).
double _worst(Iterable<double> row, double sum, double side, {double? extra}) {
  var mx = extra ?? 0.0;
  var mn = extra ?? double.infinity;
  for (final a in row) {
    mx = math.max(mx, a);
    mn = math.min(mn, a);
  }
  if (sum <= 0 || mn <= 0) return double.infinity;
  final s2 = side * side;
  return math.max(s2 * mx / (sum * sum), sum * sum / (s2 * mn));
}

/// Cellule la plus profonde sous [p], ou null.
int? hitTreemap(List<TreemapCell> c, Offset p) {
  TreemapCell? best;
  for (final cell in c) {
    if (cell.rect.contains(p) && (best == null || cell.depth > best.depth)) best = cell;
  }
  return best?.id;
}

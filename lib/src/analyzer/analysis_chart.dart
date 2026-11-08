import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../bridge/fluluks_api.g.dart';
import '../strings_fr.dart';
import '../ui/tokens.dart';
import 'analyzer_controller.dart';
import 'chart_info_strip.dart';
import 'chart_layout.dart';
import 'chart_palette.dart';
import 'sunburst_layout.dart';
import 'treemap_layout.dart';

/// Clé du dessin (tests).
const analysisChartPaintKey = Key('analysis-chart-paint');

/// Anneaux concentriques ou carte proportionnelle d'une vue de l'analyseur (phase 16), au doigt : toucher un dossier
/// pour y entrer, un autre élément pour le choisir ; toucher le centre des anneaux pour remonter ; glisser pour lire la
/// bande d'information ; appui long pour le menu. TalkBack lit un résumé (les cinq plus gros) ; l'arbre de l'écran
/// sert d'alternative complète.
class AnalysisChart extends StatefulWidget {
  const AnalysisChart({
    super.key,
    required this.view,
    required this.kind,
    this.selected,
    required this.onZoom,
    required this.onUp,
    required this.onSelect,
    required this.onMenu,
  });

  final AnalysisViewMsg view;
  final ChartKind kind;
  final int? selected;
  final ValueChanged<int> onZoom;
  final VoidCallback onUp;
  final ValueChanged<int?> onSelect;
  final ValueChanged<int> onMenu;

  @override
  State<AnalysisChart> createState() => _AnalysisChartState();
}

class _AnalysisChartState extends State<AnalysisChart> {
  int? _hover;
  _Geometry? _geometry;

  AnalysisNodeMsg? _node(int? id) => id == null ? null : widget.view.nodes.where((n) => n.id == id).firstOrNull;

  /// Élément sous [p] (null : rien) ; `center` vrai pour le disque central des anneaux.
  ({bool center, int id})? _hit(Offset p) {
    final g = _geometry;
    if (g == null) return null;
    if (g.rings != null) return hitRing(g.rings!, p - g.center, g.centerRadius);
    final id = hitTreemap(g.cells!, p);
    return id == null ? null : (center: false, id: id);
  }

  void _tap(Offset p) {
    final h = _hit(p);
    if (h == null) return;
    if (h.center) {
      widget.onUp();
      return;
    }
    final n = _node(h.id);
    if (n == null) return;
    final enterable = (n.kind == 'dir' || n.kind == 'trash') && n.hasChildren;
    if (enterable) {
      widget.onZoom(n.id);
    } else {
      widget.onSelect(n.id);
    }
  }

  void _drag(Offset p) {
    final h = _hit(p);
    final id = h == null || h.center ? null : h.id;
    if (id != _hover) setState(() => _hover = id);
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.view;
    final scheme = Theme.of(context).colorScheme;
    final root = v.nodes.first;
    final top = (List.of(v.nodes.where((n) => n.depth == 1))..sort((a, b) => b.alloc - a.alloc)).take(5);
    final summary = Fr.chartSummary(widget.kind.name, analysisNodeName(root, rootLabel: v.rootLabel), [
      for (final n in top) (analysisNodeName(n), n.alloc, analysisPercent(n, root)),
    ]);
    final shown = _node(_hover) ?? _node(widget.selected);
    return Column(
      children: [
        Expanded(
          child: Semantics(
            container: true,
            label: summary,
            child: ExcludeSemantics(
              child: LayoutBuilder(builder: (context, box) {
                final size = Size(box.maxWidth, box.maxHeight);
                _geometry = _Geometry.of(v, widget.kind, size);
                // fondu d'un zoom à l'autre, absent quand Android coupe les animations
                final fade = Motion.of(context, Motion.medium);
                final paint = CustomPaint(
                  key: ValueKey((v.scanId, v.root, widget.kind)),
                  size: size,
                  painter: _ChartPainter(
                    view: v,
                    geometry: _geometry!,
                    scheme: scheme,
                    selected: widget.selected,
                    textStyle: Theme.of(context).textTheme.labelSmall!,
                    textScaler: MediaQuery.textScalerOf(context),
                  ),
                  child: SizedBox.fromSize(size: size, key: analysisChartPaintKey),
                );
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (d) => _tap(d.localPosition),
                  onLongPressStart: (d) {
                    final h = _hit(d.localPosition);
                    if (h != null && !h.center) widget.onMenu(h.id);
                  },
                  onPanStart: (d) => _drag(d.localPosition),
                  onPanUpdate: (d) => _drag(d.localPosition),
                  onPanEnd: (_) => setState(() => _hover = null),
                  child: fade == Duration.zero ? paint : AnimatedSwitcher(duration: fade, child: paint),
                );
              }),
            ),
          ),
        ),
        ChartInfoStrip(node: shown, root: root, sizeKind: v.sizeKind, rootLabel: v.rootLabel),
      ],
    );
  }
}

/// Mise en page calculée pour une taille : anneaux (centre et rayon) ou cellules.
class _Geometry {
  _Geometry({this.rings, this.cells, this.center = Offset.zero, this.centerRadius = 0, this.radius = 0});

  final List<RingSegment>? rings;
  final List<TreemapCell>? cells;
  final Offset center;
  final double centerRadius, radius;

  static _Geometry of(AnalysisViewMsg v, ChartKind kind, Size size) {
    if (kind == ChartKind.treemap) {
      return _Geometry(cells: layoutTreemap(v, Offset.zero & size));
    }
    final radius = math.max(0.0, math.min(size.width, size.height) / 2 - 4);
    return _Geometry(
      rings: layoutRings(v, radius: radius),
      center: size.center(Offset.zero),
      centerRadius: radius * 0.25,
      radius: radius,
    );
  }
}

class _ChartPainter extends CustomPainter {
  _ChartPainter({
    required this.view,
    required this.geometry,
    required this.scheme,
    required this.selected,
    required this.textStyle,
    required this.textScaler,
  }) : _tops = topIndexes(view),
       _byId = {for (final n in view.nodes) n.id: n};

  final AnalysisViewMsg view;
  final _Geometry geometry;
  final ColorScheme scheme;
  final int? selected;
  final TextStyle textStyle;
  final TextScaler textScaler;
  final Map<int, int> _tops;
  final Map<int, AnalysisNodeMsg> _byId;

  Color _fill(int id) {
    final n = _byId[id]!;
    return segmentColor(scheme, topIndex: _tops[id] ?? 0, depth: n.depth, kind: n.kind);
  }

  /// Texte lisible sur [fill] : la couleur du texte de la surface ou celle de la surface, la plus contrastée.
  Color _ink(Color fill) =>
      contrastRatio(scheme.onSurface, fill) >= contrastRatio(scheme.surface, fill) ? scheme.onSurface : scheme.surface;

  void _label(Canvas c, String text, Rect box, Color fill) {
    if (box.width < 24 || box.height < 10) return;
    final tp = TextPainter(
      text: TextSpan(text: text, style: textStyle.copyWith(color: _ink(fill))),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
      textScaler: textScaler,
    )..layout(maxWidth: box.width - 4);
    if (tp.height > box.height) return; // jamais débordant : rien plutôt qu'un nom coupé en hauteur
    tp.paint(c, Offset(box.left + 2, box.top + (box.height - tp.height) / 2));
  }

  @override
  void paint(Canvas canvas, Size size) {
    final sep = Paint()
      ..color = scheme.surface
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final outline = Paint()
      ..color = scheme.primary
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final g = geometry;
    if (g.rings != null) {
      canvas.drawCircle(g.center, g.centerRadius, Paint()..color = scheme.surfaceContainerHigh);
      final rootName = analysisNodeName(view.nodes.first, rootLabel: view.rootLabel);
      final side = g.centerRadius * math.sqrt2;
      _label(canvas, rootName, Rect.fromCenter(center: g.center, width: side, height: side),
          scheme.surfaceContainerHigh);
      Path? chosen;
      for (final s in g.rings!) {
        final path = _arc(g.center, s);
        final fill = _fill(s.id);
        canvas.drawPath(path, Paint()..color = fill);
        canvas.drawPath(path, sep);
        if (s.id == selected) chosen = path;
        final mid = (s.inner + s.outer) / 2;
        if (s.sweep * mid >= 48) {
          final a = s.start + s.sweep / 2;
          final p = g.center + Offset(math.sin(a), -math.cos(a)) * mid;
          final w = math.min(s.sweep * mid, s.outer - s.inner + 24);
          _label(canvas, analysisNodeName(_byId[s.id]!), Rect.fromCenter(center: p, width: w, height: 16), fill);
        }
      }
      if (chosen != null) canvas.drawPath(chosen, outline);
    } else {
      Rect? chosen;
      for (final cell in g.cells!) {
        final fill = _fill(cell.id);
        canvas.drawRect(cell.rect, Paint()..color = fill);
        canvas.drawRect(cell.rect, sep);
        if (cell.id == selected) chosen = cell.rect;
        if (cell.labelled) {
          final band = Rect.fromLTWH(cell.rect.left, cell.rect.top, cell.rect.width, math.min(18, cell.rect.height));
          _label(canvas, analysisNodeName(_byId[cell.id]!), band, fill);
        }
      }
      if (chosen != null) canvas.drawRect(chosen.deflate(1), outline);
    }
  }

  /// Secteur d'anneau : arc extérieur dans le sens des aiguilles d'une montre, arc intérieur en retour.
  Path _arc(Offset c, RingSegment s) {
    const top = -math.pi / 2; // les angles partent de midi
    final path = Path()..arcTo(Rect.fromCircle(center: c, radius: s.outer), top + s.start, s.sweep, true);
    if (s.sweep >= 2 * math.pi - 1e-6) {
      path
        ..close()
        ..addOval(Rect.fromCircle(center: c, radius: s.inner))
        ..fillType = PathFillType.evenOdd;
      return path;
    }
    path
      ..arcTo(Rect.fromCircle(center: c, radius: s.inner), top + s.start + s.sweep, -s.sweep, false)
      ..close();
    return path;
  }

  @override
  bool shouldRepaint(_ChartPainter old) =>
      old.view != view || old.selected != selected || old.scheme != scheme || old.geometry != geometry;
}

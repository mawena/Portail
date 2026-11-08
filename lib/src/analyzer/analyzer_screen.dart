import 'package:flutter/material.dart';

import '../bridge/fluluks_api.g.dart';
import '../screens/explorer_screen.dart';
import '../screens/module_shell.dart';
import '../state/app_state.dart';
import '../state/prefs.dart';
import '../strings_fr.dart';
import '../ui/states.dart';
import '../ui/tokens.dart';
import '../ui/widgets.dart';
import 'analysis_chart.dart';
import 'analysis_tree.dart';
import 'analyzer_controller.dart';
import 'chart_info_strip.dart';
import 'node_actions.dart';

/// Ouvre l'écran d'une analyse, dans le module Analyseur d'où qu'on vienne : avec [sourceId], lance l'analyse de
/// [path] ; avec [scanId], rouvre une analyse gardée.
Future<void> openAnalysis(BuildContext context, AppState state, {String? scanId, String? sourceId, String path = '/'}) {
  final route = MaterialPageRoute<void>(
    builder: (_) => AnalyzerScreen(state: state, scanId: scanId, sourceId: sourceId, path: path),
  );
  final shell = ModuleShell.maybeOf(context);
  return shell == null ? Navigator.of(context).push(route) : shell.push(PortailModule.analyzer, route);
}

/// Clé du menu de la barre de titre (tri, profondeur), pour les tests.
const analyzerMenuKey = Key('analyseur-menu');

/// Largeur à partir de laquelle graphique et arbre sont côte à côte.
const analyzerWideWidth = 840.0;

/// Écran d'une analyse (phase 16) : progression, graphique (anneaux ou carte, 45 % de la hauteur au plus en portrait),
/// fil d'Ariane, arbre synchronisé ou plus gros fichiers ; Retour remonte d'un niveau, puis quitte.
class AnalyzerScreen extends StatefulWidget {
  const AnalyzerScreen({super.key, required this.state, this.scanId, this.sourceId, this.path = '/'});

  final AppState state;
  final String? scanId;
  final String? sourceId;
  final String path;

  @override
  State<AnalyzerScreen> createState() => _AnalyzerScreenState();
}

enum _Menu { sortSize, sortName, sortItems, sortDate, fewer, more }

class _AnalyzerScreenState extends State<AnalyzerScreen> {
  late final AnalyzerController c = AnalyzerController(widget.state);
  String _sort = 'size';
  String? _sourceId;

  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    _sourceId = widget.sourceId;
    if (widget.scanId != null) {
      c.open(widget.scanId!).then((_) => _resolveSource());
    } else if (widget.sourceId != null) {
      c.start(widget.sourceId!, widget.path);
    }
  }

  Future<void> _resolveSource() async {
    if (_sourceId != null || c.scanId == null) return;
    final s = (await state.api.analyses()).where((a) => a.scanId == c.scanId).firstOrNull;
    if (s != null && mounted) setState(() => _sourceId = s.sourceId);
  }

  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  void _menu(AnalysisNodeMsg n) {
    final src = _sourceId;
    if (src == null) return;
    showNodeActions(context, state, c, n, sourceId: src);
  }

  void _chartMenu(int id) {
    final n = c.view?.nodes.where((e) => e.id == id).firstOrNull;
    if (n != null) _menu(n);
  }

  Widget _progress(AnalysisProgressMsg p) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.l, Space.s, Space.l, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, spacing: Space.xs, children: [
        LinearProgressIndicator(value: p.usedBytes == null ? null : p.fraction),
        Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(Fr.analysisProgress(p.files, p.bytes), style: t.bodyMedium),
              Text(p.current, style: t.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
            ]),
          ),
          TextButton(onPressed: state.api.cancelAnalysis, child: const Text(Fr.cancel)),
        ]),
      ]),
    );
  }

  List<Widget> _banners() {
    final v = c.view;
    final p = c.progress;
    return [
      if (p != null && p.cancelled && !p.running)
        StatusBanner(
          icon: Icons.warning_amber_rounded,
          text: Fr.analysisPartial,
          actions: [TextButton(onPressed: c.rescan, child: const Text(Fr.reanalyze))],
        ),
      if (p != null && p.error != null && !p.running)
        StatusBanner(icon: Icons.error_outline_rounded, text: p.error!, tone: ChipTone.danger),
      if (v != null && v.simplified) const StatusBanner(icon: Icons.info_outline_rounded, text: Fr.analysisSimplified, tone: ChipTone.neutral),
      if (v != null && v.sizeKind == 'apparent')
        const StatusBanner(icon: Icons.cloud_outlined, text: Fr.analysisRemoteNotice, tone: ChipTone.neutral),
    ];
  }

  Widget _trail() {
    final trail = c.trail;
    final s = Theme.of(context).colorScheme;
    return SizedBox(
      height: Layout.minTouch,
      child: Row(children: [
        IconButton(
          tooltip: Fr.pickUp,
          onPressed: trail.length > 1 ? c.up : null,
          icon: const Icon(Icons.arrow_upward_rounded),
        ),
        Expanded(
          child: ListView(scrollDirection: Axis.horizontal, reverse: true, children: [
            for (var i = trail.length - 1; i >= 0; i--) ...[
              TextButton(
                onPressed: i == trail.length - 1 ? null : () => c.goTo(i),
                child: Text(analysisNodeName(trail[i], rootLabel: c.rootLabel)),
              ),
              if (i > 0) Icon(Icons.chevron_right_rounded, color: s.onSurfaceVariant, size: 18),
            ],
          ]),
        ),
      ]),
    );
  }

  Widget _chart(BoxConstraints box) {
    final v = c.view;
    if (v == null || c.chart == ChartKind.none) return const SizedBox.shrink();
    return AnalysisChart(
      view: v,
      kind: c.chart,
      selected: c.selected,
      onZoom: c.zoom,
      onUp: c.up,
      onSelect: c.select,
      onMenu: _chartMenu,
    );
  }

  Widget _lower() => DefaultTabController(
        length: 2,
        child: Column(children: [
          // libellés réduits plutôt que coupés quand ils ne tiennent pas (texte à 200 %)
          const TabBar(tabs: [
            Tab(child: FittedBox(fit: BoxFit.scaleDown, child: Text(Fr.analysisContent))),
            Tab(child: FittedBox(fit: BoxFit.scaleDown, child: Text(Fr.biggestFiles))),
          ]),
          Expanded(
            child: TabBarView(children: [
              AnalysisTree(controller: c, sort: _sort, onMenu: _menu),
              _Biggest(controller: c, node: c.displayed?.id ?? 0, sourceId: _sourceId, state: state),
            ]),
          ),
        ]),
      );

  Widget _body() {
    final v = c.view;
    final p = c.progress;
    if (v == null) {
      if (c.error != null) return ErrorState(message: c.error!, onRetry: c.scanId == null && widget.sourceId != null ? c.rescan : null);
      return DelayedProgress(
        label: Fr.analyzing,
        action: TextButton(onPressed: state.api.cancelAnalysis, child: const Text(Fr.cancel)),
      );
    }
    final top = <Widget>[
      if (p != null && p.running) _progress(p),
      for (final b in _banners()) Padding(padding: const EdgeInsets.fromLTRB(Space.l, Space.s, Space.l, 0), child: b),
      _trail(),
    ];
    return LayoutBuilder(builder: (context, box) {
      final hasChart = c.chart != ChartKind.none;
      if (box.maxWidth >= analyzerWideWidth) {
        return Column(children: [
          ...top,
          Expanded(
            child: Row(children: [
              if (hasChart) Expanded(child: _chart(box)),
              Expanded(child: _lower()),
            ]),
          ),
        ]);
      }
      final chartHeight = (box.maxHeight * 0.45).clamp(0.0, box.maxWidth + 80);
      return Column(children: [
        ...top,
        if (hasChart) SizedBox(height: chartHeight, child: _chart(box)),
        if (!hasChart && c.displayed != null)
          ChartInfoStrip(node: c.view?.nodes.where((n) => n.id == c.selected).firstOrNull, root: v.nodes.first, sizeKind: v.sizeKind, rootLabel: v.rootLabel),
        Expanded(child: _lower()),
      ]);
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([c, state]),
      builder: (context, _) {
        final title = c.rootLabel;
        return PopScope(
          canPop: c.trail.length <= 1,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) c.up();
          },
          child: Scaffold(
            appBar: AppBar(
              title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
              actions: [
                IconButton(tooltip: Fr.reanalyze, onPressed: c.scanId == null ? null : c.rescan, icon: const Icon(Icons.refresh_rounded)),
                PopupMenuButton<ChartKind>(
                  tooltip: Fr.chartChoice,
                  icon: Icon(switch (c.chart) {
                    ChartKind.rings => Icons.donut_large_rounded,
                    ChartKind.treemap => Icons.dashboard_rounded,
                    ChartKind.none => Icons.view_list_rounded,
                  }),
                  onSelected: c.setChart,
                  itemBuilder: (_) => [
                    CheckedPopupMenuItem(value: ChartKind.rings, checked: c.chart == ChartKind.rings, child: const Text(Fr.chartRings)),
                    CheckedPopupMenuItem(value: ChartKind.treemap, checked: c.chart == ChartKind.treemap, child: const Text(Fr.chartTreemap)),
                    CheckedPopupMenuItem(value: ChartKind.none, checked: c.chart == ChartKind.none, child: const Text(Fr.chartNone)),
                  ],
                ),
                PopupMenuButton<_Menu>(
                  key: analyzerMenuKey,
                  onSelected: (m) => switch (m) {
                    _Menu.sortSize => setState(() => _sort = 'size'),
                    _Menu.sortName => setState(() => _sort = 'name'),
                    _Menu.sortItems => setState(() => _sort = 'items'),
                    _Menu.sortDate => setState(() => _sort = 'date'),
                    _Menu.fewer => c.setDepth(c.depth - 1),
                    _Menu.more => c.setDepth(c.depth + 1),
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(enabled: false, child: Text(Fr.sortBy)),
                    for (final (m, label, key) in const [
                      (_Menu.sortSize, Fr.sortSize, 'size'),
                      (_Menu.sortName, Fr.sortName, 'name'),
                      (_Menu.sortItems, Fr.sortItems, 'items'),
                      (_Menu.sortDate, Fr.sortDate, 'date'),
                    ])
                      CheckedPopupMenuItem(value: m, checked: _sort == key, child: Text(label)),
                    const PopupMenuDivider(),
                    PopupMenuItem(value: _Menu.fewer, enabled: c.depth > analyzerDepthMin, child: const Text(Fr.fewerLevels)),
                    PopupMenuItem(value: _Menu.more, enabled: c.depth < analyzerDepthMax, child: const Text(Fr.moreLevels)),
                  ],
                ),
              ],
            ),
            body: SafeArea(top: false, child: _body()),
          ),
        );
      },
    );
  }
}

/// Plus gros fichiers sous le nœud affiché, avec leur dossier.
class _Biggest extends StatefulWidget {
  const _Biggest({required this.controller, required this.node, required this.sourceId, required this.state});

  final AnalyzerController controller;
  final int node;
  final String? sourceId;
  final AppState state;

  @override
  State<_Biggest> createState() => _BiggestState();
}

class _BiggestState extends State<_Biggest> {
  Future<List<EntryMsg>>? _files;
  (Object?, int)? _for;

  @override
  Widget build(BuildContext context) {
    final key = (widget.controller.view, widget.node);
    if (_for != key) {
      _for = key;
      _files = widget.controller.biggest(widget.node);
    }
    return FutureBuilder<List<EntryMsg>>(
      future: _files,
      builder: (context, snap) {
        final files = snap.data;
        if (files == null) return const SizedBox.shrink();
        return ListView(children: [
          for (final e in files)
            ListTile(
              key: ValueKey('gros-${e.path}'),
              leading: const Icon(Icons.insert_drive_file_rounded),
              title: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(parentOf(e.path), maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: Text(Fr.humanSize(e.size)),
              onTap: widget.sourceId == null
                  ? null
                  : () => openExplorer(context, widget.state, widget.sourceId!, path: parentOf(e.path)),
            ),
        ]);
      },
    );
  }
}

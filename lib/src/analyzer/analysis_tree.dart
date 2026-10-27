import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../bridge/fluluks_api.g.dart';
import '../strings_fr.dart';
import '../ui/tokens.dart';
import 'analyzer_controller.dart';
import 'chart_info_strip.dart';

/// Icône d'un nœud de l'analyse.
IconData analysisNodeIcon(String kind) => switch (kind) {
      'dir' => Icons.folder_rounded,
      'trash' => Icons.delete_outline_rounded,
      'file' => Icons.insert_drive_file_rounded,
      'others' => Icons.more_horiz_rounded,
      'unscanned' => Icons.apps_rounded,
      'inaccessible' => Icons.lock_rounded,
      'excluded' => Icons.visibility_off_rounded,
      _ => Icons.storage_rounded,
    };

/// Arbre du nœud affiché (phase 16) : ses enfants triés ([sort] : `size`, `name`, `items`, `date`), dépliables, par
/// pages de 200 (« Afficher plus ») ; chaque ligne montre le nom et la place, puis une barre de sa part dans son parent,
/// le pourcentage, les éléments et la date. Toucher un dossier y entre (le graphique suit), un autre élément le
/// choisit ; appui long ou bouton « Actions » : [onMenu].
class AnalysisTree extends StatefulWidget {
  const AnalysisTree({super.key, required this.controller, required this.sort, required this.onMenu});

  final AnalyzerController controller;
  final String sort;
  final ValueChanged<AnalysisNodeMsg> onMenu;

  @override
  State<AnalysisTree> createState() => _AnalysisTreeState();
}

class _Kids {
  final nodes = <AnalysisNodeMsg>[];
  bool more = false;
  bool loading = false;
}

class _AnalysisTreeState extends State<AnalysisTree> {
  final _kids = <int, _Kids>{};
  final _open = <int>{};
  final _parents = <int, AnalysisNodeMsg>{};
  Object? _for; // vue pour laquelle les pages sont chargées

  AnalyzerController get c => widget.controller;

  @override
  void didUpdateWidget(AnalysisTree old) {
    super.didUpdateWidget(old);
    if (old.sort != widget.sort) _reset();
  }

  void _reset() {
    _kids.clear();
    _open.clear();
    _parents.clear();
    _for = c.view;
  }

  Future<void> _load(int node, {bool more = false}) async {
    final k = _kids.putIfAbsent(node, _Kids.new);
    if (k.loading) return;
    k.loading = true;
    final page = await c.children(node, sort: widget.sort, offset: more ? k.nodes.length : 0);
    if (!mounted || !identical(_kids[node], k)) return;
    setState(() {
      if (!more) k.nodes.clear();
      k.nodes.addAll(page);
      k.more = page.length >= analyzerPage;
      k.loading = false;
      for (final n in page) {
        _parents[n.id] = _byId(node) ?? n;
      }
    });
  }

  AnalysisNodeMsg? _byId(int id) {
    if (c.displayed?.id == id) return c.displayed;
    for (final k in _kids.values) {
      for (final n in k.nodes) {
        if (n.id == id) return n;
      }
    }
    return null;
  }

  /// Ancêtres de [n] depuis le nœud affiché (exclu), lui compris.
  List<AnalysisNodeMsg> _chain(AnalysisNodeMsg n) {
    final out = [n];
    var p = _parents[n.id];
    while (p != null && p.id != c.displayed?.id) {
      out.insert(0, p);
      p = _parents[p.id];
    }
    return out;
  }

  bool _enterable(AnalysisNodeMsg n) => (n.kind == 'dir' || n.kind == 'trash') && n.hasChildren;

  void _toggle(AnalysisNodeMsg n) {
    setState(() {
      if (!_open.remove(n.id)) {
        _open.add(n.id);
        if (!_kids.containsKey(n.id)) _load(n.id);
      }
    });
  }

  void _tap(AnalysisNodeMsg n) {
    if (_enterable(n)) {
      c.enter(_chain(n));
    } else {
      c.select(n.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final top = c.displayed;
    if (top == null) return const SizedBox.shrink();
    if (!identical(_for, c.view)) _reset();
    if (!_kids.containsKey(top.id)) {
      _kids[top.id] = _Kids();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load(top.id);
      });
    }
    final rows = <Widget>[];
    void add(AnalysisNodeMsg parent, int level) {
      final k = _kids[parent.id];
      if (k == null) return;
      for (final n in k.nodes) {
        final open = _open.contains(n.id);
        rows.add(_TreeRow(
          key: ValueKey('ligne-${n.id}'),
          node: n,
          parent: parent,
          rootLabel: c.view?.rootLabel,
          level: level,
          open: open,
          selected: c.selected == n.id,
          canEnter: _enterable(n),
          onTap: () => _tap(n),
          onToggle: _enterable(n) ? () => _toggle(n) : null,
          onMenu: () => widget.onMenu(n),
        ));
        if (open) add(n, level + 1);
      }
      if (k.more) {
        rows.add(Padding(
          padding: EdgeInsetsDirectional.only(start: Space.l + 16.0 * level.clamp(0, 4)),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(onPressed: () => _load(parent.id, more: true), child: const Text(Fr.showMore)),
          ),
        ));
      }
    }

    add(top, 0);
    return ListView(children: rows);
  }
}

class _TreeRow extends StatelessWidget {
  const _TreeRow({
    super.key,
    required this.node,
    required this.parent,
    required this.rootLabel,
    required this.level,
    required this.open,
    required this.selected,
    required this.canEnter,
    required this.onTap,
    required this.onToggle,
    required this.onMenu,
  });

  final AnalysisNodeMsg node, parent;
  final String? rootLabel;
  final int level;
  final bool open, selected, canEnter;
  final VoidCallback onTap, onMenu;
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = theme.colorScheme;
    final name = analysisNodeName(node, rootLabel: rootLabel);
    final parentName = analysisNodeName(parent, rootLabel: rootLabel);
    final pct = analysisPercent(node, parent);
    final showItems = node.kind != 'file' && node.kind != 'unscanned';
    final details = [
      Fr.percent(pct),
      if (showItems) Fr.analysisItems(node.items),
      if (node.mtime > 0) Fr.friendlyDate(node.mtime),
      if (node.kind == 'inaccessible') Fr.analysisInaccessible,
    ].join(' · ');
    return Semantics(
      label: Fr.analysisRow(name, node.kind, node.alloc, pct, parentName, showItems ? node.items : null,
          node.mtime > 0 ? node.mtime : null),
      selected: selected,
      button: true,
      onTap: onTap,
      onTapHint: canEnter ? Fr.open : null,
      customSemanticsActions: {
        CustomSemanticsAction(label: open ? Fr.collapse : Fr.expand): ?onToggle,
        const CustomSemanticsAction(label: Fr.actions): onMenu,
      },
      excludeSemantics: true,
      child: Material(
        color: selected ? s.secondaryContainer : s.secondaryContainer.withValues(alpha: 0),
        child: InkWell(
          onTap: onTap,
          onLongPress: onMenu,
          child: Padding(
            padding: EdgeInsetsDirectional.only(start: 16.0 * level.clamp(0, 4)),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: Layout.minTouch),
              child: Row(children: [
                SizedBox(
                  width: Layout.minTouch,
                  child: onToggle == null
                      ? null
                      : IconButton(
                          tooltip: open ? Fr.collapse : Fr.expand,
                          icon: Icon(open ? Icons.expand_more_rounded : Icons.chevron_right_rounded),
                          onPressed: onToggle,
                        ),
                ),
                Icon(analysisNodeIcon(node.kind), color: s.onSurfaceVariant),
                const SizedBox(width: Space.m),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: Space.s),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, spacing: Space.xs, children: [
                      Row(children: [
                        Expanded(
                          child: Text(name, style: theme.textTheme.bodyLarge, maxLines: 1, overflow: TextOverflow.ellipsis),
                        ),
                        const SizedBox(width: Space.s),
                        Text(Fr.humanSize(node.alloc), style: theme.textTheme.bodyMedium),
                      ]),
                      Row(children: [
                        SizedBox(
                          width: 64,
                          child: LinearProgressIndicator(value: pct / 100, borderRadius: BorderRadius.circular(2)),
                        ),
                        const SizedBox(width: Space.s),
                        Expanded(
                          child: Text(details,
                              style: theme.textTheme.bodySmall?.copyWith(color: s.onSurfaceVariant),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                        ),
                      ]),
                    ]),
                  ),
                ),
                IconButton(tooltip: Fr.actions, icon: const Icon(Icons.more_vert_rounded), onPressed: onMenu),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

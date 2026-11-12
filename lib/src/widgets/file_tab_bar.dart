import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../screens/explorer_screen.dart' show nameOf;
import '../state/app_state.dart';
import '../state/files_tabs.dart';
import '../strings_fr.dart';
import '../ui/sheets.dart';
import '../ui/tokens.dart';
import 'source_tile.dart';

/// Nom d'un onglet : le dossier ouvert, le nom du stockage à sa racine, « Fichiers » sur l'accueil.
String fileTabTitle(AppState state, FileTab t) {
  final p = t.place;
  if (p == null) return Fr.moduleFiles;
  if (p.path == '/') return state.sourceById(p.sourceId)?.label ?? Fr.moduleFiles;
  return nameOf(p.path);
}

IconData _icon(AppState state, FileTab t) {
  final p = t.place;
  if (p == null) return Icons.home_rounded;
  return sourceIcon(state.sourceById(p.sourceId)?.kind ?? '');
}

/// Barre d'onglets du module Fichiers (phase 17, spec § 29), au-dessus des pages dès deux onglets : un onglet par
/// dossier ouvert, avec sa croix, et + pour ouvrir l'accueil dans un nouvel onglet. Elle défile quand les onglets ne
/// tiennent pas ; l'onglet affiché est ramené en vue.
class FileTabBar extends StatefulWidget {
  const FileTabBar({super.key, required this.state, required this.tabs, required this.onNew});

  final AppState state;
  final FilesTabs tabs;
  final VoidCallback onNew;

  @override
  State<FileTabBar> createState() => _FileTabBarState();
}

class _FileTabBarState extends State<FileTabBar> {
  final _keys = <int, GlobalKey>{};
  int _shown = -1;

  FilesTabs get _tabs => widget.tabs;

  /// Après l'image : l'onglet affiché, s'il a changé, est ramené en vue.
  void _reveal() {
    final id = _tabs.active.id;
    if (id == _shown) return;
    _shown = id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final c = _keys[id]?.currentContext;
      if (c == null || !mounted) return;
      Scrollable.ensureVisible(c, duration: Motion.of(context, Motion.medium), curve: Motion.standard, alignment: 0.5);
    });
  }

  Future<void> _menu(FileTab t) async {
    final a = await showActionSheet<String>(context, title: fileTabTitle(widget.state, t), actions: [
      const SheetAction('close', Icons.close_rounded, Fr.closeTab),
      const SheetAction('others', Icons.tab_unselected_rounded, Fr.closeOtherTabs),
    ]);
    switch (a) {
      case 'close':
        _tabs.close(t);
      case 'others':
        _tabs.closeOthers(t);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // la barre couvre la barre d'état, à la place de la barre d'application : c'est elle qui en donne les icônes,
    // claires ou sombres selon le thème
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: theme.appBarTheme.systemOverlayStyle ??
          (theme.brightness == Brightness.light ? SystemUiOverlayStyle.dark : SystemUiOverlayStyle.light),
      child: ListenableBuilder(
        listenable: Listenable.merge([_tabs, widget.state]),
        builder: (context, _) {
          final all = _tabs.tabs;
          _keys.removeWhere((id, _) => !all.any((t) => t.id == id));
          _reveal();
          return Material(
            color: scheme.surfaceContainer,
            child: SafeArea(
              bottom: false,
              child: Row(children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: Space.xs),
                    child: Row(children: [
                      for (final (i, t) in all.indexed)
                        _FileTabChip(
                          key: _keys.putIfAbsent(t.id, GlobalKey.new),
                          title: fileTabTitle(widget.state, t),
                          icon: _icon(widget.state, t),
                          index: i,
                          count: all.length,
                          selected: t == _tabs.active,
                          onTap: () => _tabs.activate(t),
                          onClose: () => _tabs.close(t),
                          onMenu: () => _menu(t),
                        ),
                    ]),
                  ),
                ),
                IconButton(
                  tooltip: _tabs.canOpen ? Fr.newTab : Fr.tabsFull,
                  icon: const Icon(Icons.add_rounded),
                  onPressed: _tabs.canOpen ? widget.onNew : null,
                ),
              ]),
            ),
          );
        },
      ),
    );
  }
}

/// Un onglet : icône du stockage, nom (coupé par des points de suspension), croix. TalkBack lit « Onglet 2 sur 3,
/// Films » ; la croix « Fermer l'onglet Films ».
class _FileTabChip extends StatelessWidget {
  const _FileTabChip({
    super.key,
    required this.title,
    required this.icon,
    required this.index,
    required this.count,
    required this.selected,
    required this.onTap,
    required this.onClose,
    required this.onMenu,
  });

  final String title;
  final IconData icon;
  final int index, count;
  final bool selected;
  final VoidCallback onTap, onClose, onMenu;

  static const maxWidth = 200.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fg = selected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Space.xs / 2, vertical: Space.xs / 2),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: maxWidth),
        child: Material(
          color: scheme.secondaryContainer.withValues(alpha: selected ? 1 : 0),
          shape: const StadiumBorder(),
          clipBehavior: Clip.antiAlias,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Flexible(
              child: Semantics(
                container: true,
                button: true,
                selected: selected,
                label: Fr.tabLabel(index + 1, count, title),
                onTap: onTap,
                onLongPress: onMenu,
                excludeSemantics: true,
                child: InkWell(
                  onTap: onTap,
                  onLongPress: onMenu,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 48),
                    child: Padding(
                      padding: const EdgeInsetsDirectional.only(start: Space.m),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(icon, size: 18, color: fg),
                        const SizedBox(width: Space.s),
                        Flexible(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelLarge!.copyWith(color: fg),
                          ),
                        ),
                      ]),
                    ),
                  ),
                ),
              ),
            ),
            IconButton(
              tooltip: Fr.closeTabNamed(title),
              iconSize: 18,
              color: fg,
              icon: const Icon(Icons.close_rounded),
              onPressed: onClose,
            ),
          ]),
        ),
      ),
    );
  }
}

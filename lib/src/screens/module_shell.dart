import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../ai/ai_home_screen.dart';
import '../analyzer/analyzer_home_screen.dart';
import '../state/app_state.dart';
import '../strings_fr.dart';
import '../ui/tokens.dart';
import '../widgets/bottom_dock.dart';
import 'home_screen.dart';
import 'remote_home_screen.dart';
import 'settings_screen.dart';
import 'vaults_home_screen.dart';

/// Modules de Portail, dans l'ordre de la barre de navigation (spec § 27).
enum PortailModule { files, vaults, analyzer, remote, ai }

/// Réglages, Aide et À propos : barre de titre de la racine de chaque module.
List<Widget> moduleActions(BuildContext context, AppState state) => [
      IconButton(
        tooltip: Fr.settings,
        icon: const Icon(Icons.settings_rounded),
        onPressed: () =>
            Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SettingsScreen(state: state))),
      ),
      PopupMenuButton<void Function()>(
        tooltip: Fr.moreOptions,
        icon: const Icon(Icons.more_vert_rounded),
        onSelected: (open) => open(),
        itemBuilder: (context) => [
          PopupMenuItem(value: () => openHelp(context), child: const Text(Fr.help)),
          PopupMenuItem(value: () => openAbout(context, state), child: const Text(Fr.about)),
        ],
      ),
    ];

/// Coquille des modules (phase 16, T1 ; Coffres depuis le 2026-10-27) : une barre de navigation en bas (un rail à
/// gauche dès 600 dp de large, défilant s'il ne tient pas en hauteur) et une pile de navigation par module, gardée
/// quand on passe à un autre. Toucher le module déjà choisi ramène à sa racine ; Retour dépile le module, puis ramène
/// à Fichiers, puis laisse Android fermer Portail. Les pages plein écran (visionneuses, éditeur, terminal,
/// conversation, lecture en cours) s'ouvrent sur le navigateur de l'application, au-dessus de la barre. Le dock du
/// cadre (lecteur réduit, opération en cours) se pose au-dessus de la barre.
class ModuleShell extends StatefulWidget {
  const ModuleShell({super.key, required this.state});

  final AppState state;

  static ModuleShellState of(BuildContext context) => maybeOf(context)!;

  /// Coquille qui contient [context] ; null pour une page plein écran ou un écran monté seul.
  static ModuleShellState? maybeOf(BuildContext context) => context.findAncestorStateOfType<ModuleShellState>();

  @override
  State<ModuleShell> createState() => ModuleShellState();
}

class ModuleShellState extends State<ModuleShell> with SingleTickerProviderStateMixin {
  AppState get _state => widget.state;

  final _navigators = {for (final m in PortailModule.values) m: GlobalKey<NavigatorState>()};
  final _heroes = {for (final m in PortailModule.values) m: MaterialApp.createMaterialHeroController()};

  /// Modules déjà montrés : leur pile est construite au premier passage, puis gardée.
  final _built = {PortailModule.files};
  PortailModule _current = PortailModule.files;

  /// Fondu d'un module à l'autre.
  late final _fade = AnimationController(vsync: this, value: 1);

  DockSlot? _slot;
  Animation<double>? _covering;

  /// Disques déjà vus : un disque branché (intention USB) ramène à Fichiers, où il apparaît.
  late Set<String> _disks = {for (final d in _state.disks) d.id};

  PortailModule get current => _current;

  /// Module dont la pile contient [context] ; null pour une page plein écran (navigateur de l'application).
  PortailModule? moduleOf(BuildContext context) {
    final nav = Navigator.maybeOf(context);
    for (final m in PortailModule.values) {
      if (_navigators[m]!.currentState == nav) return m;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _state.addListener(_stateChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final slot = DockHost.maybeOf(context)?.slot;
    if (slot != _slot) {
      _slot?.removeListener(_dockChanged);
      _slot?.embedded = false;
      _slot = slot?..addListener(_dockChanged);
    }
    // une page posée sur la coquille anime sa transition secondaire : le dock repasse alors au cadre
    final covering = ModalRoute.of(context)?.secondaryAnimation;
    if (covering != _covering) {
      _covering?.removeStatusListener(_coverChanged);
      _covering = covering?..addStatusListener(_coverChanged);
    }
    _coverChanged(_covering?.status ?? AnimationStatus.dismissed);
  }

  @override
  void dispose() {
    _state.removeListener(_stateChanged);
    _covering?.removeStatusListener(_coverChanged);
    _slot
      ?..removeListener(_dockChanged)
      ..embedded = false;
    for (final h in _heroes.values) {
      h.dispose();
    }
    _fade.dispose();
    super.dispose();
  }

  void _coverChanged(AnimationStatus status) => _slot?.embedded = status.isDismissed;

  void _dockChanged() {
    if (mounted) setState(() {});
  }

  void _stateChanged() {
    final disks = {for (final d in _state.disks) d.id};
    final plugged = disks.difference(_disks).isNotEmpty;
    _disks = disks;
    if (plugged && mounted) select(PortailModule.files);
  }

  /// Montre le module [m], sur la page où on l'avait laissé.
  void select(PortailModule m) {
    if (m == _current) return;
    setState(() {
      _current = m;
      _built.add(m);
    });
    _fade
      ..duration = Motion.of(context, Motion.short)
      ..forward(from: 0);
  }

  /// Choisit le module [m], puis empile [route] sur sa pile.
  Future<T?> push<T extends Object?>(PortailModule m, Route<T> route) async {
    select(m);
    if (_navigators[m]!.currentState == null) await WidgetsBinding.instance.endOfFrame;
    return _navigators[m]!.currentState!.push(route);
  }

  void _tap(int i) {
    final m = PortailModule.values[i];
    if (m == _current) {
      _navigators[m]!.currentState?.popUntil((r) => r.isFirst);
    } else {
      select(m);
    }
  }

  Future<void> _back() async {
    final nav = _navigators[_current]!.currentState;
    if (nav != null && await nav.maybePop()) return;
    if (_current != PortailModule.files) {
      select(PortailModule.files);
      return;
    }
    await SystemNavigator.pop();
  }

  Widget _root(PortailModule m) => switch (m) {
        PortailModule.files => HomeScreen(state: _state),
        PortailModule.vaults => VaultsHomeScreen(state: _state),
        PortailModule.analyzer => AnalyzerHomeScreen(state: _state),
        PortailModule.remote => RemoteHomeScreen(state: _state),
        PortailModule.ai => AiHomeScreen(state: _state),
      };

  Widget _module(PortailModule m) {
    if (!_built.contains(m)) return const SizedBox.shrink();
    // module masqué : gardé, mais ni dessiné, ni touché, ni lu par TalkBack, ni animé
    final shown = m == _current;
    return Offstage(
      offstage: !shown,
      child: TickerMode(
        enabled: shown,
        child: ExcludeFocus(
          excluding: !shown,
          child: HeroControllerScope(
            controller: _heroes[m]!,
            child: Navigator(
              key: _navigators[m],
              onGenerateRoute: (settings) =>
                  MaterialPageRoute<void>(settings: settings, builder: (_) => _root(m)),
            ),
          ),
        ),
      ),
    );
  }

  /// Une analyse pour l'Analyseur, une session SSH (et ses tunnels) pour Distants, une réponse ou une automatisation
  /// pour l'IA.
  bool _busy(PortailModule m) => switch (m) {
        PortailModule.files || PortailModule.vaults => false,
        PortailModule.analyzer => _state.analysisProgress?.running ?? false,
        PortailModule.remote => _state.terminals.sessions.any((e) => !e.isClosed),
        PortailModule.ai => _state.chats.busy || _state.automations.busy,
      };

  static String _label(PortailModule m) => switch (m) {
        PortailModule.files => Fr.moduleFiles,
        PortailModule.vaults => Fr.moduleVaults,
        PortailModule.analyzer => Fr.moduleAnalyzer,
        PortailModule.remote => Fr.moduleRemote,
        PortailModule.ai => Fr.moduleAi,
      };

  static (IconData, IconData) _icons(PortailModule m) => switch (m) {
        PortailModule.files => (Icons.folder_outlined, Icons.folder_rounded),
        PortailModule.vaults => (Icons.lock_outline_rounded, Icons.lock_rounded),
        PortailModule.analyzer => (Icons.pie_chart_outline_rounded, Icons.pie_chart_rounded),
        PortailModule.remote => (Icons.cloud_outlined, Icons.cloud_rounded),
        PortailModule.ai => (Icons.smart_toy_outlined, Icons.smart_toy_rounded),
      };

  /// Plus grande taille de texte (1 au moins) à laquelle chaque libellé de la barre tient dans sa case : au-delà, avec
  /// cinq modules sur un téléphone étroit, les libellés se chevaucheraient. TalkBack les lit en entier.
  double _barTextScale(BuildContext context) {
    final theme = Theme.of(context);
    final states = NavigationBarTheme.of(context).labelTextStyle;
    final styles = [
      for (final s in [<WidgetState>{}, {WidgetState.selected}]) states?.resolve(s) ?? theme.textTheme.labelMedium,
    ];
    var widest = 0.0;
    for (final m in PortailModule.values) {
      for (final style in styles) {
        final tp = TextPainter(text: TextSpan(text: _label(m), style: style), textDirection: TextDirection.ltr)..layout();
        widest = math.max(widest, tp.width);
        tp.dispose();
      }
    }
    final slot = MediaQuery.sizeOf(context).width / PortailModule.values.length - Space.s;
    return widest <= 0 ? 1 : math.max(1, slot / widest);
  }

  /// Icône d'un module, avec un point quand une activité y est en cours (lu par TalkBack).
  Widget _icon(PortailModule m, {required bool selected}) {
    final (off, on) = _icons(m);
    final icon = Icon(selected ? on : off);
    if (!_busy(m)) return icon;
    return Semantics(label: Fr.moduleBusy(_label(m)), child: Badge(smallSize: 8, child: icon));
  }

  @override
  Widget build(BuildContext context) {
    final keyboard = MediaQuery.viewInsetsOf(context).bottom > 0;
    final rail = MediaQuery.sizeOf(context).width >= Layout.medium;
    final dock = keyboard || !(_slot?.embedded ?? false) ? const <Widget>[] : _slot!.bars;
    final modules = FadeTransition(
      opacity: _fade,
      child: Stack(fit: StackFit.expand, children: [for (final m in PortailModule.values) _module(m)]),
    );
    final activity = Listenable.merge([_state, _state.terminals, _state.chats, _state.automations]);
    final Widget body;
    if (rail) {
      body = Row(children: [
        ListenableBuilder(
          listenable: activity,
          builder: (context, _) => SafeArea(
            right: false,
            child: _RailFit(
              child: NavigationRail(
                selectedIndex: _current.index,
                onDestinationSelected: _tap,
                labelType: NavigationRailLabelType.all,
                destinations: [
                  for (final m in PortailModule.values)
                    NavigationRailDestination(
                      icon: _icon(m, selected: false),
                      selectedIcon: _icon(m, selected: true),
                      label: Text(_label(m), maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                ],
              ),
            ),
          ),
        ),
        // Conteneur sémantique : la barrière des pages d'un module (BlockSemantics) cacherait sinon à TalkBack le rail,
        // peint avant elle.
        Expanded(
          child: Semantics(
            container: true,
            child: Column(children: [
              Expanded(
                child: MediaQuery.removePadding(
                  context: context,
                  removeLeft: true,
                  removeBottom: dock.isNotEmpty,
                  child: modules,
                ),
              ),
              DockSurface(children: dock),
            ]),
          ),
        ),
      ]);
    } else {
      body = Column(children: [
        Expanded(
          child: MediaQuery.removePadding(context: context, removeBottom: !keyboard, child: modules),
        ),
        if (!keyboard) ...[
          MediaQuery.removePadding(context: context, removeBottom: true, child: DockSurface(children: dock)),
          ListenableBuilder(
            listenable: activity,
            builder: (context, _) => MediaQuery.withClampedTextScaling(
              maxScaleFactor: _barTextScale(context),
              child: NavigationBar(
                selectedIndex: _current.index,
                onDestinationSelected: _tap,
                labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
                destinations: [
                  for (final m in PortailModule.values)
                    NavigationDestination(
                      icon: _icon(m, selected: false),
                      selectedIcon: _icon(m, selected: true),
                      label: _label(m),
                    ),
                ],
              ),
            ),
          ),
        ],
      ]);
    }
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Material(color: Theme.of(context).colorScheme.surface, child: body),
    );
  }
}

/// Rail entier s'il tient en hauteur ; sinon (paysage et grand texte), défilant. Sa hauteur naturelle est mesurée à
/// chaque mise en page : le cas courant reste un rail simple, sans zone de défilement de plus pour TalkBack.
class _RailFit extends StatefulWidget {
  const _RailFit({required this.child});

  final Widget child;

  @override
  State<_RailFit> createState() => _RailFitState();
}

class _RailFitState extends State<_RailFit> {
  bool _scroll = false;

  void _measured(bool tooTall) {
    if (tooTall == _scroll) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _scroll = tooTall);
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final rail = _HeightProbe(available: c.maxHeight, onMeasured: _measured, child: widget.child);
      if (!_scroll) return rail;
      return SingleChildScrollView(
        child: ConstrainedBox(constraints: BoxConstraints(minHeight: c.maxHeight), child: IntrinsicHeight(child: rail)),
      );
    });
  }
}

/// Signale, à la mise en page, si la hauteur naturelle de son enfant dépasse [available] (la hauteur de l'écran pour
/// le rail, qu'il défile déjà ou non). L'enfant reçoit toujours au moins sa hauteur naturelle, coupée à la peinture :
/// rien ne déborde pendant l'image qui précède le passage au défilement.
class _HeightProbe extends SingleChildRenderObjectWidget {
  const _HeightProbe({required this.available, required this.onMeasured, required super.child});

  final double available;
  final ValueChanged<bool> onMeasured;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderHeightProbe(available, onMeasured);

  @override
  void updateRenderObject(BuildContext context, _RenderHeightProbe renderObject) => renderObject
    ..available = available
    ..onMeasured = onMeasured;
}

class _RenderHeightProbe extends RenderProxyBox {
  _RenderHeightProbe(this._available, this.onMeasured);

  double _available;
  set available(double v) {
    if (v == _available) return;
    _available = v;
    markNeedsLayout();
  }

  ValueChanged<bool> onMeasured;

  @override
  void performLayout() {
    final c = child;
    if (c == null) {
      size = constraints.smallest;
      return;
    }
    final natural = c.getMaxIntrinsicHeight(constraints.maxWidth);
    final h = math.max(natural, constraints.hasBoundedHeight ? constraints.maxHeight : constraints.minHeight);
    c.layout(constraints.copyWith(minHeight: h, maxHeight: h), parentUsesSize: true);
    size = constraints.constrain(c.size);
    if (_available.isFinite) onMeasured(natural > _available + 0.5);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final c = child;
    if (c == null) return;
    if (c.size.height <= size.height + 0.5) {
      layer = null;
      context.paintChild(c, offset);
    } else {
      layer = context.pushClipRect(needsCompositing, offset, Offset.zero & size, super.paint,
          oldLayer: layer as ClipRectLayer?);
    }
  }
}

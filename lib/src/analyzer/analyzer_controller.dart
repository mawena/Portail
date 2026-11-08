import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../bridge/fluluks_api.g.dart';
import '../state/app_state.dart';
import '../state/prefs.dart';
import '../strings_fr.dart';

/// Graphique de l'analyseur : anneaux concentriques, carte proportionnelle, ou aucun (arbre seul).
enum ChartKind { rings, treemap, none }

/// Nombre maximal de nœuds demandés pour une vue des graphiques.
const analyzerMaxNodes = 1500;

/// Taille d'une page d'enfants de l'arbre.
const analyzerPage = 200;

/// État de l'écran d'une analyse (phase 16) : vue du nœud affiché, fil d'Ariane, profondeur et graphique (gardés dans
/// les préférences), élément choisi. Pendant l'analyse, la vue est rechargée au plus toutes les [refresh], puis une
/// fois à la fin. Dart ne reçoit jamais l'arbre entier : des vues de [analyzerMaxNodes] nœuds et des pages d'enfants.
class AnalyzerController extends ChangeNotifier {
  AnalyzerController(this.state, {this.refresh = const Duration(milliseconds: 500)}) {
    state.addListener(_onState);
  }

  final AppState state;
  final Duration refresh;

  String? _scanId;
  String? _sourceId;
  String? _path;
  AnalysisViewMsg? _view;
  String _rootLabel = '';
  final _trail = <AnalysisNodeMsg>[];
  int? _selected;
  String? _error;
  AnalysisProgressMsg? _seen;
  Timer? _timer;
  bool _pending = false;
  bool _disposed = false;

  String? get scanId => _scanId;
  AnalysisViewMsg? get view => _view;

  /// Libellé de la racine de l'analyse (stockage ou dossier analysé), gardé quand on descend.
  String get rootLabel => _rootLabel;

  /// Racine de l'analyse → nœud affiché.
  List<AnalysisNodeMsg> get trail => List.unmodifiable(_trail);
  int? get selected => _selected;

  /// Dernière erreur (analyse oubliée, suppression refusée…), en français.
  String? get error => _error;
  int get depth => state.uiPrefs.analyzerLevels;
  ChartKind get chart =>
      ChartKind.values.firstWhere((k) => k.name == state.uiPrefs.analyzerChart, orElse: () => ChartKind.rings);

  /// Avancement de cette analyse, ou null.
  AnalysisProgressMsg? get progress {
    final p = state.analysisProgress;
    return p != null && p.scanId == _scanId ? p : null;
  }

  bool get running => progress?.running ?? (_view?.running ?? false);
  int get _node => _trail.isEmpty ? 0 : _trail.last.id;

  /// Lance l'analyse de [path] dans [sourceId] et montre sa racine.
  Future<void> start(String sourceId, String path) => _call(() async {
        final id = await state.api.startAnalysis(sourceId, path);
        _reset(id, sourceId, path);
        await _load(0);
      });

  /// Montre une analyse gardée.
  Future<void> open(String scanId) => _call(() async {
        final s = (await state.api.analyses()).where((a) => a.scanId == scanId).firstOrNull;
        if (s == null) throw PlatformException(code: 'ENOENT', message: Fr.analysisGone);
        _reset(scanId, s.sourceId, s.path);
        await _load(0);
      });

  void _reset(String id, String sourceId, String path) {
    _timer?.cancel();
    _timer = null;
    _pending = false;
    _scanId = id;
    _sourceId = sourceId;
    _path = path;
    _trail.clear();
    _selected = null;
    _seen = state.analysisProgress;
  }

  /// Entre dans [node] (un dossier de la vue qui a un contenu, à n'importe quel niveau).
  Future<void> zoom(int node) => _call(() async {
        final v = _view;
        if (v == null || node == _node || node < 0) return;
        final byId = {for (final n in v.nodes) n.id: n};
        final target = byId[node];
        if (target == null || !target.hasChildren || (target.kind != 'dir' && target.kind != 'trash')) return;
        final chain = <AnalysisNodeMsg>[];
        for (var c = byId[node]; c != null && c.id != v.root; c = byId[c.parent]) {
          chain.insert(0, c);
        }
        if (chain.isEmpty) return;
        _trail.addAll(chain);
        _selected = null;
        await _load(node);
      });

  /// Entre dans le dernier dossier de [chain] : ses ancêtres depuis le nœud affiché (exclu), lui compris ; pour une
  /// ligne de l'arbre, qui peut être sous la profondeur de la vue.
  Future<void> enter(List<AnalysisNodeMsg> chain) => _call(() async {
        if (_view == null || chain.isEmpty) return;
        final target = chain.last;
        if (!target.hasChildren || (target.kind != 'dir' && target.kind != 'trash')) return;
        _trail.addAll(chain);
        _selected = null;
        await _load(target.id);
      });

  /// Nœud affiché (racine de la vue), ou null.
  AnalysisNodeMsg? get displayed => _trail.isEmpty ? null : _trail.last;

  /// Remonte d'un niveau.
  Future<void> up() async {
    if (_trail.length > 1) await goTo(_trail.length - 2);
  }

  /// Revient à l'élément [index] du fil d'Ariane.
  Future<void> goTo(int index) => _call(() async {
        if (index < 0 || index >= _trail.length - 1) return;
        _trail.removeRange(index + 1, _trail.length);
        _selected = null;
        await _load(_node);
      });

  /// Profondeur des graphiques, de 2 à 8, gardée dans les préférences.
  Future<void> setDepth(int d) async {
    final v = d.clamp(analyzerDepthMin, analyzerDepthMax);
    if (v == depth) return;
    await state.setUiPrefs(state.uiPrefs.copyWith(analyzerDepth: v));
    if (_scanId != null) await _call(() => _load(_node));
    notifyListeners();
  }

  Future<void> setChart(ChartKind k) async {
    await state.setUiPrefs(state.uiPrefs.copyWith(analyzerChart: k.name));
    notifyListeners();
  }

  void select(int? node) {
    if (_selected == node) return;
    _selected = node;
    notifyListeners();
  }

  /// Page d'enfants de [node] pour l'arbre (`size`, `name`, `items` ou `date`).
  Future<List<AnalysisNodeMsg>> children(int node, {String sort = 'size', int offset = 0}) async {
    final id = _scanId;
    if (id == null) return const [];
    try {
      return await state.api.analysisChildren(id, node, sort, offset, analyzerPage);
    } on PlatformException catch (e) {
      _fail(e);
      return const [];
    }
  }

  /// Plus gros fichiers sous [node].
  Future<List<EntryMsg>> biggest(int node) async {
    final id = _scanId;
    if (id == null) return const [];
    try {
      return await state.api.analysisBiggest(id, node);
    } on PlatformException catch (e) {
      _fail(e);
      return const [];
    }
  }

  /// Corbeille ou suppression définitive ; la vue suit sans réanalyse.
  Future<void> delete(int node, {required bool permanent}) => _call(() async {
        final id = _scanId;
        if (id == null) return;
        await state.api.analysisDelete(id, node, permanent);
        _selected = null;
        await _load(_node);
      });

  /// Exclut [node] des analyses suivantes de ce stockage.
  Future<void> exclude(int node) => _call(() async {
        final id = _scanId;
        if (id == null) return;
        await state.api.analysisExclude(id, node);
        _selected = null;
        await _load(_node);
      });

  /// Nouvelle analyse du même emplacement.
  Future<void> rescan() async {
    final (s, p) = (_sourceId, _path);
    if (s != null && p != null) await start(s, p);
  }

  void _onState() {
    final p = state.analysisProgress;
    if (identical(p, _seen) || p == null || p.scanId != _scanId) return;
    _seen = p;
    if (!p.running) {
      _timer?.cancel();
      _timer = null;
      _pending = false;
      unawaited(_call(() => _load(_node)));
      return;
    }
    if (_timer != null) {
      _pending = true;
      return;
    }
    unawaited(_call(() => _load(_node)));
    _timer = Timer(refresh, _tick);
  }

  void _tick() {
    _timer = null;
    if (!_pending || _disposed) return;
    _pending = false;
    unawaited(_call(() => _load(_node)));
    _timer = Timer(refresh, _tick);
  }

  Future<void> _load(int node) async {
    final id = _scanId;
    if (id == null) return;
    final v = await state.api.analysisView(id, node, depth, analyzerMaxNodes);
    if (id != _scanId || _disposed) return;
    _view = v;
    final top = v.nodes.first;
    if (_trail.isEmpty || _trail.length == 1) _rootLabel = v.rootLabel;
    if (_trail.isEmpty) {
      _trail.add(top);
    } else {
      _trail[_trail.length - 1] = top;
    }
    _error = null;
  }

  Future<void> _call(Future<void> Function() action) async {
    try {
      await action();
    } on PlatformException catch (e) {
      _fail(e);
    }
    if (!_disposed) notifyListeners();
  }

  /// Une analyse oubliée par Kotlin vide le contrôleur (retour à l'accueil de l'analyseur).
  void _fail(PlatformException e) {
    _error = e.message ?? Fr.genericError;
    if (e.message == Fr.analysisGone) {
      _timer?.cancel();
      _timer = null;
      _scanId = null;
      _view = null;
      _trail.clear();
      _selected = null;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    state.removeListener(_onState);
    super.dispose();
  }
}

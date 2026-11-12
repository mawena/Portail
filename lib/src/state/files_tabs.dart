import 'dart:async';

import 'package:flutter/foundation.dart';

/// Emplacement montré par une page d'un onglet : un dossier d'un stockage.
class TabPlace {
  TabPlace(this.sourceId, this.path);

  final String sourceId;
  String path;
}

/// Onglet du module Fichiers (spec § 29) : sa pile de pages est tenue par la coquille ; il retient l'emplacement de
/// départ ([initial], null pour l'accueil de Fichiers) et ceux que ses explorateurs lui signalent.
class FileTab {
  FileTab._(this.id, this.initial);

  final int id;
  final TabPlace? initial;

  /// Explorateurs ouverts dans l'onglet, dans l'ordre de la pile.
  final _places = <TabPlace>[];

  /// Dossier montré par l'explorateur du haut de la pile ; null sur l'accueil.
  TabPlace? get place => _places.isEmpty ? null : _places.last;
}

/// Onglets du module Fichiers, le temps de la session : l'onglet affiché, l'ordre dans lequel ils l'ont été (fermer
/// l'affiché montre le précédent), [max] au plus. Il en reste toujours un.
class FilesTabs extends ChangeNotifier {
  FilesTabs() {
    _tabs.add(FileTab._(_nextId++, null));
    _order.add(_tabs.single);
  }

  static const max = 8;

  final _tabs = <FileTab>[];

  /// Onglets du plus anciennement au plus récemment affiché : le dernier est l'affiché.
  final _order = <FileTab>[];
  int _nextId = 0;
  bool _pending = false;
  bool _disposed = false;

  List<FileTab> get tabs => List.unmodifiable(_tabs);
  FileTab get active => _order.last;
  int get activeIndex => _tabs.indexOf(active);
  bool get canOpen => _tabs.length < max;

  /// Ouvre un onglet à la fin, sur [at] (l'accueil sinon), et l'affiche ; null s'il y en a déjà [max].
  FileTab? open({TabPlace? at}) {
    if (!canOpen) return null;
    final t = FileTab._(_nextId++, at);
    _tabs.add(t);
    _order.add(t);
    notifyListeners();
    return t;
  }

  void activate(FileTab t) {
    if (t == active || !_tabs.contains(t)) return;
    _order
      ..remove(t)
      ..add(t);
    notifyListeners();
  }

  /// Ferme [t] ; l'onglet affiché fermé laisse la place au précédent affiché. Sans effet sur le dernier onglet.
  void close(FileTab t) {
    if (_tabs.length < 2 || !_tabs.contains(t)) return;
    _tabs.remove(t);
    _order.remove(t);
    notifyListeners();
  }

  void closeOthers(FileTab keep) {
    if (_tabs.length < 2 || !_tabs.contains(keep)) return;
    _tabs
      ..clear()
      ..add(keep);
    _order
      ..clear()
      ..add(keep);
    notifyListeners();
  }

  /// Un explorateur ouvert dans [t] montre [path] de [sourceId] (appelé depuis `initState`).
  TabPlace enter(FileTab t, String sourceId, String path) {
    final p = TabPlace(sourceId, path);
    t._places.add(p);
    _notifySoon();
    return p;
  }

  /// L'explorateur de [p] montre maintenant [path].
  void moved(TabPlace p, String path) {
    if (p.path == path) return;
    p.path = path;
    notifyListeners();
  }

  /// L'explorateur de [p] est quitté (appelé depuis `dispose`).
  void leave(FileTab t, TabPlace p) {
    t._places.remove(p);
    _notifySoon();
  }

  /// Prévient après l'image en cours : `initState` et `dispose` ne peuvent pas reconstruire la barre d'onglets.
  void _notifySoon() {
    if (_pending) return;
    _pending = true;
    scheduleMicrotask(() {
      _pending = false;
      if (!_disposed) notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

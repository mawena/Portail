import 'package:flutter/widgets.dart';

import '../state/files_tabs.dart';

/// Onglet du module Fichiers qui contient une page (spec § 29) : l'explorateur lui signale le dossier qu'il montre.
class FilesTabScope extends InheritedWidget {
  const FilesTabScope({super.key, required this.tabs, required this.tab, required super.child});

  final FilesTabs tabs;
  final FileTab tab;

  /// Onglet de [context] ; null hors du module Fichiers. Lisible depuis `initState` (sans dépendance).
  static FilesTabScope? maybeOf(BuildContext context) => context.getInheritedWidgetOfExactType<FilesTabScope>();

  @override
  bool updateShouldNotify(FilesTabScope oldWidget) => tab != oldWidget.tab || tabs != oldWidget.tabs;
}

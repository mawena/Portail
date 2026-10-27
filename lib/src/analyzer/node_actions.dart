import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../bridge/fluluks_api.g.dart';
import '../screens/explorer_screen.dart';
import '../screens/trash_screen.dart';
import '../state/app_state.dart';
import '../strings_fr.dart';
import '../ui/feedback.dart';
import '../ui/sheets.dart';
import '../widgets/delete_dialog.dart';
import '../widgets/properties_sheet.dart';
import 'analyzer_controller.dart';
import 'chart_info_strip.dart';

enum _Act { open, explorer, copyPath, properties, exclude, delete, openTrash }

/// Le nœud est-il un élément réel du stockage (pas la racine de l'analyse, ni une part virtuelle, ni un dossier jamais
/// lu) ? Seuls ceux-là se suppriment ou s'excluent.
bool analysisNodeDeletable(AnalysisNodeMsg n, {required bool isRoot}) =>
    !isRoot && n.id >= 0 && (n.kind == 'dir' || n.kind == 'file');

/// Menu d'un élément de l'analyse (appui long sur une ligne ou un segment) : ouvrir, afficher dans l'explorateur,
/// copier le chemin, propriétés, exclure des analyses, supprimer ; la corbeille du stockage s'ouvre. Contenu résumé,
/// part hors analyse et dossiers non lus n'ont que leur explication.
Future<void> showNodeActions(
  BuildContext context,
  AppState state,
  AnalyzerController c,
  AnalysisNodeMsg n, {
  required String sourceId,
}) async {
  final isRoot = n.id == c.trail.firstOrNull?.id;
  final remote = c.view?.sizeKind == 'apparent';
  final name = analysisNodeName(n, rootLabel: c.view?.rootLabel);
  final help = switch (n.kind) {
    'others' => Fr.analysisOthersHelp,
    'unscanned' => Fr.analysisUnscannedHelp,
    'inaccessible' => Fr.analysisInaccessible,
    'excluded' => Fr.excludedFromAnalyses,
    'otherFs' => Fr.analysisOtherFs,
    _ => null,
  };
  final real = n.id >= 0 && n.kind != 'otherFs';
  final deletable = analysisNodeDeletable(n, isRoot: isRoot);
  final enterable = (n.kind == 'dir' || n.kind == 'trash') && n.hasChildren && n.id != c.displayed?.id;
  final act = await showActionSheet<_Act>(context, title: help == null ? name : '$name — $help', actions: [
    if (enterable) const SheetAction(_Act.open, Icons.zoom_in_rounded, Fr.open),
    if (n.kind == 'trash' && !remote) const SheetAction(_Act.openTrash, Icons.delete_outline_rounded, Fr.openTrash),
    if (real && n.kind != 'inaccessible') const SheetAction(_Act.explorer, Icons.folder_open_rounded, Fr.showInExplorer),
    if (real) const SheetAction(_Act.copyPath, Icons.content_copy_rounded, Fr.copyPath),
    if (real && (n.kind == 'dir' || n.kind == 'file')) const SheetAction(_Act.properties, Icons.info_outline_rounded, Fr.properties),
    if (deletable && n.kind == 'dir') const SheetAction(_Act.exclude, Icons.visibility_off_rounded, Fr.excludeFromAnalyses),
    if (deletable) const SheetAction(_Act.delete, Icons.delete_rounded, Fr.delete, destructive: true),
  ]);
  if (act == null || !context.mounted) return;
  switch (act) {
    case _Act.open:
      final v = c.view;
      if (v != null && v.nodes.any((e) => e.id == n.id)) {
        await c.zoom(n.id);
      } else {
        await c.enter([n]);
      }
    case _Act.openTrash:
      await openTrash(context, state, sourceId);
    case _Act.explorer:
      await openExplorer(context, state, sourceId, path: n.kind == 'file' ? parentOf(n.path) : n.path);
    case _Act.copyPath:
      await Clipboard.setData(ClipboardData(text: n.path));
      if (context.mounted) showMessage(context, Fr.pathCopied);
    case _Act.properties:
      await showProperties(context, state, sourceId, n.path, onDisk: remote ? null : n.alloc);
    case _Act.exclude:
      await c.exclude(n.id);
      if (context.mounted) showMessage(context, Fr.excludedFromAnalyses);
    case _Act.delete:
      final inTrash = n.path == '/.Portail-corbeille' || n.path.startsWith('/.Portail-corbeille/');
      final permanent = await confirmDelete(
        context,
        title: Fr.deleteSized(name, n.alloc),
        body: remote ? Fr.deleteRemoteBody : (inTrash ? Fr.deleteBody : Fr.deleteToTrashBody),
        trashOffered: !remote && !inTrash,
      );
      if (permanent == null) return;
      await c.delete(n.id, permanent: permanent);
      if (!context.mounted) return;
      final err = c.error;
      if (err != null) {
        showMessage(context, err, kind: MessageKind.error);
      } else if (!permanent) {
        showMessage(context, Fr.trashedFromAnalysis,
            actionLabel: Fr.openTrash, onAction: () => openTrash(context, state, sourceId));
      }
  }
}

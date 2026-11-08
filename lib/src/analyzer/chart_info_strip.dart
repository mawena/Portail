import 'package:flutter/material.dart';

import '../bridge/fluluks_api.g.dart';
import '../strings_fr.dart';

/// Nom montré d'un nœud de l'analyseur (contenu résumé : « Autres » ; racine : son libellé).
String analysisNodeName(AnalysisNodeMsg n, {String? rootLabel}) {
  if (n.kind == 'others') return Fr.analysisOthers;
  if (n.name.isEmpty) return rootLabel ?? n.path;
  return n.name;
}

/// Part de [n] dans [root], arrondie (0 à 100).
int analysisPercent(AnalysisNodeMsg n, AnalysisNodeMsg root) =>
    root.alloc <= 0 ? 0 : (n.alloc * 100 / root.alloc).round().clamp(0, 100);

/// Bande d'information sous le graphique, à la place du survol de Baobab : « Photos — 12,3 Go — 45 % de Téléphone —
/// 1 234 éléments », puis la taille des données quand elle s'écarte de plus de 10 % de la place occupée.
class ChartInfoStrip extends StatelessWidget {
  const ChartInfoStrip({super.key, required this.node, required this.root, required this.sizeKind, this.rootLabel});

  final AnalysisNodeMsg? node;
  final AnalysisNodeMsg root;
  final String sizeKind;
  final String? rootLabel;

  @override
  Widget build(BuildContext context) {
    final n = node ?? root;
    final t = Theme.of(context).textTheme;
    final rootName = analysisNodeName(root, rootLabel: rootLabel);
    final parts = [
      analysisNodeName(n, rootLabel: rootLabel),
      Fr.humanSize(n.alloc),
      if (!identical(n, root) && n.id != root.id) Fr.ofParent(analysisPercent(n, root), rootName),
      if (n.kind != 'unscanned' && n.kind != 'file') Fr.analysisItems(n.items),
    ];
    final differs = sizeKind == 'allocated' && n.kind != 'unscanned' && (n.alloc - n.apparent).abs() * 10 > n.alloc;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(parts.join(' — '), style: t.bodyMedium, maxLines: 2, overflow: TextOverflow.ellipsis),
          if (differs)
            Text(Fr.onDiskOfData(n.alloc, n.apparent),
                style: t.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }
}

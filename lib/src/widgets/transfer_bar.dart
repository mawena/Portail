import 'dart:async';

import 'package:flutter/material.dart';

import '../bridge/fluluks_api.g.dart';
import '../state/app_state.dart';
import '../strings_fr.dart';
import '../ui/feedback.dart';
import '../ui/tokens.dart';

/// Barre de l'opération en cours (copie, déplacement, compression, extraction, chiffrement, déchiffrement,
/// vérification) : progression et Annuler ; à la fin, le résultat pendant 4 s (8 s pour un fichier chiffré, avec
/// « Partager le fichier chiffré » et comment le destinataire l'ouvre). Une seule pour toute l'application : le cadre (`PlayerFrame`) la pose dans le dock du
/// bas, sous tous les écrans.
class TransferBar extends StatefulWidget {
  const TransferBar({super.key, required this.state});

  final AppState state;

  @override
  State<TransferBar> createState() => _TransferBarState();
}

class _TransferBarState extends State<TransferBar> {
  /// Résultat affiché après la fin ; plus longtemps quand un fichier chiffré peut être partagé.
  static const _shown = Duration(seconds: 4);
  static const _shownShare = Duration(seconds: 8);

  /// Chiffrement réussi qui a produit un seul fichier : il peut être partagé.
  bool _shareable(TransferMsg t) =>
      t.finished && !t.cancelled && t.error == null && t.kind == 'encrypt' && widget.state.lastEncrypt?.single == true;

  TransferMsg? _timed;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) {
        final t = widget.state.transfer;
        if (t == null) return const SizedBox.shrink();
        if (t.finished && !identical(t, _timed)) {
          _timed = t;
          if (!t.cancelled && t.error == null) AppHaptics.success(widget.state); // copie terminée
          _timer?.cancel();
          _timer = Timer(_shareable(t) ? _shownShare : _shown, () {
            if (identical(widget.state.transfer, t)) widget.state.transferResultSeen();
          });
        }
        final theme = Theme.of(context);
        final pct = t.totalBytes > 0 ? (t.doneBytes * 100 ~/ t.totalBytes).clamp(0, 100) : 0;
        final String text;
        // résultat : icône de réussite ou d'échec, comme les messages
        final IconData? icon = !t.finished
            ? null
            : t.error != null
                ? Icons.error_rounded
                : t.cancelled
                    ? Icons.cancel_rounded
                    : Icons.check_circle_rounded;
        if (!t.finished) {
          text = Fr.transferLine(t.kind, t.currentName, t.fileIndex, t.fileCount, pct);
        } else if (t.cancelled) {
          text = Fr.transferCancelled;
        } else if (t.error == null && t.kind == 'verify') {
          text = Fr.fileIntact;
        } else {
          text = t.error ?? Fr.transferDoneRate(t.fileIndex, t.doneBytes, t.elapsedMs);
        }
        final share = _shareable(t) ? widget.state.lastEncrypt : null;
        return Padding(
          padding: const EdgeInsets.fromLTRB(Space.l, Space.s, Space.s, Space.s),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              if (icon != null) ...[
                ExcludeSemantics(
                  child: Icon(icon, color: t.error != null ? theme.colorScheme.error : theme.colorScheme.primary),
                ),
                const SizedBox(width: Space.m),
              ],
              Expanded(
                child: Text(
                  text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: numeric(theme.textTheme.bodyMedium!),
                ),
              ),
              if (!t.finished) TextButton(onPressed: widget.state.cancelTransfer, child: const Text(Fr.cancel)),
            ]),
            if (share != null) ...[
              Text(share.format == 'zip' ? Fr.shareHintZip : Fr.shareHintAge, style: theme.textTheme.bodySmall),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: TextButton.icon(
                  onPressed: () {
                    final dir = share.dstDir == '/' ? '' : share.dstDir;
                    widget.state.api.share(share.dstId, ['$dir/${t.currentName}']);
                  },
                  icon: const Icon(Icons.share_rounded),
                  label: const Text(Fr.shareEncrypted),
                ),
              ),
            ],
            if (!t.finished) LinearProgressIndicator(value: t.totalBytes > 0 ? pct / 100 : null),
          ]),
        );
      },
    );
  }
}

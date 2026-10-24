import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/app_state.dart';
import '../strings_fr.dart';
import '../ui/feedback.dart';
import '../ui/tokens.dart';

/// Ouvre les détails de la dernière tentative de connexion à [serverId] (phase 13) : la cause technique [cause] s'il
/// y en a une, puis le journal de la tentative (sans aucun secret), copiable.
Future<void> showConnectionDetails(BuildContext context, AppState state, String serverId, {String? cause}) async {
  final lines = await state.lastAttemptLog(serverId);
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => ConnectionDetailsSheet(cause: cause, lines: lines),
  );
}

/// Feuille des détails d'une connexion : cause, journal en police à chasse fixe, bouton Copier.
class ConnectionDetailsSheet extends StatelessWidget {
  const ConnectionDetailsSheet({super.key, this.cause, required this.lines});

  final String? cause;
  final List<String> lines;

  String get _text => [if (cause != null && cause!.isNotEmpty) cause!, ...lines].join('\n');

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: _text));
    if (context.mounted) showMessage(context, Fr.detailsCopied, kind: MessageKind.success);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mono = theme.textTheme.bodySmall!.copyWith(fontFamily: 'monospace');
    final c = cause;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Space.l, 0, Space.l, Space.l),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(Fr.connectionDetails, style: theme.textTheme.titleMedium),
            const SizedBox(height: Space.m),
            Flexible(
              child: SingleChildScrollView(
                child: SelectableText(
                  [if (c != null && c.isNotEmpty) c, if (lines.isEmpty) Fr.noAttemptLog, ...lines].join('\n'),
                  style: mono,
                ),
              ),
            ),
            const SizedBox(height: Space.m),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: FilledButton.tonalIcon(
                onPressed: () => _copy(context),
                icon: const Icon(Icons.copy_rounded),
                label: const Text(Fr.copy),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../bridge/fluluks_api.g.dart';
import '../state/app_state.dart';
import '../strings_fr.dart';
import '../ui/tokens.dart';
import '../ui/widgets.dart';

/// Choix d'un dossier de destination dans n'importe quel stockage, dossier distant compris ; les stockages en
/// lecture seule et les vues déchiffrées ne sont pas proposés ; [accept] écarte d'autres stockages (dossiers
/// distants et coffres pour un nouveau coffre). Rend (stockage, chemin), ou null si annulé.
Future<(String, String)?> pickFolder(BuildContext context, AppState state, {bool Function(SourceMsg)? accept}) =>
    showDialog<(String, String)>(context: context, builder: (_) => FolderPickerDialog(state: state, accept: accept));

class FolderPickerDialog extends StatefulWidget {
  const FolderPickerDialog({super.key, required this.state, this.accept});

  final AppState state;
  final bool Function(SourceMsg)? accept;

  @override
  State<FolderPickerDialog> createState() => _FolderPickerDialogState();
}

class _FolderPickerDialogState extends State<FolderPickerDialog> {
  SourceMsg? _source;
  String _path = '/';
  List<EntryMsg> _dirs = const [];
  bool _loading = false;
  String? _error;

  IconData _icon(SourceMsg s) => switch (s.kind) {
        'phone' => Icons.smartphone_rounded,
        'remote' => Icons.cloud_rounded,
        'removable' => Icons.sd_card_rounded,
        'vault' => Icons.enhanced_encryption_rounded,
        _ => Icons.usb_rounded,
      };

  Future<void> _open(SourceMsg s, String path) async {
    setState(() {
      _source = s;
      _path = path;
      _loading = true;
      _error = null;
    });
    try {
      final l = await widget.state.api.listDir(s.id, path, false);
      if (!mounted) return;
      setState(() {
        _dirs = l.where((e) => e.type == 'dir').toList()..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        _loading = false;
      });
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        _dirs = const [];
        _loading = false;
        _error = e.message ?? Fr.genericError;
      });
    }
  }

  void _up() {
    final s = _source!;
    if (_path == '/') {
      setState(() {
        _source = null;
        _dirs = const [];
        _error = null;
      });
      return;
    }
    final i = _path.lastIndexOf('/');
    _open(s, i <= 0 ? '/' : _path.substring(0, i));
  }

  @override
  Widget build(BuildContext context) {
    final s = _source;
    final accept = widget.accept;
    final storages = widget.state.sources
        .where((x) => x.kind != 'decrypted' && !x.readOnly && (accept == null || accept(x)))
        .toList();
    return AlertDialog(
      title: const Text(Fr.pickFolderTitle),
      contentPadding: const EdgeInsets.symmetric(vertical: Space.s),
      content: SizedBox(
        width: double.maxFinite,
        height: 360,
        child: ListView(children: [
          if (s == null) ...[
            const SectionHeader(Fr.pickStorages),
            for (final x in storages)
              ListTile(leading: Icon(_icon(x)), title: Text(x.label), onTap: () => _open(x, '/')),
          ] else ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.xl, vertical: Space.xs),
              child: Text(Fr.destChosen(s.label, _path), style: Theme.of(context).textTheme.bodySmall),
            ),
            ListTile(leading: const Icon(Icons.arrow_upward_rounded), title: const Text(Fr.pickUp), onTap: _up),
            if (_loading) const LinearProgressIndicator(),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(Space.l),
                child: StatusBanner(icon: Icons.error_rounded, text: _error!, tone: ChipTone.danger),
              ),
            for (final d in _dirs)
              ListTile(leading: const Icon(Icons.folder_rounded), title: Text(d.name), onTap: () => _open(s, d.path)),
          ],
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text(Fr.cancel)),
        FilledButton(
          onPressed: s == null || _loading ? null : () => Navigator.pop(context, (s.id, _path)),
          child: const Text(Fr.pickHere),
        ),
      ],
    );
  }
}

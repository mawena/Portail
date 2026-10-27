import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../bridge/fluluks_api.g.dart';
import '../state/app_state.dart';
import '../strings_fr.dart';
import '../ui/feedback.dart';
import '../ui/states.dart';

/// Emplacements exclus de l'analyse (Réglages → Analyseur de stockage, phase 16) : dossiers ignorés par les analyses
/// suivantes, stockage par stockage, ajoutés depuis le menu d'un élément d'une analyse ; « Ne plus exclure » en retire
/// un. Aucun : écran vide qui dit comment en ajouter.
class AnalysisExclusionsScreen extends StatefulWidget {
  const AnalysisExclusionsScreen({super.key, required this.state});

  final AppState state;

  @override
  State<AnalysisExclusionsScreen> createState() => _AnalysisExclusionsScreenState();
}

class _AnalysisExclusionsScreenState extends State<AnalysisExclusionsScreen> {
  List<AnalysisExclusionMsg>? _list;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final l = await widget.state.api.analysisExclusions();
    if (mounted) setState(() => _list = l);
  }

  Future<void> _remove(AnalysisExclusionMsg e) async {
    try {
      await widget.state.api.removeAnalysisExclusion(e.stableKey, e.path);
    } on PlatformException catch (err) {
      if (mounted) showMessage(context, err.message ?? Fr.genericError, kind: MessageKind.error);
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final l = _list;
    return Scaffold(
      appBar: AppBar(title: const Text(Fr.analysisExclusions)),
      body: l == null
          ? const Center(child: CircularProgressIndicator())
          : l.isEmpty
              ? const EmptyState(
                  icon: Icons.visibility_off_outlined,
                  title: Fr.noAnalysisExclusions,
                  message: Fr.noAnalysisExclusionsBody,
                )
              : ListView(children: [
                  for (final e in l)
                    ListTile(
                      leading: const Icon(Icons.visibility_off_rounded),
                      title: Text(e.path),
                      subtitle: Text(e.sourceLabel),
                      trailing: IconButton(
                        tooltip: Fr.removeExclusion,
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () => _remove(e),
                      ),
                    ),
                ]),
    );
  }
}

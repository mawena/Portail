import 'package:flutter/material.dart';

import '../bridge/fluluks_api.g.dart';
import '../screens/explorer_screen.dart';
import '../screens/module_shell.dart';
import '../state/app_state.dart';
import '../strings_fr.dart';
import '../ui/dialogs.dart';
import '../ui/tokens.dart';
import '../ui/widgets.dart';
import '../widgets/bottom_dock.dart';
import '../widgets/folder_picker.dart';
import '../widgets/source_tile.dart';
import 'analyzer_screen.dart';

/// Montre l'accueil de l'analyseur (module de la barre).
Future<void> openAnalyzerHome(BuildContext context, AppState state) async =>
    ModuleShell.maybeOf(context)?.select(PortailModule.analyzer);

/// Stockages proposés par l'accueil de l'analyseur : téléphone, cartes SD, volumes ouverts et coffres ouverts. Un
/// dossier distant s'analyse depuis l'explorateur ; un fichier déchiffré en mémoire ne s'analyse pas.
bool analyzableLocation(SourceMsg s) => const {'phone', 'removable', 'disk', 'vault'}.contains(s.kind);

/// Libellé d'un emplacement analysé : le stockage, ou « DCIM (Téléphone) » pour un dossier.
String analysisLabel(AppState state, String sourceId, String path, {String? fallback}) {
  final label = state.sources.where((s) => s.id == sourceId).map((s) => s.label).firstOrNull ?? fallback ?? sourceId;
  return path == '/' ? label : '${nameOf(path)} ($label)';
}

/// Lance l'analyse de [path] dans [sourceId] et ouvre son écran, dans le module Analyseur : un dossier distant demande
/// d'abord confirmation (lecture par le réseau, tailles du serveur) ; une analyse en cours, l'accord de l'arrêter.
Future<void> analyzeLocation(BuildContext context, AppState state, String sourceId, String path) async {
  final kind = state.sources.where((s) => s.id == sourceId).map((s) => s.kind).firstOrNull;
  if (kind == 'remote') {
    final ok = await confirmAction(context,
        title: Fr.analysisRemoteWarningTitle, body: Fr.analysisRemoteWarning, confirmLabel: Fr.analyze);
    if (!ok || !context.mounted) return;
  }
  final p = state.analysisProgress;
  if (p != null && p.running) {
    final ok = await confirmAction(context,
        title: Fr.stopAnalysisTitle(analysisLabel(state, p.sourceId, p.path)),
        body: Fr.stopAnalysisBody,
        confirmLabel: Fr.analyze);
    if (!ok || !context.mounted) return;
  }
  await openAnalysis(context, state, sourceId: sourceId, path: path);
}

/// Accueil de l'analyseur (phase 16), comme celui de Baobab : l'analyse en cours, les emplacements analysables avec
/// leur jauge d'occupation (toucher lance l'analyse), « Analyser un dossier… », puis les analyses gardées de la session
/// (toucher rouvre ; menu : Réanalyser, Oublier).
class AnalyzerHomeScreen extends StatefulWidget {
  const AnalyzerHomeScreen({super.key, required this.state});

  final AppState state;

  @override
  State<AnalyzerHomeScreen> createState() => _AnalyzerHomeScreenState();
}

class _AnalyzerHomeScreenState extends State<AnalyzerHomeScreen> {
  List<AnalysisSummaryMsg> _kept = const [];
  AnalysisProgressMsg? _seen;

  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    _seen = state.analysisProgress;
    state.addListener(_onState);
    _reload();
  }

  @override
  void dispose() {
    state.removeListener(_onState);
    super.dispose();
  }

  /// Une analyse qui commence ou finit change la liste des analyses gardées.
  void _onState() {
    final p = state.analysisProgress;
    if (p?.scanId == _seen?.scanId && p?.running == _seen?.running) return;
    _seen = p;
    _reload();
  }

  Future<void> _reload() async {
    final kept = await state.api.analyses();
    if (mounted) setState(() => _kept = kept);
  }

  Future<void> _pickFolder() async {
    final picked = await pickFolder(context, state, writableOnly: false);
    if (picked == null || !mounted) return;
    await analyzeLocation(context, state, picked.$1, picked.$2);
  }

  Future<void> _keptAction(AnalysisSummaryMsg a, String action) async {
    if (action == 'rescan') {
      await analyzeLocation(context, state, a.sourceId, a.path);
    } else {
      await state.api.forgetAnalysis(a.scanId);
    }
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text(Fr.moduleAnalyzer), actions: moduleActions(context, state)),
      bottomNavigationBar: BottomDock(state: state),
      body: ListenableBuilder(
        listenable: state,
        builder: (context, _) {
          final p = state.analysisProgress;
          final run = p != null && p.running ? p : null;
          final kept = _kept.where((a) => a.scanId != run?.scanId).toList();
          return ListView(padding: const EdgeInsets.all(Space.l), children: [
            if (run != null) _RunningCard(state: state, progress: run),
            const SectionHeader(Fr.analyzerLocations),
            for (final s in state.sources.where(analyzableLocation))
              Padding(
                padding: const EdgeInsets.only(bottom: Space.s),
                child: SourceTile(
                  source: s,
                  // le téléphone et les cartes SD demandent l'accès à tous les fichiers
                  onTap: state.allFilesAccess || (s.kind != 'phone' && s.kind != 'removable')
                      ? () => analyzeLocation(context, state, s.id, '/')
                      : null,
                ),
              ),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                icon: const Icon(Icons.folder_open_rounded),
                label: const Text(Fr.analyzeFolder),
                onPressed: _pickFolder,
              ),
            ),
            if (kept.isNotEmpty) ...[
              const SectionHeader(Fr.analyzerKept),
              for (final a in kept)
                Padding(
                  padding: const EdgeInsets.only(bottom: Space.s),
                  child: _KeptCard(state: state, analysis: a, onAction: (v) => _keptAction(a, v)),
                ),
            ],
          ]);
        },
      ),
    );
  }
}

/// Analyse en cours : emplacement, avancement (barre déterminée pour un stockage entier), Annuler ; toucher l'ouvre.
class _RunningCard extends StatelessWidget {
  const _RunningCard({required this.state, required this.progress});

  final AppState state;
  final AnalysisProgressMsg progress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = progress;
    return Card(
      key: const ValueKey('analyse-en-cours'),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => openAnalysis(context, state, scanId: p.scanId),
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(Space.l, Space.m, Space.xs, Space.m),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, spacing: Space.s, children: [
            Row(children: [
              const TonalIcon(Icons.pie_chart_rounded),
              const SizedBox(width: Space.l),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(Fr.analysisRunning, style: theme.textTheme.titleMedium),
                  Text(analysisLabel(state, p.sourceId, p.path), style: theme.textTheme.bodyMedium),
                ]),
              ),
              TextButton(onPressed: state.api.cancelAnalysis, child: const Text(Fr.cancel)),
            ]),
            Padding(
              padding: const EdgeInsetsDirectional.only(end: Space.l),
              child: LinearProgressIndicator(value: p.usedBytes == null ? null : p.fraction),
            ),
            Text(Fr.analysisProgress(p.files, p.bytes), style: numeric(theme.textTheme.bodyMedium!)),
          ]),
        ),
      ),
    );
  }
}

/// Analyse gardée : emplacement, place, fichiers, état et date ; toucher la rouvre ; menu : Réanalyser, Oublier.
class _KeptCard extends StatelessWidget {
  const _KeptCard({required this.state, required this.analysis, required this.onAction});

  final AppState state;
  final AnalysisSummaryMsg analysis;
  final ValueChanged<String> onAction;

  @override
  Widget build(BuildContext context) {
    final a = analysis;
    final label = analysisLabel(state, a.sourceId, a.path, fallback: a.label);
    final kind = state.sources.where((s) => s.id == a.sourceId).map((s) => s.kind).firstOrNull ?? '';
    final done = a.finishedAtMs;
    return Card(
      key: ValueKey('analyse-${a.scanId}'),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        contentPadding: const EdgeInsetsDirectional.only(start: Space.l, end: Space.xs),
        leading: TonalIcon(sourceIcon(kind)),
        title: Text(label),
        subtitle: Text(Fr.analysisSummary(a.bytes, a.files, a.state, done == null ? null : done ~/ 1000),
            style: numeric(Theme.of(context).textTheme.bodyMedium!)),
        onTap: () => openAnalysis(context, state, scanId: a.scanId),
        trailing: PopupMenuButton<String>(
          tooltip: Fr.analysisMenu(label),
          icon: const Icon(Icons.more_vert_rounded),
          onSelected: onAction,
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'rescan', child: ListTile(leading: Icon(Icons.refresh_rounded), title: Text(Fr.reanalyze))),
            PopupMenuItem(
              value: 'forget',
              child: ListTile(leading: Icon(Icons.playlist_remove_rounded), title: Text(Fr.forgetAnalysis)),
            ),
          ],
        ),
      ),
    );
  }
}

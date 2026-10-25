import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../bridge/fluluks_api.g.dart';
import '../state/app_state.dart';
import '../strings_fr.dart';
import '../ui/dialogs.dart';
import '../ui/feedback.dart';
import '../ui/tokens.dart';
import '../ui/widgets.dart';
import '../widgets/connection_details_sheet.dart';

/// Vrai pour une adresse `http://` vers un hôte qui n'est pas local (hors 10/8, 172.16/12, 192.168/16, 127/8,
/// `localhost`, `*.local`, `::1`) : la clé et les conversations passeraient en clair sur Internet.
bool isClearTextPublic(String url) {
  final u = Uri.tryParse(url.trim());
  if (u == null || u.scheme.toLowerCase() != 'http' || u.host.isEmpty) return false;
  final h = u.host.toLowerCase();
  if (h == 'localhost' || h.endsWith('.local') || h == '::1' || h == '[::1]') return false;
  final p = h.split('.').map(int.tryParse).toList();
  if (p.length == 4 && p.every((n) => n != null && n >= 0 && n <= 255)) {
    final a = p[0]!, b = p[1]!;
    if (a == 10 || a == 127 || (a == 192 && b == 168) || (a == 172 && b >= 16 && b <= 31)) return false;
  }
  return true;
}

/// Fiche d'un serveur IA (phase 15) : nom, adresse, clé API (jamais montrée : « laissez vide pour la garder »,
/// « Retirer la clé »), serveur par défaut ; pour un serveur enregistré, « Tester la connexion » (résultat et
/// « Détails ») et ses modèles, dont le modèle par défaut. Avertit d'une adresse `http://` hors du réseau local.
class AiServerForm extends StatefulWidget {
  const AiServerForm({super.key, required this.state, this.server});

  final AppState state;

  /// Null : nouveau serveur.
  final AiServerMsg? server;

  @override
  State<AiServerForm> createState() => _AiServerFormState();
}

class _AiServerFormState extends State<AiServerForm> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.server?.name ?? '');
  late final _url = TextEditingController(text: widget.server?.baseUrl ?? '');
  final _key = TextEditingController();
  late bool _hasKey = widget.server?.hasKey ?? false;
  late bool _isDefault = widget.server?.isDefault ?? false;
  late String? _defaultModel = widget.server?.defaultModel;
  List<String>? _models;
  String? _modelsError;
  bool _loadingModels = false;
  bool _testing = false;

  AppState get _state => widget.state;

  @override
  void initState() {
    super.initState();
    _state.ai.watch();
    _url.addListener(() => setState(() {}));
    if (widget.server != null) _loadModels();
  }

  @override
  void dispose() {
    _state.ai.unwatch();
    for (final c in [_name, _url, _key]) {
      c.dispose();
    }
    super.dispose();
  }

  void _error(String m) => showMessage(context, m, kind: MessageKind.error);

  String? _urlError(String v) {
    final t = v.trim();
    if (t.isEmpty) return Fr.aiUrlRequired;
    final l = t.toLowerCase();
    if (!l.startsWith('http://') && !l.startsWith('https://')) return Fr.aiUrlScheme;
    return null;
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final s = widget.server;
    final msg = AiServerMsg(
      id: s?.id ?? '',
      name: _name.text.trim(),
      baseUrl: _url.text.trim(),
      hasKey: false,
      isDefault: false,
    );
    final key = _key.text.isEmpty ? null : Uint8List.fromList(utf8.encode(_key.text));
    try {
      await _state.ai.save(msg, key);
      if (mounted) Navigator.of(context).pop();
    } on PlatformException catch (e) {
      if (mounted) _error(e.message ?? Fr.genericError);
    }
  }

  Future<void> _removeKey() async {
    try {
      await _state.ai.removeKey(widget.server!.id);
      if (!mounted) return;
      setState(() => _hasKey = false);
      showMessage(context, Fr.aiKeyRemoved, kind: MessageKind.success);
    } on PlatformException catch (e) {
      if (mounted) _error(e.message ?? Fr.genericError);
    }
  }

  Future<void> _setDefault(bool on) async {
    if (!on || _isDefault) return;
    try {
      await _state.ai.setDefault(widget.server!.id);
      if (mounted) setState(() => _isDefault = true);
    } on PlatformException catch (e) {
      if (mounted) _error(e.message ?? Fr.genericError);
    }
  }

  Future<void> _delete() async {
    final s = widget.server!;
    final ok = await confirmAction(
      context,
      title: Fr.aiDeleteServer,
      body: Fr.aiDeleteServerBody(s.name),
      confirmLabel: Fr.delete,
      destructive: true,
    );
    if (!ok || !mounted) return;
    try {
      await _state.ai.delete(s.id);
      if (mounted) Navigator.of(context).pop();
    } on PlatformException catch (e) {
      if (mounted) _error(e.message ?? Fr.genericError);
    }
  }

  Future<void> _loadModels() async {
    setState(() {
      _loadingModels = true;
      _modelsError = null;
    });
    try {
      final m = await _state.ai.models(widget.server!.id);
      if (mounted) setState(() => _models = m);
    } on PlatformException catch (e) {
      if (mounted) setState(() => _modelsError = e.message ?? Fr.genericError);
    } finally {
      if (mounted) setState(() => _loadingModels = false);
    }
  }

  Future<void> _chooseModel(String m) async {
    try {
      await _state.ai.setDefaultModel(widget.server!.id, m);
      if (mounted) setState(() => _defaultModel = m);
    } on PlatformException catch (e) {
      if (mounted) _error(e.message ?? Fr.genericError);
    }
  }

  /// « Tester la connexion » : la fiche enregistrée (santé, puis modèles).
  Future<void> _test() async {
    final id = widget.server!.id;
    setState(() => _testing = true);
    try {
      final r = await _state.ai.test(id);
      if (!mounted) return;
      void details() => showModalBottomSheet<void>(
            context: context,
            isScrollControlled: true,
            showDragHandle: true,
            builder: (_) => ConnectionDetailsSheet(cause: r.detail, lines: r.log),
          );
      if (r.ok) {
        setState(() => _models = r.models);
        showMessage(context, Fr.aiConnectionOk(r.version, r.models.length),
            kind: MessageKind.success, actionLabel: Fr.details, onAction: details);
      } else {
        showMessage(context, r.error ?? Fr.genericError,
            kind: MessageKind.error, actionLabel: Fr.details, onAction: details);
      }
    } on PlatformException catch (e) {
      if (mounted) _error(e.message ?? Fr.genericError);
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Widget _field(
    TextEditingController c,
    String label, {
    String? helper,
    bool obscure = false,
    TextInputType? type,
    String? Function(String)? validator,
  }) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: Space.s),
        child: TextFormField(
          controller: c,
          obscureText: obscure,
          keyboardType: type,
          autocorrect: false,
          enableSuggestions: !obscure,
          validator: validator == null ? null : (v) => validator(v ?? ''),
          decoration: InputDecoration(labelText: label, helperText: helper, helperMaxLines: 3, errorMaxLines: 3),
        ),
      );

  List<Widget> _modelsSection(ThemeData theme) {
    final models = _models;
    final muted = theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return [
      SectionHeader(
        Fr.aiModels,
        trailing: IconButton(
          tooltip: Fr.aiRefreshModels,
          icon: const Icon(Icons.refresh_rounded),
          onPressed: _loadingModels ? null : _loadModels,
        ),
      ),
      if (_loadingModels && models == null) const LinearProgressIndicator(),
      if (_modelsError != null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: Space.s),
          child: StatusBanner(icon: Icons.error_rounded, text: _modelsError!, tone: ChipTone.danger),
        ),
      if (models != null && models.isEmpty)
        Padding(padding: const EdgeInsets.symmetric(vertical: Space.s), child: Text(Fr.aiNoModels, style: muted)),
      if (models != null && models.isNotEmpty) ...[
        Text(Fr.aiModelsHelp, style: muted),
        for (final m in models)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(m == _defaultModel ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded),
            title: Text(m),
            selected: m == _defaultModel,
            onTap: () => _chooseModel(m),
          ),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = widget.server;
    return Scaffold(
      appBar: AppBar(
        title: Text(s?.name ?? Fr.aiAddServer),
        actions: [
          if (s != null)
            IconButton(tooltip: Fr.aiDeleteServer, icon: const Icon(Icons.delete_rounded), onPressed: _delete),
        ],
      ),
      body: AdaptiveBody(
        maxWidth: Layout.maxForm,
        child: Form(
          key: _form,
          child: ListView(padding: listPadding(context, const EdgeInsets.all(Space.l)), children: [
            _field(_name, Fr.aiServerName),
            _field(_url, Fr.aiServerUrl, helper: Fr.aiServerUrlHelp, type: TextInputType.url, validator: _urlError),
            if (isClearTextPublic(_url.text))
              const Padding(
                padding: EdgeInsets.symmetric(vertical: Space.s),
                child: StatusBanner(
                  icon: Icons.lock_open_rounded,
                  title: Fr.aiClearTextWarning,
                  text: Fr.aiClearTextHelp,
                ),
              ),
            _field(_key, Fr.aiApiKey, obscure: true, helper: _hasKey ? Fr.aiApiKeyKeep : Fr.aiApiKeyHelp),
            if (_hasKey)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton(onPressed: _removeKey, child: const Text(Fr.aiRemoveKey)),
              ),
            if (s != null)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text(Fr.aiDefaultServer),
                subtitle: const Text(Fr.aiDefaultServerHelp),
                value: _isDefault,
                onChanged: _isDefault ? null : _setDefault,
              ),
            const SizedBox(height: Space.l),
            if (s != null) ...[
              OutlinedButton.icon(
                onPressed: _testing ? null : _test,
                icon: _testing
                    ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.network_check_rounded),
                label: const Text(Fr.testConnection),
              ),
              const SizedBox(height: Space.s),
            ],
            FilledButton(onPressed: _save, child: const Text(Fr.save)),
            if (s != null) ..._modelsSection(theme),
          ]),
        ),
      ),
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../bridge/fluluks_api.g.dart';
import '../state/app_state.dart';
import '../strings_fr.dart';
import '../ui/feedback.dart';
import '../ui/tokens.dart';
import '../ui/widgets.dart';
import 'model_picker.dart';

/// Créer ou modifier une automatisation (phase 15) : nom, modèle de prompt et ses variables (détectées pendant la
/// saisie, avec leur valeur par défaut), serveur et modèle, prompt système, déclenchement à la demande ou planifié.
class AutomationForm extends StatefulWidget {
  const AutomationForm({super.key, required this.state, this.automation});

  final AppState state;

  /// null : nouvelle automatisation.
  final AutomationMsg? automation;

  @override
  State<AutomationForm> createState() => _AutomationFormState();
}

class _AutomationFormState extends State<AutomationForm> {
  final _form = GlobalKey<FormState>();
  late final AutomationMsg? a = widget.automation;
  late final _name = TextEditingController(text: a?.name ?? '');
  late final _template = TextEditingController(text: a?.template ?? '');
  late final _system = TextEditingController(text: a?.systemPrompt ?? '');
  late String? _serverId = a?.serverId ?? widget.state.ai.defaultServer?.id;
  late String? _model = a?.model ?? widget.state.ai.defaultServer?.defaultModel;
  late bool _periodic = a?.trigger == 'periodic';
  late int _interval = a?.intervalMinutes ?? Fr.automationIntervals.first;
  late bool _enabled = a?.enabled ?? true;

  /// Variables détectées dans le modèle, et le champ de leur valeur par défaut (gardé même si la variable disparaît
  /// un instant pendant la saisie).
  List<String> _vars = const [];
  final _defaults = <String, TextEditingController>{};
  Timer? _debounce;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    for (final v in a?.variables ?? const <AutomationVarMsg>[]) {
      _defaults[v.name] = TextEditingController(text: v.defaultValue ?? '');
    }
    _vars = [for (final v in a?.variables ?? const <AutomationVarMsg>[]) v.name];
    _template.addListener(_templateChanged);
    if (!widget.state.ai.loaded) unawaited(widget.state.ai.load().then((_) => _fillDefaultServer()));
  }

  void _fillDefaultServer() {
    if (!mounted || _serverId != null) return;
    setState(() {
      _serverId = widget.state.ai.defaultServer?.id;
      _model = widget.state.ai.defaultServer?.defaultModel;
    });
  }

  void _templateChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), _detect);
  }

  Future<void> _detect() async {
    try {
      final vars = await widget.state.automations.variables(_template.text);
      if (!mounted) return;
      setState(() {
        _vars = vars;
        for (final v in vars) {
          _defaults.putIfAbsent(v, TextEditingController.new);
        }
      });
    } on PlatformException {
      // détection impossible : les variables seront vérifiées à l'enregistrement
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _name.dispose();
    _template.dispose();
    _system.dispose();
    for (final c in _defaults.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _chooseModel() async {
    final picked = await showModelPicker(context, widget.state, serverId: _serverId, model: _model);
    if (picked == null || !mounted) return;
    setState(() {
      _serverId = picked.$1;
      _model = picked.$2;
    });
  }

  Future<void> _save() async {
    if (!(_form.currentState?.validate() ?? false) || _saving) return;
    _debounce?.cancel();
    await _detect();
    if (!mounted) return;
    setState(() => _saving = true);
    try {
      final system = _system.text.trim();
      await widget.state.automations.save(AutomationMsg(
        id: a?.id ?? 0,
        name: _name.text.trim(),
        template: _template.text,
        variables: [
          for (final v in _vars)
            AutomationVarMsg(name: v, defaultValue: _defaults[v]!.text.isEmpty ? null : _defaults[v]!.text),
        ],
        serverId: _serverId,
        model: _model,
        systemPrompt: system.isEmpty ? null : system,
        trigger: _periodic ? 'periodic' : 'manual',
        intervalMinutes: _periodic ? _interval : null,
        enabled: _enabled,
      ));
      if (mounted) Navigator.of(context).pop();
    } on PlatformException catch (e) {
      if (mounted) showMessage(context, e.message ?? Fr.automations, kind: MessageKind.error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ai = widget.state.ai;
    final sid = _serverId;
    final modelLabel = sid == null
        ? Fr.chatNoModel
        : '${ai.server(sid)?.name ?? Fr.chatServerGone} · ${_model ?? Fr.chatNoModel}';
    final intervals = {...Fr.automationIntervals, _interval}.toList()..sort();
    return Scaffold(
      appBar: AppBar(title: Text(a == null ? Fr.automationNew : Fr.automationEdit)),
      body: Form(
        key: _form,
        child: AdaptiveBody(
          maxWidth: Layout.maxForm,
          child: ListView(padding: listPadding(context, const EdgeInsets.all(Space.l)), children: [
            TextFormField(
              controller: _name,
              decoration: const InputDecoration(labelText: Fr.automationName),
              textCapitalization: TextCapitalization.sentences,
              validator: (v) => (v ?? '').trim().isEmpty ? Fr.automationNameRequired : null,
            ),
            const SizedBox(height: Space.l),
            TextFormField(
              controller: _template,
              minLines: 3,
              maxLines: 10,
              keyboardType: TextInputType.multiline,
              decoration: const InputDecoration(
                labelText: Fr.automationTemplate,
                helperText: Fr.automationTemplateHelp,
                helperMaxLines: 3,
                alignLabelWithHint: true,
              ),
              validator: (v) => (v ?? '').trim().isEmpty ? Fr.automationTemplateRequired : null,
            ),
            if (_vars.isNotEmpty) ...[
              const SectionHeader(Fr.automationVariables),
              for (final v in _vars)
                Padding(
                  padding: const EdgeInsets.only(bottom: Space.m),
                  child: TextFormField(
                    key: ValueKey('var-$v'),
                    controller: _defaults[v],
                    decoration: InputDecoration(
                      labelText: Fr.automationDefaultFor(v),
                      helperText: _periodic ? Fr.automationDefaultRequired : null,
                    ),
                    validator: (t) => _periodic && (t ?? '').isEmpty ? Fr.automationDefaultRequired : null,
                  ),
                ),
            ],
            const SectionHeader(Fr.automationModel),
            Card(
              clipBehavior: Clip.antiAlias,
              child: ListTile(
                leading: const Icon(Icons.dns_rounded),
                title: Text(modelLabel),
                trailing: const Icon(Icons.arrow_drop_down_rounded),
                onTap: _chooseModel,
              ),
            ),
            const SizedBox(height: Space.l),
            TextFormField(
              controller: _system,
              minLines: 1,
              maxLines: 6,
              keyboardType: TextInputType.multiline,
              decoration: const InputDecoration(
                labelText: Fr.chatSystemPrompt,
                helperText: Fr.chatSystemPromptHelp,
                helperMaxLines: 3,
              ),
            ),
            const SectionHeader(Fr.automationTrigger),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, icon: Icon(Icons.bolt_rounded), label: Text(Fr.automationManual)),
                ButtonSegment(value: true, icon: Icon(Icons.schedule_rounded), label: Text(Fr.automationPeriodic)),
              ],
              selected: {_periodic},
              onSelectionChanged: (s) => setState(() => _periodic = s.first),
            ),
            if (_periodic) ...[
              const SizedBox(height: Space.l),
              DropdownButtonFormField<int>(
                initialValue: _interval,
                isExpanded: true,
                decoration: const InputDecoration(labelText: Fr.automationTrigger),
                items: [
                  for (final m in intervals) DropdownMenuItem(value: m, child: Text(Fr.automationInterval(m))),
                ],
                onChanged: (m) => setState(() => _interval = m ?? _interval),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text(Fr.automationEnabled),
                value: _enabled,
                onChanged: (v) => setState(() => _enabled = v),
              ),
              Text(
                Fr.automationPeriodicHelp,
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
            const SizedBox(height: Space.xl),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: FilledButton(onPressed: _saving ? null : _save, child: const Text(Fr.save)),
            ),
          ]),
        ),
      ),
    );
  }
}

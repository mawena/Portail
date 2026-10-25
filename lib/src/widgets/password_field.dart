import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../crypto/password_generator.dart';
import '../crypto/password_strength.dart';
import '../strings_fr.dart';
import '../ui/feedback.dart';
import '../ui/tokens.dart';

/// Champ de mot de passe. Pour déverrouiller (sans [confirm]) : un champ masqué, sans règle. Pour créer (avec
/// [confirm]) : un second champ de confirmation, les règles de Portail (8 caractères au moins, sans caractère NUL,
/// deux saisies identiques) si [enforceRules], et l'avertissement « Sans ce mot de passe, rien ne pourra être
/// récupéré ». [showStrength] affiche la force estimée, annoncée par TalkBack ; [allowGenerate] propose un mot de
/// passe de 20 caractères ou une phrase de 6 mots, et sa copie protégée par [copySecret] (octets mis à zéro ensuite).
/// Le clavier n'apprend ni ne suggère rien. Les deux champs sont vidés quand le champ disparaît.
class PasswordField extends StatefulWidget {
  const PasswordField({
    super.key,
    required this.controller,
    this.confirm,
    this.showStrength = false,
    this.allowGenerate = false,
    this.onGenerated,
    this.onValidChanged,
    this.copySecret,
    this.label = Fr.password,
    this.confirmLabel = Fr.passwordConfirm,
    this.showLabel = Fr.showPassword,
    this.hideLabel = Fr.hidePassword,
    this.enforceRules = true,
    this.errorText,
    this.enabled = true,
    this.autofocus = false,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final TextEditingController? confirm;
  final bool showStrength;
  final bool allowGenerate;
  final ValueChanged<String>? onGenerated;

  /// Appelé quand la saisie devient valide ou cesse de l'être (création seulement).
  final ValueChanged<bool>? onValidChanged;
  final Future<void> Function(Uint8List bytes)? copySecret;
  final String label;
  final String confirmLabel;

  /// Infobulles du bouton qui affiche ou masque la saisie.
  final String showLabel;
  final String hideLabel;
  final bool enforceRules;

  /// Erreur venue de l'écran (sous la confirmation s'il y en a une).
  final String? errorText;
  final bool enabled;
  final bool autofocus;
  final ValueChanged<String>? onSubmitted;

  /// Refus d'un mot de passe à créer, ou null : 8 caractères au moins (et non 8 octets), aucun caractère NUL,
  /// confirmation identique. Mêmes règles que `Passwords` côté Kotlin.
  static String? problem(String pw, String? confirm) {
    if (pw.contains('\u0000')) return Fr.passwordNul;
    if (pw.runes.length < 8) return Fr.passwordTooShort;
    if (confirm != null && confirm != pw) return Fr.passwordMismatch;
    return null;
  }

  @override
  State<PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<PasswordField> with AutomaticKeepAliveClientMixin {
  /// Gardé en vie dans une liste défilante : un défilement ne démonte pas le champ (ni n'efface ce qui est tapé).
  @override
  bool get wantKeepAlive => true;

  bool _obscure = true;
  bool? _lastValid;
  Set<String>? _words;

  bool get _creating => widget.confirm != null;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    widget.confirm?.addListener(_changed);
    if (widget.showStrength) {
      loadEffWords().then((w) {
        if (mounted) setState(() => _words = w.toSet());
      });
    }
  }

  @override
  void dispose() {
    final c = widget.controller, k = widget.confirm;
    c.removeListener(_changed);
    k?.removeListener(_changed);
    // vidés après cette image : pendant le démontage, l'arbre ne peut pas se reconstruire ; un champ déjà libéré
    // par son écran n'a plus rien à vider
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final x in [c, ?k]) {
        try {
          x.clear();
        } on FlutterError {
          // contrôleur libéré par son écran
        }
      }
    });
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    if (_creating && widget.enforceRules) {
      final ok = PasswordField.problem(widget.controller.text, widget.confirm!.text) == null;
      if (ok != _lastValid) {
        _lastValid = ok;
        widget.onValidChanged?.call(ok);
      }
    }
  }

  Future<void> _generate(bool words) async {
    final p = words ? generatePassphrase(await loadEffWords()) : generatePassword();
    if (!mounted) return;
    setState(() => _obscure = false); // affiché, pour pouvoir le noter
    widget.controller.text = p;
    widget.confirm?.text = p;
    widget.onGenerated?.call(p);
  }

  Future<void> _copy() async {
    final copy = widget.copySecret;
    if (copy == null || widget.controller.text.isEmpty) return;
    final bytes = Uint8List.fromList(utf8.encode(widget.controller.text));
    try {
      await copy(bytes);
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
    if (mounted) showMessage(context, Fr.passwordCopied);
  }

  String _levelName(Strength s) => switch (s) {
        Strength.veryWeak => Fr.strengthVeryWeak,
        Strength.weak => Fr.strengthWeak,
        Strength.fair => Fr.strengthFair,
        Strength.good => Fr.strengthGood,
        Strength.excellent => Fr.strengthExcellent,
      };

  Color _levelColor(ColorScheme s, Strength level) => switch (level) {
        Strength.veryWeak || Strength.weak => s.error,
        Strength.fair => s.tertiary,
        Strength.good || Strength.excellent => s.primary,
      };

  Widget _field(TextEditingController c, String label, {String? error, Widget? suffix, bool autofocus = false}) => TextField(
        controller: c,
        obscureText: _obscure,
        // affiché, il n'est plus un champ de mot de passe pour le clavier : ni suggestions, ni apprentissage
        keyboardType: _obscure ? null : TextInputType.visiblePassword,
        autocorrect: false,
        enableSuggestions: false,
        enableIMEPersonalizedLearning: false,
        enabled: widget.enabled,
        autofocus: autofocus,
        decoration: InputDecoration(labelText: label, errorText: error, errorMaxLines: 3, suffixIcon: suffix),
        onSubmitted: widget.onSubmitted,
      );

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final text = widget.controller.text;
    final rules = _creating && widget.enforceRules;
    final problem = rules ? PasswordField.problem(text, null) : null;
    final mismatch =
        rules && widget.confirm!.text.isNotEmpty && widget.confirm!.text != text ? Fr.passwordMismatch : null;
    final buttons = <Widget>[
      if (widget.allowGenerate && widget.copySecret != null && text.isNotEmpty)
        IconButton(
          tooltip: Fr.copyPassword,
          icon: const Icon(Icons.copy_rounded),
          onPressed: widget.enabled ? _copy : null,
        ),
      if (widget.allowGenerate)
        PopupMenuButton<bool>(
          tooltip: Fr.generatePassword,
          enabled: widget.enabled,
          icon: const Icon(Icons.casino_rounded),
          onSelected: _generate,
          itemBuilder: (_) => const [
            PopupMenuItem(value: false, child: Text(Fr.generateChars)),
            PopupMenuItem(value: true, child: Text(Fr.generateWords)),
          ],
        ),
      IconButton(
        tooltip: _obscure ? widget.showLabel : widget.hideLabel,
        icon: Icon(_obscure ? Icons.visibility_rounded : Icons.visibility_off_rounded),
        onPressed: () => setState(() => _obscure = !_obscure),
      ),
    ];
    final strength = widget.showStrength && text.isNotEmpty ? estimate(text, words: _words) : null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _field(
          widget.controller,
          widget.label,
          error: text.isNotEmpty ? problem : (_creating ? null : widget.errorText),
          suffix: Row(mainAxisSize: MainAxisSize.min, children: buttons),
          autofocus: widget.autofocus,
        ),
        if (strength != null) ...[
          const SizedBox(height: Space.xs),
          Semantics(
            liveRegion: true,
            label: Fr.strength(_levelName(strength)),
            child: ExcludeSemantics(
              child: Row(children: [
                Expanded(
                  child: LinearProgressIndicator(
                    value: (strength.index + 1) / Strength.values.length,
                    color: _levelColor(theme.colorScheme, strength),
                  ),
                ),
                const SizedBox(width: Space.s),
                Text(Fr.strength(_levelName(strength)), style: theme.textTheme.bodySmall),
              ]),
            ),
          ),
        ],
        if (_creating) ...[
          const SizedBox(height: Space.s),
          _field(widget.confirm!, widget.confirmLabel, error: mismatch ?? widget.errorText),
          const SizedBox(height: Space.s),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.info_outline_rounded, size: 18, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: Space.s),
            Expanded(child: Text(Fr.passwordNoRecovery, style: theme.textTheme.bodySmall)),
          ]),
        ],
      ],
    );
  }
}

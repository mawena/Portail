import 'package:flutter/material.dart';

import '../strings_fr.dart';
import '../ui/tokens.dart';

/// État d'un modificateur de la barre de touches : un toucher l'active pour la prochaine touche, un second le
/// verrouille, un troisième le relâche.
enum ModifierState { off, once, locked }

/// Ctrl et Alt de la barre de touches (phase 13), appliqués à la touche suivante de la barre ou du clavier du
/// téléphone.
class KeyModifiers extends ChangeNotifier {
  ModifierState ctrl = ModifierState.off;
  ModifierState alt = ModifierState.off;

  static ModifierState _next(ModifierState s) => switch (s) {
        ModifierState.off => ModifierState.once,
        ModifierState.once => ModifierState.locked,
        ModifierState.locked => ModifierState.off,
      };

  void tapCtrl() {
    ctrl = _next(ctrl);
    notifyListeners();
  }

  void tapAlt() {
    alt = _next(alt);
    notifyListeners();
  }

  /// Modificateurs pour la touche en cours ; ceux posés « une fois » sont relâchés.
  (bool ctrl, bool alt) take() {
    final r = (ctrl != ModifierState.off, alt != ModifierState.off);
    var changed = false;
    if (ctrl == ModifierState.once) {
      ctrl = ModifierState.off;
      changed = true;
    }
    if (alt == ModifierState.once) {
      alt = ModifierState.off;
      changed = true;
    }
    if (changed) notifyListeners();
    return r;
  }

  /// Texte tapé avec les modificateurs actifs : Ctrl change un caractère en code de contrôle (`c` → 0x03), Alt le
  /// précède d'Échap. Un caractère sans code de contrôle reste tel quel.
  String apply(String data) {
    if (ctrl == ModifierState.off && alt == ModifierState.off) return data;
    final (c, a) = take();
    var s = data;
    if (c && s.length == 1) s = _control(s) ?? s;
    return a ? '\x1b$s' : s;
  }

  static String? _control(String ch) {
    final code = ch.codeUnitAt(0);
    if (code >= 0x61 && code <= 0x7a) return String.fromCharCode(code - 0x60); // a à z
    if (code >= 0x40 && code <= 0x5f) return String.fromCharCode(code - 0x40); // @ A à Z [ \ ] ^ _
    if (ch == ' ') return '\x00';
    if (ch == '?') return '\x7f';
    return null;
  }
}

/// Paramètre xterm des modificateurs d'une touche spéciale (1 + 2 pour Alt + 4 pour Ctrl), null sans modificateur.
int? _modParam(bool ctrl, bool alt) => (ctrl || alt) ? 1 + (alt ? 2 : 0) + (ctrl ? 4 : 0) : null;

/// Barre de touches au-dessus du clavier (phase 13) : Échap, Tab, Ctrl, Alt, flèches, Début, Fin, pages et symboles
/// difficiles à atteindre sur un clavier de téléphone. Défile horizontalement ; cibles de 48 dp.
/// [appCursorKeys] : vrai si le terminal est en mode curseur d'application (flèches en `ESC O A`).
class KeyBar extends StatelessWidget {
  const KeyBar({super.key, required this.onInput, required this.modifiers, this.appCursorKeys});

  final void Function(String data) onInput;
  final KeyModifiers modifiers;
  final bool Function()? appCursorKeys;

  void _plain(String s) => onInput(modifiers.apply(s));

  /// Flèches, Début, Fin : `ESC [ x`, `ESC O x` en mode application, `ESC [ 1 ; m x` avec modificateurs.
  void _cursor(String x) {
    final (c, a) = modifiers.take();
    final m = _modParam(c, a);
    if (m != null) return onInput('\x1b[1;$m$x');
    onInput((appCursorKeys?.call() ?? false) ? '\x1bO$x' : '\x1b[$x');
  }

  void _tilde(int n) {
    final (c, a) = modifiers.take();
    final m = _modParam(c, a);
    onInput(m == null ? '\x1b[$n~' : '\x1b[$n;$m~');
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surfaceContainerHigh,
      child: SizedBox(
        height: 48,
        child: ListenableBuilder(
          listenable: modifiers,
          builder: (context, _) => ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: Space.xs),
            children: [
              _Key(text: 'Échap', label: Fr.keyEsc, onTap: () => _plain('\x1b')),
              _Key(text: 'Tab', label: Fr.keyTab, onTap: () => _plain('\t')),
              _Key(text: 'Ctrl', label: Fr.keyCtrl, state: modifiers.ctrl, onTap: modifiers.tapCtrl),
              _Key(text: 'Alt', label: Fr.keyAlt, state: modifiers.alt, onTap: modifiers.tapAlt),
              _Key(text: '←', label: Fr.keyLeft, onTap: () => _cursor('D')),
              _Key(text: '↑', label: Fr.keyUp, onTap: () => _cursor('A')),
              _Key(text: '↓', label: Fr.keyDown, onTap: () => _cursor('B')),
              _Key(text: '→', label: Fr.keyRight, onTap: () => _cursor('C')),
              _Key(text: 'Début', label: Fr.keyHome, onTap: () => _cursor('H')),
              _Key(text: 'Fin', label: Fr.keyEnd, onTap: () => _cursor('F')),
              _Key(text: 'Pg↑', label: Fr.keyPageUp, onTap: () => _tilde(5)),
              _Key(text: 'Pg↓', label: Fr.keyPageDown, onTap: () => _tilde(6)),
              _Key(text: '~', label: Fr.keyTilde, onTap: () => _plain('~')),
              _Key(text: '|', label: Fr.keyPipe, onTap: () => _plain('|')),
              _Key(text: '/', label: Fr.keySlash, onTap: () => _plain('/')),
              _Key(text: '-', label: Fr.keyDash, onTap: () => _plain('-')),
            ],
          ),
        ),
      ),
    );
  }
}

class _Key extends StatelessWidget {
  const _Key({required this.text, required this.label, required this.onTap, this.state});

  final String text;
  final String label;
  final VoidCallback onTap;

  /// Modificateur (Ctrl, Alt) : son état ; null pour une touche ordinaire.
  final ModifierState? state;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (bg, fg) = switch (state) {
      ModifierState.once => (cs.secondaryContainer, cs.onSecondaryContainer),
      ModifierState.locked => (cs.primary, cs.onPrimary),
      _ => (cs.surfaceContainerHigh, cs.onSurface),
    };
    return Semantics(
      label: label,
      value: switch (state) {
        ModifierState.once => Fr.modifierOnce,
        ModifierState.locked => Fr.modifierLocked,
        _ => null,
      },
      toggled: state == null ? null : state != ModifierState.off,
      button: true,
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Material(
          color: bg,
          borderRadius: BorderRadius.circular(Space.s),
          child: InkWell(
            borderRadius: BorderRadius.circular(Space.s),
            // la touche ne prend pas le focus : le clavier et le terminal le gardent
            canRequestFocus: false,
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: Space.s),
                child: Center(
                  child: Text(
                    text,
                    style: TextStyle(color: fg, fontWeight: FontWeight.w600, fontFamily: 'monospace'),
                    // barre de 48 dp : la taille du texte du système compte, jusqu'à 130 %
                    textScaler: MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.3),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

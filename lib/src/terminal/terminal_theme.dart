import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

/// Fond du terminal en thème sombre : presque noir, pour le contraste des 16 couleurs.
const terminalDarkBackground = Color(0xFF0D0E10);

/// Thème du terminal (phase 13) suivant [cs] : fond `surface` en clair, presque noir en sombre ; 16 couleurs ANSI
/// lisibles sur ce fond (le « blanc » reste visible sur fond clair).
TerminalTheme terminalTheme(ColorScheme cs) {
  final dark = cs.brightness == Brightness.dark;
  final p = dark ? _dark : _light;
  return TerminalTheme(
    cursor: cs.primary,
    selection: cs.primary.withValues(alpha: 0.35),
    foreground: dark ? const Color(0xFFE6E6E6) : cs.onSurface,
    background: dark ? terminalDarkBackground : cs.surface,
    black: p[0],
    red: p[1],
    green: p[2],
    yellow: p[3],
    blue: p[4],
    magenta: p[5],
    cyan: p[6],
    white: p[7],
    brightBlack: p[8],
    brightRed: p[9],
    brightGreen: p[10],
    brightYellow: p[11],
    brightBlue: p[12],
    brightMagenta: p[13],
    brightCyan: p[14],
    brightWhite: p[15],
    searchHitBackground: const Color(0xFFFFDF5D),
    searchHitBackgroundCurrent: const Color(0xFFFF9632),
    searchHitForeground: const Color(0xFF000000),
  );
}

const _light = [
  Color(0xFF24292F), Color(0xFFCF222E), Color(0xFF116329), Color(0xFF7D4E00), //
  Color(0xFF0550AE), Color(0xFF8250DF), Color(0xFF1B7C83), Color(0xFF6E7781), //
  Color(0xFF57606A), Color(0xFFA40E26), Color(0xFF1A7F37), Color(0xFF633C01), //
  Color(0xFF0969DA), Color(0xFF6639BA), Color(0xFF136061), Color(0xFF8C959F), //
];

const _dark = [
  Color(0xFF6E7681), Color(0xFFFF7B72), Color(0xFF3FB950), Color(0xFFD29922), //
  Color(0xFF58A6FF), Color(0xFFBC8CFF), Color(0xFF39C5CF), Color(0xFFB1BAC4), //
  Color(0xFF8B949E), Color(0xFFFFA198), Color(0xFF56D364), Color(0xFFE3B341), //
  Color(0xFF79C0FF), Color(0xFFD2A8FF), Color(0xFF56D4DD), Color(0xFFFFFFFF), //
];

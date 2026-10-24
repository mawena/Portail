import 'package:flutter_test/flutter_test.dart';
import 'package:fluluks/src/terminal/portail_terminal.dart';
import 'package:xterm/xterm.dart';

/// Défauts d'xterm 4.0.0 vus sur le Pixel (phase 13, essais) : après `clear` (ESC[3J, historique effacé) ou un
/// historique plein, les numéros de ligne et le repli au changement de largeur étaient faux.
void main() {
  PortailTerminal term({int maxLines = 100}) => PortailTerminal(maxLines: maxLines)..resize(10, 5);

  void lines(Terminal t, int from, int to) {
    for (var i = from; i < to; i++) {
      t.write('l$i\r\n');
    }
  }

  List<String> texts(Terminal t) =>
      [for (var i = 0; i < t.buffer.lines.length; i++) t.buffer.lines[i].getText().trim()];

  void expectIndices(Terminal t) {
    for (var i = 0; i < t.buffer.lines.length; i++) {
      expect(t.buffer.lines[i].index, i, reason: 'ligne $i');
    }
  }

  test('clearKeepsLineIndices', () {
    final t = term();
    lines(t, 0, 20);
    t.write('\x1b[H\x1b[2J\x1b[3Jmot');
    expect(t.buffer.lines.length, 5);
    expectIndices(t);
    // la sélection d'un mot (appui long) se lit sur la bonne ligne
    final range = BufferRangeLine(CellOffset(0, 0), CellOffset(3, 0));
    expect(t.buffer.getText(range), 'mot');
  });

  test('widthChangeAfterClearKeepsScreen', () {
    final t = term();
    lines(t, 0, 20);
    t.write('\x1b[H\x1b[2J\x1b[3Jmot');
    t.resize(20, 5);
    expect(texts(t).first, 'mot');
    expect(texts(t).skip(1).every((l) => l.isEmpty), isTrue);
    expectIndices(t);
  });

  test('widthChangeWithFullScrollbackKeepsOrder', () {
    final t = term(maxLines: 30);
    lines(t, 0, 100); // historique plein : le tampon circulaire a tourné
    t.resize(20, 5);
    final all = texts(t).where((l) => l.isNotEmpty).toList();
    expect(all, [for (var i = 100 - all.length; i < 100; i++) 'l$i']);
    expect(all.length, greaterThan(20));
    expectIndices(t);
  });

  test('altScreenShrinkKeepsLineIndices', () {
    final t = PortailTerminal(maxLines: 100)..resize(10, 10);
    t.write('\x1b[?1049h');
    lines(t, 0, 12); // curseur en bas de l'écran alternatif
    t.resize(10, 5); // rotation : moins de lignes
    expectIndices(t);
  });
}

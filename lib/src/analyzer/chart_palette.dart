import 'package:flutter/material.dart';

/// Teintes des enfants directs de la racine de la vue (bleu, vert, orange, violet, rouge, sarcelle, olive, indigo).
const _hues = [212.0, 140.0, 25.0, 285.0, 345.0, 175.0, 55.0, 248.0];

/// Couleur d'un segment ou d'une cellule : une des huit teintes selon [topIndex], éclaircie (thème clair) ou assombrie
/// (thème sombre) avec la profondeur, toujours à 3:1 au moins contre `surface` jusqu'à la profondeur 3 ; un fichier
/// en ton neutre de la même teinte ; contenu résumé, part hors analyse et dossier illisible en gris.
Color segmentColor(ColorScheme s, {required int topIndex, required int depth, required String kind}) {
  switch (kind) {
    case 'others':
    case 'inaccessible':
    case 'excluded':
    case 'otherFs':
      return s.outline;
    case 'unscanned':
      return s.surfaceContainerHighest;
  }
  final dark = s.brightness == Brightness.dark;
  final d = (depth - 1).clamp(0, 3);
  final hue = _hues[topIndex % _hues.length];
  final saturation = kind == 'file' ? 0.22 : (dark ? 0.62 : 0.70);
  // la profondeur 3 est la plus proche du fond : les autres s'en écartent d'un pas chacune
  final edge = _edge(s, hue, saturation);
  final lightness = dark ? edge + _step * (3 - d) : edge - _step * (3 - d);
  return HSLColor.fromAHSL(1, hue, saturation, lightness.clamp(0.05, 0.95)).toColor();
}

const _step = 0.05;
const _minContrast = 3.2;
final _edges = <(Color, double, double), double>{};

/// Luminosité HSL la plus proche de `surface` (la plus claire en thème clair, la plus sombre en thème sombre) qui garde
/// [_minContrast] contre lui ; la luminosité HSL n'étant pas perceptuelle, elle est cherchée teinte par teinte.
double _edge(ColorScheme s, double hue, double saturation) => _edges.putIfAbsent((s.surface, hue, saturation), () {
      final dark = s.brightness == Brightness.dark;
      var l = dark ? 0.20 : 0.80;
      Color c() => HSLColor.fromAHSL(1, hue, saturation, l).toColor();
      while (contrastRatio(c(), s.surface) < _minContrast && l > 0.05 && l < 0.95) {
        l += dark ? 0.01 : -0.01;
      }
      return l;
    });

/// Rapport de contraste WCAG entre deux couleurs.
double contrastRatio(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

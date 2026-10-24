import 'dart:math';

import 'package:xterm/xterm.dart';

/// Terminal xterm de Portail, avec deux défauts d'xterm 4.0.0 corrigés (vus sur le Pixel) :
/// - effacer l'historique (`clear` envoie ESC[3J) décale le tampon sans renuméroter ses lignes : sélection, copie et
///   « Enregistrer comme commande » lisaient une ligne vide ou une autre ligne ;
/// - le repli du texte au changement de largeur (rotation, pincement, taille du texte) suppose un tampon qui commence
///   au début de son tableau : après un `clear` ou un historique plein, l'écran se remplissait d'anciennes lignes.
/// Le tampon est donc reconstruit (lignes retirées puis remises, dans l'ordre) avant le repli et après chaque
/// effacement d'historique.
class PortailTerminal extends Terminal {
  PortailTerminal({super.maxLines, super.onOutput, super.onResize, super.onTitleChange, super.onBell});

  @override
  void eraseScrollbackOnly() {
    final b = buffer;
    if (b.height <= b.viewHeight) return;
    _rebuild(b, from: b.scrollBack);
  }

  @override
  void resize(int newWidth, int newHeight, [int? pixelWidth, int? pixelHeight]) {
    if (max(newWidth, 1) != viewWidth) _rebuild(mainBuffer);
    super.resize(newWidth, newHeight, pixelWidth, pixelHeight);
    if (isUsingAltBuffer) _rebuild(altBuffer); // xterm efface l'historique de l'écran alternatif après le changement
  }

  /// Remet les lignes de [b] à partir de [from] au début du tableau, numérotées de 0.
  static void _rebuild(Buffer b, {int from = 0}) {
    final keep = [for (var i = from; i < b.lines.length; i++) b.lines[i]];
    b.lines.clear();
    b.lines.pushAll(keep);
  }
}

import 'dart:math';

import 'package:flutter/services.dart';

/// Caractères des mots de passe générés : minuscules, majuscules, chiffres et `-_.!?@#%+=` (72 caractères).
const passwordAlphabet = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.!?@#%+=';

const _classes = ['abcdefghijklmnopqrstuvwxyz', 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', '0123456789', '-_.!?@#%+='];

/// Source d'aléa des mots de passe : celle du système (`Random.secure`).
final Random defaultRandom = Random.secure();

/// Mot de passe de [length] caractères tirés de [passwordAlphabet], avec au moins une minuscule, une majuscule, un
/// chiffre et un symbole (tirage refait sinon : chaque caractère reste uniforme).
String generatePassword({int length = 20, Random? random}) {
  final r = random ?? defaultRandom;
  while (true) {
    final p = String.fromCharCodes(List.generate(length, (_) => passwordAlphabet.codeUnitAt(r.nextInt(passwordAlphabet.length))));
    if (length < _classes.length || _classes.every((c) => p.split('').any(c.contains))) return p;
  }
}

/// Phrase de passe de [count] mots distincts de [words] (liste de l'EFF), séparés par `-` ; les quelques mots qui
/// contiennent eux-mêmes un tiret sont écartés, pour que la phrase se relise sans ambiguïté.
String generatePassphrase(List<String> words, {int count = 6, Random? random}) {
  final r = random ?? defaultRandom;
  final pool = words.where((w) => w.isNotEmpty && !w.contains('-')).toList();
  final picked = <String>[];
  while (picked.length < count) {
    final w = pool[r.nextInt(pool.length)];
    if (!picked.contains(w)) picked.add(w);
  }
  return picked.join('-');
}

List<String>? _effWords;

/// Liste de l'EFF (7776 mots), lue une fois depuis les ressources de l'application.
Future<List<String>> loadEffWords() async {
  final cached = _effWords;
  if (cached != null) return cached;
  final text = await rootBundle.loadString('assets/words/eff_large.txt');
  return _effWords = text.split('\n').map((w) => w.trim()).where((w) => w.isNotEmpty).toList(growable: false);
}

import 'dart:io';
import 'dart:math';

import 'package:fluluks/src/crypto/password_generator.dart';
import 'package:fluluks/src/crypto/password_strength.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final words = File('assets/words/eff_large.txt').readAsLinesSync().where((w) => w.isNotEmpty).toList();
  final set = words.toSet();

  test('strengthLevels', () {
    expect(estimate('motdepasse', words: set), Strength.veryWeak);
    expect(estimate('password', words: set), Strength.veryWeak);
    expect(estimate('Tr0ub4dour&3', words: set), Strength.fair);
    final rnd = Random(5);
    for (var i = 0; i < 50; i++) {
      final p = generatePassphrase(words, random: rnd);
      expect(estimate(p, words: set), anyOf(Strength.good, Strength.excellent), reason: p);
    }
    for (var i = 0; i < 200; i++) {
      final p = generatePassword(random: rnd);
      expect(estimate(p, words: set), Strength.excellent, reason: p);
    }
    expect(estimate(''), Strength.veryWeak);
    // seuils : < 28, < 36, < 60, < 80 bits
    expect(strengthOf(27.9), Strength.veryWeak);
    expect(strengthOf(28), Strength.weak);
    expect(strengthOf(36), Strength.fair);
    expect(strengthOf(60), Strength.good);
    expect(strengthOf(80), Strength.excellent);
  });

  test('sequencesPenalized', () {
    expect(entropyBits('abcdefghij'), lessThan(entropyBits('qmzxwkrtpv') - 20));
    expect(estimate('12345678'), Strength.veryWeak);
    expect(estimate('87654321'), Strength.veryWeak);
    expect(estimate('aaaaaaaa'), Strength.veryWeak);
    expect(estimate('azertyuiop'), Strength.veryWeak);
    expect(estimate('qwertyuiop'), Strength.veryWeak);
    expect(entropyBits('Soleil2024!'), lessThan(entropyBits('Xq7#vL2m!k')));
    // un mot de la liste compte comme un mot, pas comme ses lettres
    expect(entropyBits('battery', words: set), lessThan(entropyBits('battery')));
  });
}

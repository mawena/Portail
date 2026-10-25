import 'dart:io';
import 'dart:math';

import 'package:fluluks/src/crypto/password_generator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final words = File('assets/words/eff_large.txt').readAsLinesSync().where((w) => w.isNotEmpty).toList();

  test('generatorUsesSecureRandomAndAllClasses', () {
    expect(defaultRandom.runtimeType, Random.secure().runtimeType);
    const symbols = '-_.!?@#%+=';
    for (var i = 0; i < 300; i++) {
      final p = generatePassword();
      expect(p.length, 20);
      expect(p.split('').every(passwordAlphabet.contains), isTrue, reason: p);
      expect(RegExp('[a-z]').hasMatch(p), isTrue, reason: p);
      expect(RegExp('[A-Z]').hasMatch(p), isTrue, reason: p);
      expect(RegExp('[0-9]').hasMatch(p), isTrue, reason: p);
      expect(p.split('').any(symbols.contains), isTrue, reason: p);
    }
    expect(passwordAlphabet.length, 26 + 26 + 10 + symbols.length);
    expect(generatePassword(length: 32).length, 32);
    expect(generatePassword(), isNot(generatePassword()));
  });

  test('passphraseHasSixDistinctListWords', () {
    final set = words.toSet();
    for (var i = 0; i < 100; i++) {
      final p = generatePassphrase(words);
      final parts = p.split('-');
      expect(parts.length, 6, reason: p);
      expect(parts.toSet().length, 6, reason: p);
      expect(parts.every(set.contains), isTrue, reason: p);
    }
    expect(generatePassphrase(words, count: 4).split('-').length, 4);
  });

  test('wordListIs7776Unique', () {
    expect(words.length, 7776);
    expect(words.toSet().length, 7776);
    expect(words.every((w) => RegExp(r'^[a-z]+(-[a-z]+)?$').hasMatch(w)), isTrue);
    expect(words.first, 'abacus');
    expect(words.last, 'zoom');
    expect(File('assets/words/LICENCE-EFF.txt').readAsStringSync(), contains('CC BY 3.0 US'));
  });
}

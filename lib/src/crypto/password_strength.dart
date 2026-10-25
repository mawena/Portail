import 'dart:math';

/// Force d'un mot de passe, de « très faible » à « excellent ».
enum Strength { veryWeak, weak, fair, good, excellent }

/// Niveau pour une entropie estimée : très faible < 28 bits, faible < 36, moyen < 60, bon < 80, excellent au-delà.
Strength strengthOf(double bits) => bits < 28
    ? Strength.veryWeak
    : bits < 36
        ? Strength.weak
        : bits < 60
            ? Strength.fair
            : bits < 80
                ? Strength.good
                : Strength.excellent;

/// Force estimée de [pw] ; [words] : liste de l'EFF, dont chaque mot compte comme un mot et non comme ses lettres.
Strength estimate(String pw, {Set<String>? words}) => strengthOf(entropyBits(pw, words: words));

/// Mots de passe et mots trop courants, comptés presque pour rien.
const _common = [
  'motdepasse', 'motdepass', 'password', 'passw0rd', 'azerty', 'qwerty', 'soleil', 'bonjour', 'marseille', 'loulou',
  'doudou', 'chouchou', 'nicolas', 'camille', 'secret', 'admin', 'iloveyou', 'jetaime', 'football', 'princesse',
  'dragon', 'monkey', 'letmein', 'welcome', 'sunshine', 'master', 'portail', 'superman', 'batman', 'pokemon',
  'chocolat', 'coucou', 'abc123', 'freedom', 'shadow', 'michael', 'jordan', 'charlie', 'liberte', 'amour',
];

/// Rangées du clavier (AZERTY, QWERTY, QWERTZ) et des chiffres, lues dans les deux sens.
const _rows = ['azertyuiop', 'qsdfghjklm', 'wxcvbn', 'qwertyuiop', 'asdfghjkl', 'zxcvbnm', 'qwertzuiop', 'yxcvbnm', '1234567890'];

/// Substitutions courantes (« 0 » pour « o »…).
const _leet = {'0': 'o', '1': 'l', '3': 'e', '4': 'a', '5': 's', '7': 't', '8': 'b', '9': 'g', '@': 'a', r'$': 's', '!': 'i'};

const _vowels = 'aeiouy';
final _effBits = log(7776) / ln2;
const _wordLikeBitsPerLetter = 2.5;

/// Entropie estimée de [pw], en bits. Chaque caractère vaut log2 de l'alphabet de ses classes (minuscules,
/// majuscules, chiffres, symboles, autres), sauf les motifs reconnus, comptés bien moins : mot courant, mot de la
/// liste de l'EFF, caractère répété, suite (`abcd`, `4321`), rangée du clavier (`azerty`), suite de lettres
/// prononçable comme un mot (y compris avec des substitutions comme `Tr0ub4dour`). Une phrase de mots de l'EFF
/// séparés par un même séparateur compte log2(7776) par mot.
double entropyBits(String pw, {Set<String>? words}) {
  final raw = pw.runes.map(String.fromCharCode).toList();
  if (raw.isEmpty) return 0;
  final phrase = _passphraseBits(pw, words);
  if (phrase != null) return phrase;
  final cs = _charsetBits(raw);
  final lower = raw.map((c) => c.toLowerCase()).toList();
  final norm = [for (final c in lower) _leet[c] ?? c];
  var bits = 0.0;
  var i = 0;
  while (i < raw.length) {
    final (len, cost) = _best(raw, lower, norm, i, cs, words);
    bits += cost;
    i += len;
  }
  return bits;
}

double? _passphraseBits(String pw, Set<String>? words) {
  if (words == null) return null;
  for (final sep in const ['-', '_', ' ', '.', '+']) {
    if (!pw.contains(sep)) continue;
    final parts = pw.split(sep);
    if (parts.length < 3 || !parts.every((p) => words.contains(p.toLowerCase()))) continue;
    final caps = parts.where((p) => p != p.toLowerCase()).length;
    return parts.length * _effBits + log(5) / ln2 + caps;
  }
  return null;
}

double _charsetBits(List<String> raw) {
  var lower = false, upper = false, digit = false, symbol = false, other = false;
  for (final c in raw) {
    final u = c.codeUnitAt(0);
    if (u >= 0x61 && u <= 0x7a) {
      lower = true;
    } else if (u >= 0x41 && u <= 0x5a) {
      upper = true;
    } else if (u >= 0x30 && u <= 0x39) {
      digit = true;
    } else if (u < 0x80) {
      symbol = true;
    } else {
      other = true;
    }
  }
  final n = (lower ? 26 : 0) + (upper ? 26 : 0) + (digit ? 10 : 0) + (symbol ? 33 : 0) + (other ? 100 : 0);
  return log(max(n, 2)) / ln2;
}

bool _isLetter(String c) => c.length == 1 && c.codeUnitAt(0) >= 0x61 && c.codeUnitAt(0) <= 0x7a;

/// Bits ajoutés par la casse et les substitutions d'un motif de [len] caractères à [i].
double _mangling(List<String> raw, List<String> lower, int i, int len) {
  var caps = 0, leet = 0;
  for (var k = i; k < i + len; k++) {
    if (raw[k] != lower[k]) caps++;
    if (_leet.containsKey(lower[k])) leet++;
  }
  final capBits = caps == 0 ? 0 : (caps == len || (caps == 1 && raw[i] != lower[i]) ? 1 : caps);
  return (capBits + leet).toDouble();
}

/// Motif le plus avantageux à [i] : (longueur, coût en bits).
(int, double) _best(List<String> raw, List<String> lower, List<String> norm, int i, double cs, Set<String>? words) {
  var best = (1, cs);
  void offer(int len, double cost) {
    if (len * cs - cost > best.$1 * cs - best.$2) best = (len, cost);
  }

  final rest = raw.length - i;
  final normRest = norm.sublist(i).join();
  // mots courants
  for (final w in _common) {
    if (w.length <= rest && normRest.startsWith(w)) offer(w.length, 6 + _mangling(raw, lower, i, w.length));
  }
  // mots de la liste de l'EFF (4 à 9 lettres)
  if (words != null) {
    for (var len = min(9, rest); len >= 4; len--) {
      final s = normRest.substring(0, len);
      if (s.split('').every(_isLetter) && words.contains(s)) {
        offer(len, _effBits + _mangling(raw, lower, i, len));
        break;
      }
    }
  }
  // répétition d'un même caractère
  var n = 1;
  while (i + n < raw.length && lower[i + n] == lower[i]) {
    n++;
  }
  if (n >= 3) offer(n, cs + (n - 1));
  // suite croissante ou décroissante (abcd, 4321)
  if (rest >= 3) {
    final d = lower[i + 1].codeUnitAt(0) - lower[i].codeUnitAt(0);
    if (d == 1 || d == -1) {
      var m = 2;
      while (i + m < raw.length && lower[i + m].codeUnitAt(0) - lower[i + m - 1].codeUnitAt(0) == d) {
        m++;
      }
      if (m >= 3) offer(m, cs + (m - 1));
    }
  }
  // rangée du clavier
  for (var len = min(10, rest); len >= 4; len--) {
    final s = lower.sublist(i, i + len).join();
    if (_rows.any((r) => r.contains(s) || r.split('').reversed.join().contains(s))) {
      offer(len, cs + (len - 1));
      break;
    }
  }
  // suite de lettres prononçable, comme un mot
  var l = 0;
  while (i + l < raw.length && _isLetter(norm[i + l])) {
    l++;
  }
  if (l >= 4 && _wordLike(norm.sublist(i, i + l)) && _caseOk(raw, lower, i, l)) {
    offer(l, _wordLikeBitsPerLetter * l + _mangling(raw, lower, i, l));
  }
  return best;
}

bool _caseOk(List<String> raw, List<String> lower, int i, int len) {
  var caps = 0;
  for (var k = i; k < i + len; k++) {
    if (raw[k] != lower[k]) caps++;
  }
  return caps == 0 || caps == len || (caps == 1 && raw[i] != lower[i]);
}

bool _wordLike(List<String> s) {
  final v = s.where(_vowels.contains).length;
  final ratio = v / s.length;
  if (ratio < 0.25 || ratio > 0.7) return false;
  var cons = 0, same = 1;
  for (var k = 0; k < s.length; k++) {
    cons = _vowels.contains(s[k]) ? 0 : cons + 1;
    if (cons >= 4) return false;
    same = k > 0 && s[k] == s[k - 1] ? same + 1 : 1;
    if (same >= 3) return false;
  }
  return true;
}

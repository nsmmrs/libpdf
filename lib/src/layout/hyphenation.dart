/// Hyphenation by Liang's algorithm over TeX patterns (Franklin Liang,
/// "Word Hy-phen-a-tion by Com-put-er", 1983), the patterns hyph-utf8
/// distributes for many languages.
library;

import 'dart:math' as math;

import 'package:libpdf/src/layout/paragraph.dart';

/// A hyphenator of TeX hyphenation patterns (`.hy1p`, `a1b2c`...:
/// letters with digits between them, dots for the word's ends) and
/// exceptions (words hyphenated by hand: `as-so-ciate`).
///
/// A word is hyphenated where the highest digit of the patterns that match
/// around a place is odd, keeping at least [left] letters before the first
/// hyphen and [right] after the last (TeX's `\lefthyphenmin` and
/// `\righthyphenmin`).
final class PatternHyphenator implements Hyphenator {
  /// A hyphenator of [patterns] and [exceptions] (both separated by
  /// whitespace).
  new(
    String patterns, {
    String exceptions = '',
    this.left = 2,
    this.right = 3,
  }) {
    for (final pattern in patterns.split(RegExp(r'\s+'))) {
      if (pattern.isEmpty || pattern.startsWith('%')) continue;
      final letters = <int>[];
      final values = <int>[0];
      for (final rune in pattern.runes) {
        if (rune >= 0x30 && rune <= 0x39) {
          values[values.length - 1] = rune - 0x30;
        } else {
          letters.add(rune);
          values.add(0);
        }
      }
      final key = String.fromCharCodes(letters);
      _patterns[key] = values;
      _longest = math.max(_longest, letters.length);
    }
    for (final exception in exceptions.split(RegExp(r'\s+'))) {
      if (exception.isEmpty || exception.startsWith('%')) continue;
      final positions = <int>[];
      var length = 0;
      for (final rune in exception.runes) {
        if (rune == 0x2d) {
          positions.add(length);
        } else {
          length++;
        }
      }
      _exceptions[exception.replaceAll('-', '').toLowerCase()] = positions;
    }
  }

  /// The fewest letters before a hyphen.
  final int left;

  /// The fewest letters after a hyphen.
  final int right;

  final Map<String, List<int>> _patterns = {};
  final Map<String, List<int>> _exceptions = {};
  final Map<String, List<int>> _cache = {};
  int _longest = 0;

  /// Whether there are any patterns.
  bool get isEmpty => _patterns.isEmpty && _exceptions.isEmpty;

  @override
  List<int> hyphenate(String word) => _cache[word] ??= _hyphenate(word);

  List<int> _hyphenate(String word) {
    final letters = word.toLowerCase().runes.toList();
    final n = letters.length;
    if (n < left + right) return const [];
    final lower = String.fromCharCodes(letters);
    if (_exceptions[lower] case final positions?) {
      return [
        for (final p in positions)
          if (p >= left && n - p >= right) p,
      ];
    }
    // The word between dots; values[g] is the value of the gap before
    // work[g].
    final work = [0x2e, ...letters, 0x2e];
    final values = List.filled(work.length + 1, 0);
    for (var i = 0; i < work.length; i++) {
      final end = math.min(work.length, i + _longest);
      for (var j = i + 1; j <= end; j++) {
        final pattern = _patterns[String.fromCharCodes(work, i, j)];
        if (pattern == null) continue;
        for (var k = 0; k < pattern.length; k++) {
          if (pattern[k] > values[i + k]) values[i + k] = pattern[k];
        }
      }
    }
    // The gap before the word's letter p is the gap before work[p + 1].
    return [
      for (var p = left; p <= n - right; p++)
        if (values[p + 1].isOdd) p,
    ];
  }
}

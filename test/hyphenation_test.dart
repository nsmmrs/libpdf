import 'package:libpdf/libpdf.dart';
import 'package:test/test.dart';

/// [word] with a hyphen at each of [hyphenator]'s points.
String hyphenated(PatternHyphenator hyphenator, String word) {
  final points = hyphenator.hyphenate(word);
  final out = StringBuffer();
  for (var i = 0; i < word.length; i++) {
    if (points.contains(i)) out.write('-');
    out.write(word[i]);
  }
  return out.toString();
}

void main() {
  // The patterns of The TeXbook's appendix H that hyphenate "hyphenation".
  final texbook = PatternHyphenator(
    '.hy3ph he2n hena4 hen5at 1na n2at 1tio 2io o2n',
  );

  test('the highest digit around a place decides it: odd breaks', () {
    expect(hyphenated(texbook, 'hyphenation'), 'hy-phen-ation');
    // Case doesn't matter; the points are offsets in the word.
    expect(texbook.hyphenate('Hyphenation'), [2, 6]);
  });

  test('the fewest letters before and after a hyphen', () {
    final strict = PatternHyphenator(
      '.hy3ph he2n hena4 hen5at 1na n2at 1tio 2io o2n',
      left: 3,
      right: 5,
    );
    expect(hyphenated(strict, 'hyphenation'), 'hyphen-ation');
    expect(texbook.hyphenate('hy'), isEmpty);
  });

  test('exceptions are hyphenated as written', () {
    final hyphenator = PatternHyphenator(
      '1na',
      exceptions: 'as-so-ciate ta-ble',
    );
    expect(hyphenated(hyphenator, 'associate'), 'as-so-ciate');
    expect(hyphenated(hyphenator, 'table'), 'ta-ble');
    expect(hyphenator.hyphenate('as'), isEmpty);
  });

  test('letters outside ASCII', () {
    final german = PatternHyphenator('1ß ä1', left: 1, right: 1);
    expect(german.hyphenate('Straße'), [4]);
    expect(german.hyphenate('Bär'), [2]);
  });
}

import 'dart:convert';

import 'package:libpdf/libpdf.dart';
import 'package:test/test.dart';

void main() {
  test('md5', () {
    String hex(List<int> b) =>
        [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();
    expect(hex(md5(const [])), 'd41d8cd98f00b204e9800998ecf8427e');
    expect(
      hex(md5(utf8.encode('The quick brown fox jumps over the lazy dog'))),
      '9e107d9d372bb6826bd81d3542a419d6',
    );
    expect(hex(md5(List<int>.filled(1000, 97))), isNotEmpty);
  });
}

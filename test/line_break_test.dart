import 'dart:convert';
import 'dart:io';

import 'package:libpdf/src/layout/line_break.dart';
import 'package:test/test.dart';

/// The cases of the Unicode conformance test `LineBreakTest.txt`: the
/// code points, and after each the expected decision (`÷` break, `×` no
/// break).
List<(String line, String text, List<int> breaks)> _cases() {
  final lines = const LineSplitter().convert(
    utf8.decode(
      gzip.decode(File('test/unicode/LineBreakTest.txt.gz').readAsBytesSync()),
    ),
  );
  return [
    for (final line in lines)
      if (line.split('#').first.trim() case final data when data.isNotEmpty)
        () {
          final text = StringBuffer();
          final breaks = <int>[];
          for (final token in data.split(RegExp(r'\s+'))) {
            switch (token) {
              case '÷':
                if (text.isNotEmpty) breaks.add(text.length);
              case '×':
                break;
              default:
                text.writeCharCode(int.parse(token, radix: 16));
            }
          }
          return (line, text.toString(), breaks);
        }(),
  ];
}

void main() {
  test('the Unicode conformance test (LineBreakTest.txt) passes', () {
    final failures = <String>[];
    final cases = _cases();
    for (final (line, text, expected) in cases) {
      final actual = [for (final b in lineBreaks(text)) b.offset];
      if (actual.join(',') != expected.join(',')) {
        failures.add('$line\n  got breaks at $actual');
      }
    }
    expect(cases.length, greaterThan(15000));
    expect(
      failures,
      isEmpty,
      reason:
          '${failures.length} of ${cases.length} failed:\n'
          '${failures.take(20).join('\n')}',
    );
  });

  test('mandatory breaks', () {
    expect(lineBreaks('a\nb'), [
      const LineBreak(2, mandatory: true),
      const LineBreak(3, mandatory: true),
    ]);
    expect(lineBreaks('a\r\nb').first, const LineBreak(3, mandatory: true));
    expect(lineBreaks('a b'), [
      const LineBreak(2, mandatory: false),
      const LineBreak(3, mandatory: true),
    ]);
    expect(lineBreaks(''), isEmpty);
  });

  test('classes', () {
    expect(lineBreakClass(0x41), LineBreakClass.al);
    expect(lineBreakClass(0x20), LineBreakClass.sp);
    expect(lineBreakClass(0x3042), LineBreakClass.id);
    expect(lineBreakClass(0x2010), LineBreakClass.hh);
  });
}

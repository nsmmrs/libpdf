// Damaged input: the decoders and parsers either read it or reject it
// with their format exception, and never fail otherwise (a RangeError, a
// TypeError, a hang). The damage is random but seeded, so a failure is
// reproducible.

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:libpdf/libpdf.dart';
import 'package:test/test.dart';

/// [count] damaged copies of [bytes]: bytes flipped, the end cut off, bytes
/// inserted, a run zeroed.
Iterable<Uint8List> damaged(Uint8List bytes, Random random, int count) sync* {
  for (var i = 0; i < count; i++) {
    final copy = Uint8List.fromList(bytes);
    switch (i % 4) {
      case 0:
        for (var k = 0; k < 1 + random.nextInt(8); k++) {
          copy[random.nextInt(copy.length)] = random.nextInt(256);
        }
        yield copy;
      case 1:
        yield Uint8List.sublistView(copy, 0, random.nextInt(copy.length));
      case 2:
        final at = random.nextInt(copy.length);
        yield Uint8List.fromList([
          ...copy.sublist(0, at),
          for (var k = 0; k < 1 + random.nextInt(16); k++) random.nextInt(256),
          ...copy.sublist(at),
        ]);
      default:
        final at = random.nextInt(copy.length);
        final end = min(copy.length, at + 1 + random.nextInt(64));
        copy.fillRange(at, end, 0);
        yield copy;
    }
  }
}

/// Runs [read] on damaged copies of each of [files]; fails on any error
/// but [expected].
void fuzz(
  String name,
  List<File> files,
  void Function(Uint8List bytes) read,
  bool Function(Object error) expected, {
  int count = 200,
}) {
  test('$name: damaged input is read or rejected', () {
    final random = Random(20261006);
    for (final file in files) {
      final bytes = file.readAsBytesSync();
      var i = 0;
      for (final input in damaged(bytes, random, count)) {
        try {
          read(input);
        } on Object catch (error, stack) {
          if (!expected(error)) {
            final where = stack.toString().split('\n').take(6).join('\n');
            fail('${file.path}, damaged copy $i: $error\n$where');
          }
        }
        i++;
      }
    }
  });
}

List<File> files(String dir, String suffix, {int limit = 12}) =>
    (Directory(dir)
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith(suffix))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path)))
        .take(limit)
        .toList();

void main() {
  fuzz(
    'JPEG',
    files('test/images/jpeg', '.jpg'),
    PdfImage.parse,
    (error) => error is ImageFormatException,
  );
  fuzz(
    'PNG',
    files('test/images/pngsuite', '.png', limit: 24),
    PdfImage.parse,
    (error) => error is ImageFormatException,
  );
  fuzz('SVG', files('test/svg', '.svg'), (bytes) {
    final svg = SvgImage.parse(String.fromCharCodes(bytes));
    final document = PdfDocument();
    svg.paint(
      document.addPage(const PdfRect(0, 0, 200, 200)).canvas,
      const PdfRect(0, 0, 200, 200),
    );
  }, (error) => error is FormatException);
  fuzz(
    'OpenType',
    files('test/fonts', 'f', limit: 8),
    (bytes) {
      final font = EmbeddedFont.parse(bytes);
      final style = PdfTextStyle(font, 12);
      final document = PdfDocument();
      document
          .addPage(const PdfRect(0, 0, 200, 200))
          .canvas
          .text('Hello, fuzz', 10, 100, style);
      document.save();
    },
    (error) => error is FontFormatException,
    count: 100,
  );
  fuzz(
    'PDF reading',
    [File('test/golden/hello.pdf')],
    (bytes) {
      final file = PdfFile.parse(bytes);
      final document = PdfDocument();
      for (final page in file.pages) {
        final rect = PdfRect(0, 0, page.intrinsicWidth, page.intrinsicHeight);
        page.paint(document.addPage(rect).canvas, rect);
      }
      document.save();
    },
    (error) => error is PdfFormatException,
    count: 600,
  );
}

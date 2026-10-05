@Tags(['pdf-tools'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:libpdf/libpdf.dart';
import 'package:test/test.dart';

import 'sample_document.dart';

/// The pages of [pdf] rendered by poppler, gray, at 36 dpi, as PGM files.
List<Uint8List> renderPages(File pdf, int count) => [
  for (var page = 1; page <= count; page++)
    () {
      final out = '${pdf.path}-$page';
      final result = Process.runSync('pdftoppm', [
        '-gray',
        '-r',
        '36',
        '-f',
        '$page',
        '-l',
        '$page',
        '-singlefile',
        pdf.path,
        out,
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      return File('$out.pgm').readAsBytesSync();
    }(),
];

/// The samples of a binary PGM, with its size.
(int, int, Uint8List) samples(Uint8List pgm) {
  final header = latin1.decode(pgm.sublist(0, 20)).split(RegExp(r'\s+'));
  final width = int.parse(header[1]);
  final height = int.parse(header[2]);
  return (
    width,
    height,
    Uint8List.sublistView(pgm, pgm.length - width * height),
  );
}

void main() {
  test(
    'the sample document renders as its golden images',
    () {
      final dir = Directory.systemTemp.createTempSync('libpdf.');
      addTearDown(() => dir.deleteSync(recursive: true));
      final result = sampleLayout().layout(sampleContent());
      final document = PdfDocument();
      result.render(document);
      final pdf = File('${dir.path}/sample.pdf')
        ..writeAsBytesSync(document.save());
      final pages = renderPages(pdf, result.pageCount);
      final update = Platform.environment['LIBPDF_UPDATE_GOLDENS'] == '1';
      for (final (i, page) in pages.indexed) {
        final golden = File('test/golden/layout-${i + 1}.pgm.gz');
        if (update) {
          golden.writeAsBytesSync(gzip.encode(page));
          continue;
        }
        final (w, h, actual) = samples(page);
        final (gw, gh, expected) = samples(
          Uint8List.fromList(gzip.decode(golden.readAsBytesSync())),
        );
        expect((w, h), (gw, gh), reason: 'page ${i + 1} size');
        var sum = 0;
        var far = 0;
        for (var p = 0; p < actual.length; p++) {
          final d = (actual[p] - expected[p]).abs();
          sum += d;
          if (d > 96) far++;
        }
        // Poppler and FreeType versions antialias text a little
        // differently; layout changes move whole lines.
        expect(sum / actual.length, lessThan(3), reason: 'page ${i + 1}');
        expect(far / actual.length, lessThan(0.01), reason: 'page ${i + 1}');
      }
      expect(
        Directory('test/golden')
            .listSync()
            .where((f) => f.path.contains('layout-'))
            .length,
        pages.length,
        reason: 'one golden per page',
      );
    },
    skip: Process.runSync('which', ['pdftoppm']).exitCode == 0
        ? false
        : 'needs poppler',
  );
}

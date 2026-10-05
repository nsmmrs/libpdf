@Tags(['pdf-tools'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:libpdf/libpdf.dart';
import 'package:libpdf/src/reader/filters.dart';
import 'package:test/test.dart';

import 'drawing_test.dart' show near, render;

bool _has(String tool) => Process.runSync('which', [tool]).exitCode == 0;

final bool _tools = ['qpdf', 'pdftoppm', 'pdftotext'].every(_has);

late Directory _dir;
int _count = 0;

File _write(List<int> bytes) =>
    File('${_dir.path}/r${_count++}.pdf')..writeAsBytesSync(bytes);

String _text(File pdf) =>
    Process.runSync('pdftotext', ['-layout', pdf.path, '-']).stdout as String;

/// A document of two pages: "first" on a red A4 page, "second" on a
/// blue US Letter page rotated by [rotation].
Uint8List _source({int rotation = 0, bool compact = false}) {
  final document = PdfDocument();
  final style = PdfTextStyle(StandardFont.helvetica, 24);
  document.addPage(const PdfRect(0, 0, 595.28, 841.89)).canvas
    ..setFillColor(const RgbColor(1, 0, 0))
    ..rect(const PdfRect(0, 0, 595.28, 841.89))
    ..fill()
    ..setFillColor(const GrayColor(0))
    ..text('first', 72, 700, style);
  document.addPage(const PdfRect(0, 0, 612, 792), rotation: rotation).canvas
    ..setFillColor(const RgbColor(0, 0, 1))
    ..rect(const PdfRect(0, 0, 306, 792))
    ..fill()
    ..setFillColor(const GrayColor(0))
    ..text('second', 400, 700, style);
  return document.save(
    options: PdfWriterOptions(deterministic: true, compact: compact),
  );
}

/// [page] painted on a page of its size, saved.
File _imported(ImportedPage page) {
  final document = PdfDocument();
  final rect = PdfRect(0, 0, page.intrinsicWidth, page.intrinsicHeight);
  page.paint(document.addPage(rect).canvas, rect);
  final file = _write(
    document.save(options: const PdfWriterOptions(deterministic: true)),
  );
  final check = Process.runSync('qpdf', ['--check', file.path]);
  expect(check.exitCode, 0, reason: '${check.stdout}${check.stderr}');
  return file;
}

void main() {
  setUpAll(() => _dir = Directory.systemTemp.createTempSync('libpdf-reader.'));
  tearDownAll(() => _dir.deleteSync(recursive: true));

  group('PdfFile', () {
    for (final compact in [false, true]) {
      test('reads the pages of a file it wrote (compact: $compact)', () {
        final file = PdfFile.parse(_source(compact: compact));
        expect(file.pages, hasLength(2));
        expect(file.pages[0].intrinsicWidth, closeTo(595.28, 0.01));
        expect(file.pages[1].intrinsicHeight, 792);
        expect(latin1.decode(file.pages[1].content), contains('(second)'));
      });
    }

    test('reads the cross-reference streams and object streams qpdf '
        'writes', () {
      final source = _write(_source());
      final out = '${_dir.path}/qpdf.pdf';
      final result = Process.runSync('qpdf', [
        '--object-streams=generate',
        '--compress-streams=y',
        source.path,
        out,
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final file = PdfFile.parse(File(out).readAsBytesSync());
      expect(file.pages, hasLength(2));
      expect(_text(_imported(file.pages[0])), contains('first'));
    });

    test('rebuilds the cross-references of a file whose offsets are '
        'wrong', () {
      final bytes = latin1.decode(_source());
      final broken = bytes.replaceFirstMapped(
        RegExp(r'startxref\n(\d+)'),
        (match) => 'startxref\n${int.parse(match[1]!) + 7}',
      );
      final file = PdfFile.parse(latin1.encode(broken));
      expect(file.pages, hasLength(2));
      expect(_text(_imported(file.pages[1])), contains('second'));
    });

    test('reports a file that is not a PDF file', () {
      expect(
        () => PdfFile.parse(Uint8List.fromList(utf8.encode('hello'))),
        throwsA(isA<PdfFormatException>()),
      );
    });
  }, skip: _tools ? false : 'needs qpdf and poppler');

  group('ImportedPage', () {
    test('paints the page with its text and its graphics', () {
      final file = PdfFile.parse(_source());
      final pdf = _imported(file.pages[0]);
      expect(_text(pdf), contains('first'));
      expect(render(pdf).at(300, 100), near((255, 0, 0)));
    });

    test('paints a rotated page as it is displayed', () {
      final page = PdfFile.parse(_source(rotation: 90)).pages[1];
      expect((page.intrinsicWidth, page.intrinsicHeight), (792.0, 612.0));
      final pdf = _imported(page);
      // Turned clockwise: the blue left half is now the top half.
      final rendered = render(pdf);
      expect(rendered.at(396, 500), near((0, 0, 255)));
      expect(rendered.at(396, 100), near((255, 255, 255)));
    });

    test('scales the page into the rectangle it is painted in', () {
      final page = PdfFile.parse(_source()).pages[1];
      final document = PdfDocument();
      page.paint(
        document.addPage(const PdfRect(0, 0, 400, 400)).canvas,
        const PdfRect(100, 100, 153, 198),
      );
      final pdf = _write(document.save());
      final rendered = render(pdf);
      expect(rendered.at(120, 200), near((0, 0, 255)));
      expect(rendered.at(240, 200), near((255, 255, 255)));
      expect(rendered.at(50, 200), near((255, 255, 255)));
    });

    test('is copied once, with its resources, however often it is '
        'painted', () {
      final page = PdfFile.parse(_source()).pages[0];
      final document = PdfDocument();
      for (var i = 0; i < 3; i++) {
        final rect = PdfRect(0, 0, page.intrinsicWidth, page.intrinsicHeight);
        page.paint(document.addPage(rect).canvas, rect);
      }
      final bytes = latin1.decode(
        document.save(options: const PdfWriterOptions(compact: false)),
      );
      expect(RegExp('/Subtype /Form').allMatches(bytes), hasLength(1));
      expect(RegExp('/BaseFont /Helvetica').allMatches(bytes), hasLength(1));
    });
  }, skip: _tools ? false : 'needs qpdf and poppler');

  group('stream filters', () {
    Uint8List decode(String filter, List<int> data, [PdfDict? params]) =>
        decodeStream(
          PdfStream(
            data,
            dict: PdfDict({'Filter': PdfName(filter), 'DecodeParms': ?params}),
          ),
          (object) => object,
        );

    test('ASCIIHexDecode', () {
      expect(
        ascii.decode(decode('ASCIIHexDecode', ascii.encode('48 65 6c6C 6>'))),
        'Hell`',
      );
    });

    test('ASCII85Decode', () {
      expect(
        ascii.decode(decode('ASCII85Decode', ascii.encode('87cURD]j7BEbo7~>'))),
        'Hello world',
      );
    });

    test('RunLengthDecode', () {
      expect(decode('RunLengthDecode', [2, 1, 2, 3, 254, 9, 128]), [
        1, 2, 3, 9, 9, 9, //
      ]);
    });

    test('LZWDecode (the example of ISO 32000-2, 7.4.4.2)', () {
      expect(
        ascii.decode(
          decode('LZWDecode', [
            0x80, 0x0b, 0x60, 0x50, 0x22, 0x0c, 0x0c, 0x85, 0x01, //
          ]),
        ),
        '-----A---B',
      );
    });

    test('FlateDecode with the PNG Up predictor', () {
      final rows = [2, 1, 2, 2, 1, 1];
      final data = decode(
        'FlateDecode',
        zlibEncode(rows),
        PdfDict({'Predictor': const PdfInt(12), 'Columns': const PdfInt(2)}),
      );
      expect(data, [1, 2, 2, 3]);
    });
  });
}

// Times libpdf and package:pdf making the same documents through their
// drawing APIs (no layout): text in a standard font, text in an embedded
// TrueType font (subset), and JPEG images; prints the median time of
// several runs and the size of the file each makes.
//
// Usage (from benchmark/compare): dart compile exe bin/compare.dart -o
// compare && ./compare
import 'dart:io';
import 'dart:typed_data';

import 'package:libpdf/libpdf.dart' as lib;
import 'package:pdf/pdf.dart' as pdf;

const pages = 50;
const linesPerPage = 45;
const sentence =
    'The quick brown fox jumps over the lazy dog, again and again.';

final Uint8List serif = File('../../test/fonts/notoserif-regular-latin.ttf')
    .readAsBytesSync();
final Uint8List jpeg = File('../../test/images/jpeg/rgb-baseline.jpg')
    .readAsBytesSync();

Uint8List libpdfText({required bool embedded}) {
  final document = lib.PdfDocument();
  final font = embedded
      ? lib.EmbeddedFont.parse(serif)
      : lib.StandardFont.helvetica;
  final style = lib.PdfTextStyle(font, 11);
  for (var p = 0; p < pages; p++) {
    final canvas = document.addPage(const lib.PdfRect(0, 0, 595, 842)).canvas;
    for (var l = 0; l < linesPerPage; l++) {
      canvas.text('$p.$l $sentence', 50, 800 - l * 16.0, style);
    }
  }
  return document.save();
}

Future<Uint8List> pdfText({required bool embedded}) async {
  final document = pdf.PdfDocument();
  final font = embedded
      ? pdf.PdfTtfFont(document, ByteData.sublistView(serif))
      : pdf.PdfFont.helvetica(document);
  for (var p = 0; p < pages; p++) {
    final graphics = pdf.PdfPage(
      document,
      pageFormat: pdf.PdfPageFormat.a4,
    ).getGraphics();
    for (var l = 0; l < linesPerPage; l++) {
      graphics.drawString(font, 11, '$p.$l $sentence', 50, 800 - l * 16.0);
    }
  }
  return document.save();
}

Uint8List libpdfImages() {
  final document = lib.PdfDocument();
  for (var p = 0; p < pages; p++) {
    final image = lib.PdfImage.parse(jpeg);
    document
        .addPage(const lib.PdfRect(0, 0, 595, 842))
        .canvas
        .image(image, const lib.PdfRect(50, 400, 400, 300));
  }
  return document.save();
}

Future<Uint8List> pdfImages() async {
  final document = pdf.PdfDocument();
  for (var p = 0; p < pages; p++) {
    final image = pdf.PdfImage.jpeg(document, image: jpeg);
    pdf.PdfPage(
      document,
      pageFormat: pdf.PdfPageFormat.a4,
    ).getGraphics().drawImage(image, 50, 400, 400, 300);
  }
  return document.save();
}

Future<(double, int)> time(Future<Uint8List> Function() make) async {
  for (var i = 0; i < 3; i++) {
    await make();
  }
  final times = <double>[];
  var size = 0;
  for (var i = 0; i < 11; i++) {
    final watch = Stopwatch()..start();
    size = (await make()).length;
    times.add(watch.elapsedMicroseconds / 1000);
  }
  times.sort();
  return (times[times.length ~/ 2], size);
}

Future<void> main() async {
  final workloads =
      <String, (Future<Uint8List> Function(), Future<Uint8List> Function())>{
        'standard font text, $pages pages': (
          () async => libpdfText(embedded: false),
          () => pdfText(embedded: false),
        ),
        'TrueType text (subset), $pages pages': (
          () async => libpdfText(embedded: true),
          () => pdfText(embedded: true),
        ),
        'JPEG images, $pages pages': (() async => libpdfImages(), pdfImages),
      };
  stdout.writeln(
    '| Document | libpdf | package:pdf | libpdf size | package:pdf size |',
  );
  stdout.writeln('| --- | --: | --: | --: | --: |');
  for (final MapEntry(key: name, value: (a, b)) in workloads.entries) {
    final (ta, sa) = await time(a);
    final (tb, sb) = await time(b);
    stdout.writeln(
      '| $name | ${ta.toStringAsFixed(1)} ms | ${tb.toStringAsFixed(1)} ms '
      '| ${(sa / 1024).toStringAsFixed(0)} KB | ${(sb / 1024).toStringAsFixed(0)} KB |',
    );
  }
}

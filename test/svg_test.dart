import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:libpdf/libpdf.dart';
import 'package:test/test.dart';

bool _has(String tool) => Process.runSync('which', [tool]).exitCode == 0;

final bool _tools = ['rsvg-convert', 'pdftoppm', 'qpdf'].every(_has);

/// [svg] drawn on a page of its size.
Uint8List svgPdf(SvgImage svg) {
  final document = PdfDocument();
  final page = document.addPage(PdfRect(0, 0, svg.width, svg.height));
  svg.draw(page.canvas, PdfRect(0, 0, svg.width, svg.height));
  return document.save();
}

/// The gray samples of the first page of [pdf], at 72 dpi.
(int, int, Uint8List) raster(String pdf) {
  final out = '$pdf-r';
  final result = Process.runSync('pdftoppm', [
    '-r',
    '72',
    '-singlefile',
    pdf,
    out,
  ]);
  expect(result.exitCode, 0, reason: '${result.stderr}');
  final bytes = File('$out.ppm').readAsBytesSync();
  final header = latin1.decode(bytes.sublist(0, 20)).split(RegExp(r'\s+'));
  final width = int.parse(header[1]);
  final height = int.parse(header[2]);
  return (
    width,
    height,
    Uint8List.sublistView(bytes, bytes.length - width * height * 3),
  );
}

void main() {
  late Directory dir;
  setUpAll(() => dir = Directory.systemTemp.createTempSync('libpdf.'));
  tearDownAll(() => dir.deleteSync(recursive: true));

  group(
    'renders as librsvg does',
    skip: _tools ? false : 'needs rsvg-convert, poppler and qpdf',
    () {
      final fixtures =
          Directory('test/svg')
              .listSync()
              .whereType<File>()
              .where((f) => f.path.endsWith('.svg'))
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path));
      for (final file in fixtures) {
        final name = file.uri.pathSegments.last;
        test(name, () {
          final svg = SvgImage.parse(file.readAsStringSync());
          final ours = File('${dir.path}/$name.ours.pdf')
            ..writeAsBytesSync(svgPdf(svg));
          final check = Process.runSync('qpdf', ['--check', ours.path]);
          expect(check.exitCode, 0, reason: '${check.stdout}');
          final theirs = '${dir.path}/$name.rsvg.pdf';
          final convert = Process.runSync('rsvg-convert', [
            '-f',
            'pdf',
            '-o',
            theirs,
            file.path,
          ]);
          expect(convert.exitCode, 0, reason: '${convert.stderr}');
          final (w, h, a) = raster(ours.path);
          final (w2, h2, b) = raster(theirs);
          expect((w, h), (w2, h2), reason: 'page size');
          var sum = 0;
          var far = 0;
          for (var i = 0; i < a.length; i++) {
            final d = (a[i] - b[i]).abs();
            sum += d;
            if (d > 64) far++;
          }
          final mean = sum / a.length;
          final farShare = far / a.length;
          expect(mean, lessThan(2.5), reason: 'mean difference');
          expect(farShare, lessThan(0.01), reason: 'pixels far apart');
          expect(svg.warnings, switch (name) {
            'css.svg' => ['CSS rule not supported: @media'],
            _ => isEmpty,
          });
        }, tags: ['pdf-tools']);
      }
    },
  );

  test('text: fonts, anchors and baselines', () {
    final svg = SvgImage.parse('''
<svg xmlns="http://www.w3.org/2000/svg" width="300" height="100">
  <text x="10" y="30" font-family="Helvetica" font-size="20">Start</text>
  <text x="150" y="30" font-family="Arial, sans-serif" font-size="20"
        text-anchor="middle" font-weight="bold">Mid<tspan fill="red">dle</tspan></text>
  <text x="290" y="30" font-size="20" text-anchor="end" font-family="monospace">End</text>
  <text x="10" y="70" font-family="serif" font-size="16"><tspan dy="10">Down</tspan></text>
</svg>''');
    expect(svg.warnings, isEmpty);
    final pdf = File('${dir.path}/text.pdf')..writeAsBytesSync(svgPdf(svg));
    // Positions through poppler, where the pdf-tools job installs it.
    if (!_tools || !_has('pdftotext')) return;
    final html =
        Process.runSync('pdftotext', ['-bbox', pdf.path, '-']).stdout as String;
    final words = {
      for (final m in RegExp(
        r'<word xMin="([\d.]+)" yMin="([\d.]+)" xMax="([\d.]+)" yMax="([\d.]+)">([^<]*)</word>',
      ).allMatches(html))
        m[5]!: (
          double.parse(m[1]!),
          double.parse(m[2]!),
          double.parse(m[3]!),
          double.parse(m[4]!),
        ),
    };
    const px = 0.75;
    final helvetica = PdfTextStyle(StandardFont.helvetica, 20 * px);
    expect(words['Start']!.$1, closeTo(10 * px, 0.5));
    expect(
      words['Start']!.$3,
      closeTo((10 + helvetica.measure('Start') / px) * px, 0.5),
    );
    // "Mid" and the red "dle": one word, or two where the color changes.
    final left = (words['Middle'] ?? words['Mid']!).$1;
    final right = (words['Middle'] ?? words['dle']!).$3;
    expect((left + right) / 2, closeTo(150 * px, 0.6));
    expect(words['End']!.$3, closeTo(290 * px, 0.6));
    expect(words['Down']!.$2, greaterThan(words['Start']!.$2 + 30));
  });

  test('unsupported features are reported, not fatal', () {
    final svg = SvgImage.parse('''
<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">
  <defs><mask id="m"/><filter id="f"/><marker id="k"/></defs>
  <rect width="5" height="5" mask="url(#m)" filter="url(#f)"/>
  <path d="M0 0 L5 5" marker-end="url(#k)" stroke="black"/>
  <foreignObject/>
  <rect width="5" height="5" fill="url(#nothing)"/>
</svg>''');
    svgPdf(svg);
    expect(svg.warnings, [
      'masks are not supported; the element is drawn unmasked',
      'filters are not supported; the element is drawn unfiltered',
      'markers are not drawn',
      '<foreignObject> is not supported',
      'paint server #nothing not found',
    ]);
  });

  test('sizes, units and parse errors', () {
    final svg = SvgImage.parse(
      '<svg xmlns="http://www.w3.org/2000/svg" width="2in" height="10mm"/>',
    );
    expect(svg.width, closeTo(144, 1e-9));
    expect(svg.height, closeTo(10 / 25.4 * 72, 1e-9));
    final boxed = SvgImage.parse(
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 40 20"/>',
    );
    expect((boxed.width, boxed.height), (30, 15));
    expect(svg.rootAttribute('width'), '2in');
    expect(boxed.rootAttribute('viewBox'), '0 0 40 20');
    expect(boxed.rootAttribute('width'), isNull);
    expect(() => SvgImage.parse('<html/>'), throwsFormatException);
    expect(() => SvgImage.parse('<svg'), throwsFormatException);
  });

  test('path data: every command, implicit separators, arcs', () {
    final path = SvgPath.parse(
      'M1.5.5l2-3H10V20c1 1 2 2 3 3s1 1 2 2 '
      'q1 1 2 2t3 3a5 5 0 1010 0z',
    );
    expect(path.segments.whereType<MoveSegment>().single.x, 1.5);
    expect(path.segments.whereType<MoveSegment>().single.y, 0.5);
    expect(path.segments.last, isA<CloseSegment>());
    expect(path.segments.whereType<CubicSegment>().length, greaterThan(4));
    // Errors keep what came before.
    expect(SvgPath.parse('M0 0 L10 10 L oops').segments.length, 2);
  });

  test('an SVG is placed by the layout like any image', () {
    final svg = SvgImage.parse(File('test/svg/shapes.svg').readAsStringSync());
    final result = FlowLayout(
      template: const PageTemplate(PdfRect(0, 0, 300, 300)),
    ).layout([ImageBox(svg, svg.width, svg.height, align: BoxAlign.center)]);
    final document = PdfDocument();
    result.render(document);
    final bytes = document.save();
    expect(latin1.decode(bytes), isNot(contains('/Subtype /Image')));
    expect(result.pageCount, 1);
  });
}

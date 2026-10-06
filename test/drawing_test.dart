@Tags(['pdf-tools'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:libpdf/libpdf.dart';
import 'package:test/test.dart';

bool _has(String tool) => Process.runSync('which', [tool]).exitCode == 0;

final bool _tools = [
  'qpdf',
  'pdftoppm',
  'pdftotext',
  'pdfinfo',
  'pdftohtml',
].every(_has);

late Directory _dir;

/// [document] saved and checked by qpdf; returns the file.
File saved(PdfDocument document, {PdfWriterOptions? options}) {
  final file = File('${_dir.path}/t${_count++}.pdf')
    ..writeAsBytesSync(
      document.save(
        options: options ?? const PdfWriterOptions(deterministic: true),
      ),
    );
  final check = Process.runSync('qpdf', ['--check', file.path]);
  expect(check.exitCode, 0, reason: '${check.stdout}${check.stderr}');
  expect('${check.stdout}', contains('No syntax or stream encoding errors'));
  return file;
}

int _count = 0;

/// A page rendered by poppler at 72 dpi: a pixel per point.
final class Rendered {
  new(this.width, this.height, this.samples);

  final int width;
  final int height;
  final Uint8List samples;

  /// The color around the point (x, y) of the page (y up), as RGB.
  (int, int, int) at(double x, double y) {
    final column = x.floor();
    final row = height - 1 - y.floor();
    final i = (row * width + column) * 3;
    return (samples[i], samples[i + 1], samples[i + 2]);
  }
}

Rendered render(File pdf, {int page = 1}) {
  final out = '${pdf.path}-$page';
  final result = Process.runSync('pdftoppm', [
    '-r',
    '72',
    '-f',
    '$page',
    '-l',
    '$page',
    '-singlefile',
    pdf.path,
    out,
  ]);
  expect(result.exitCode, 0, reason: '${result.stderr}');
  final bytes = File('$out.ppm').readAsBytesSync();
  // P6\n<w> <h>\n255\n
  final header = latin1.decode(bytes.sublist(0, 20)).split(RegExp(r'\s+'));
  final width = int.parse(header[1]);
  final height = int.parse(header[2]);
  final start = bytes.length - width * height * 3;
  return Rendered(width, height, Uint8List.sublistView(bytes, start));
}

Matcher near((int, int, int) color, [int tolerance = 8]) =>
    predicate<(int, int, int)>(
      (c) =>
          (c.$1 - color.$1).abs() <= tolerance &&
          (c.$2 - color.$2).abs() <= tolerance &&
          (c.$3 - color.$3).abs() <= tolerance,
      'within $tolerance of $color',
    );

const white = (255, 255, 255);
const black = (0, 0, 0);
const red = (255, 0, 0);

/// A document with one page of [width] by [height], drawn by [draw].
PdfDocument page(
  void Function(PdfCanvas canvas) draw, {
  double width = 100,
  double height = 100,
}) {
  final document = PdfDocument();
  draw(document.addPage(PdfRect(0, 0, width, height)).canvas);
  return document;
}

/// The words pdftotext finds, with their boxes (y down from the top).
List<({String text, double xMin, double yMin, double xMax, double yMax})> words(
  File pdf,
) {
  final result = Process.runSync('pdftotext', [
    '-bbox',
    '-enc',
    'UTF-8',
    pdf.path,
    '-',
  ]);
  final word = RegExp(
    r'<word xMin="([\d.]+)" yMin="([\d.]+)" xMax="([\d.]+)" yMax="([\d.]+)">'
    '([^<]*)</word>',
  );
  return [
    for (final m in word.allMatches('${result.stdout}'))
      (
        text: m[5]!,
        xMin: double.parse(m[1]!),
        yMin: double.parse(m[2]!),
        xMax: double.parse(m[3]!),
        yMax: double.parse(m[4]!),
      ),
  ];
}

String run(String tool, List<String> args, {Encoding encoding = latin1}) {
  final result = Process.runSync(tool, args, stdoutEncoding: encoding);
  expect(result.exitCode, 0, reason: '$tool: ${result.stderr}');
  return '${result.stdout}';
}

void main() {
  setUpAll(() => _dir = Directory.systemTemp.createTempSync('libpdf.'));
  tearDownAll(() => _dir.deleteSync(recursive: true));
  if (!_tools) {
    test('drawing', () {}, skip: 'needs qpdf and poppler');
    return;
  }

  test('paths are filled and stroked', () {
    final pdf = saved(
      page((c) {
        c
          ..setFillColor(const PdfColor.rgb(1, 0, 0))
          ..rect(const PdfRect(10, 10, 30, 30))
          ..fill()
          ..setFillColor(const PdfColor.rgb(0, 0.5, 0))
          ..circle(70, 70, 15)
          ..fill()
          ..setStrokeColor(const PdfColor.rgb(0, 0, 1))
          ..setLineWidth(4)
          ..moveTo(10, 90)
          ..lineTo(40, 90)
          ..stroke();
      }),
    );
    final image = render(pdf);
    expect(image.at(25, 25), near(red));
    expect(image.at(5, 5), near(white));
    expect(image.at(70, 70), near((0, 128, 0)));
    expect(image.at(57, 57), near(white), reason: 'outside the circle');
    expect(image.at(25, 90), near((0, 0, 255)));
    expect(image.at(25, 95), near(white));
  });

  test('rounded rectangles, ellipses and the even-odd rule', () {
    final pdf = saved(
      page((c) {
        c
          ..roundedRect(const PdfRect(10, 10, 80, 80), 20)
          ..rect(const PdfRect(40, 40, 20, 20))
          ..fill(evenOdd: true);
      }),
    );
    final image = render(pdf);
    expect(image.at(30, 30), near(black));
    expect(image.at(50, 50), near(white), reason: 'the hole');
    expect(image.at(12, 12), near(white), reason: 'the rounded corner');
  });

  test('transforms and save/restore', () {
    final pdf = saved(
      page((c) {
        c
          ..saved(() {
            c
              ..translate(50, 0)
              ..rotate(90)
              ..rect(const PdfRect(0, 0, 20, 10))
              ..fill();
          })
          ..rect(const PdfRect(80, 80, 10, 10))
          ..fill();
      }),
    );
    final image = render(pdf);
    expect(image.at(45, 10), near(black), reason: 'rotated about the origin');
    expect(image.at(55, 10), near(white));
    expect(image.at(85, 85), near(black), reason: 'untransformed again');
  });

  test('clipping', () {
    final pdf = saved(
      page((c) {
        c
          ..rect(const PdfRect(0, 0, 50, 100))
          ..clip()
          ..rect(const PdfRect(0, 0, 100, 100))
          ..fill();
      }),
    );
    final image = render(pdf);
    expect(image.at(25, 50), near(black));
    expect(image.at(75, 50), near(white));
  });

  test('gray, CMYK and spot colors', () {
    final pdf = saved(
      page((c) {
        for (final (i, color) in [
          const PdfColor.gray(0.5),
          const PdfColor.cmyk(0, 1, 1, 0),
          const SpotColor('Brand Red', CmykColor(0, 1, 1, 0)),
          const SpotColor('Brand Red', CmykColor(0, 1, 1, 0), 0.5),
          PdfColor.hex('#00f'),
        ].indexed) {
          c
            ..setFillColor(color)
            ..rect(PdfRect(i * 20.0, 0, 20, 100))
            ..fill();
        }
      }),
    );
    final image = render(pdf);
    expect(image.at(10, 50), near((128, 128, 128), 2));
    final (r, g, b) = image.at(30, 50);
    expect((r > 200, g < 80, b < 80), (true, true, true), reason: 'CMYK red');
    expect(image.at(50, 50), near(image.at(30, 50), 4), reason: 'spot');
    final (r2, g2, _) = image.at(70, 50);
    expect((r2 > 200, g2 > 100), (true, true), reason: 'half tint');
    expect(image.at(90, 50), near((0, 0, 255)));
    final pages = run('qpdf', [
      '--qdf',
      '--object-streams=disable',
      pdf.path,
      '-',
    ]);
    expect(
      pages,
      contains(RegExp(r'/Separation\s+/Brand#20Red\s+/DeviceCMYK')),
    );
  });

  test('dashes, caps and joins', () {
    final pdf = saved(
      page((c) {
        c
          ..setLineWidth(10)
          ..setLineCap(LineCap.butt)
          ..setLineJoin(LineJoin.round)
          ..setMiterLimit(4)
          ..dash([10, 10])
          ..moveTo(0, 50)
          ..lineTo(100, 50)
          ..stroke();
      }),
    );
    final image = render(pdf);
    expect(image.at(5, 50), near(black));
    expect(image.at(15, 50), near(white));
    expect(image.at(25, 50), near(black));
  });

  test('opacity, blend modes and soft masks', () {
    final mask = PdfForm(
      const PdfRect(0, 0, 100, 100),
      (c) => c
        ..setFillColor(const PdfColor.gray(1))
        ..rect(const PdfRect(0, 0, 50, 100))
        ..fill(),
      group: const TransparencyGroup(),
    );
    final pdf = saved(
      page((c) {
        c
          ..saved(() {
            c
              ..opacity(fill: 0.5)
              ..rect(const PdfRect(0, 0, 100, 20))
              ..fill();
          })
          ..setFillColor(const PdfColor.rgb(0, 0, 1))
          ..rect(const PdfRect(0, 20, 100, 20))
          ..fill()
          ..saved(() {
            c
              ..setBlendMode(BlendMode.multiply)
              ..setFillColor(const PdfColor.rgb(1, 0, 0))
              ..rect(const PdfRect(0, 20, 100, 20))
              ..fill();
          })
          ..saved(() {
            c
              ..softMask(mask)
              ..setFillColor(const PdfColor.rgb(1, 0, 0))
              ..rect(const PdfRect(0, 60, 100, 40))
              ..fill()
              ..clearSoftMask();
          });
      }),
    );
    final image = render(pdf);
    expect(image.at(50, 10), near((128, 128, 128), 3), reason: 'half opaque');
    expect(image.at(50, 30), near(black), reason: 'red multiplied by blue');
    expect(image.at(25, 80), near(red), reason: 'under the white of the mask');
    expect(image.at(75, 80), near(white), reason: 'under its black');
    expect(
      run('qpdf', ['--qdf', '--object-streams=disable', pdf.path, '-']),
      contains('/S /Transparency'),
      reason: 'a page with transparency is a transparency group',
    );
  });

  test('a soft mask needs a group', () {
    final form = PdfForm(const PdfRect(0, 0, 1, 1), (_) {});
    expect(() => page((c) => c.softMask(form)), throwsArgumentError);
  });

  test('forms are drawn once and painted where they are used', () {
    final star = PdfForm(
      const PdfRect(0, 0, 20, 20),
      (c) => c
        ..rect(const PdfRect(0, 0, 20, 20))
        ..fill(),
    );
    final document = PdfDocument();
    for (var i = 0; i < 2; i++) {
      document.addPage(const PdfRect(0, 0, 100, 100)).canvas.saved(() {
        document.pages[i].canvas
          ..translate(40, 40)
          ..form(star);
      });
    }
    final pdf = saved(document);
    for (final p in [1, 2]) {
      final image = render(pdf, page: p);
      expect(image.at(50, 50), near(black));
      expect(image.at(30, 30), near(white));
    }
    final qdf = run('qpdf', [
      '--qdf',
      '--object-streams=disable',
      pdf.path,
      '-',
    ]);
    expect(RegExp('/Subtype /Form').allMatches(qdf).length, 1);
  });

  test('images are placed into a rectangle', () {
    final png = PdfImage.parse(
      File('test/images/pngsuite/basn2c08.png').readAsBytesSync(),
    );
    final pdf = saved(page((c) => c.image(png, const PdfRect(10, 10, 64, 64))));
    final image = render(pdf);
    expect(image.at(5, 5), near(white));
    expect(image.at(40, 40), isNot(near(white)));
  });

  test('text is placed at its position, with its measured width', () {
    final serif = EmbeddedFont.parse(
      File('test/fonts/notoserif-regular-latin.ttf').readAsBytesSync(),
    );
    final helvetica = PdfTextStyle(StandardFont.helvetica, 12);
    final spaced = PdfTextStyle(
      serif,
      12,
      wordSpacing: 20,
      characterSpacing: 1,
    );
    late double helloWidth;
    late double spacedWidth;
    final pdf = saved(
      page(width: 300, (c) {
        helloWidth = c.text('Hello World', 10, 70, helvetica);
        spacedWidth = c.text('AVA Wave', 10, 30, spaced);
      }),
    );
    final found = words(pdf);
    expect(found.map((w) => w.text), ['Hello', 'World', 'AVA', 'Wave']);
    final [hello, world, ava, wave] = found;
    expect(hello.xMin, closeTo(10, 0.5));
    expect(world.xMax, closeTo(10 + helloWidth, 0.5));
    expect(world.xMin, closeTo(10 + helvetica.measure('Hello '), 0.5));
    expect(hello.yMax, closeTo(100 - 70 + 12 * 0.2, 2.5));
    expect(ava.xMin, closeTo(10, 0.5));
    expect(
      wave.xMin,
      closeTo(10 + spaced.measure('AVA '), 0.5),
      reason: "word spacing applies to the embedded font's space",
    );
    expect(wave.xMax, closeTo(10 + spacedWidth - 1, 0.6));
    expect(
      spaced.measure('AVA Wave'),
      greaterThan(PdfTextStyle(serif, 12).measure('AVA Wave') + 20 + 7),
    );
  });

  test('kerning is applied as the measure says', () {
    final kerned = PdfTextStyle(StandardFont.helvetica, 40);
    final unkerned = PdfTextStyle(StandardFont.helvetica, 40, kerning: false);
    expect(
      kerned.measure('AV'),
      lessThan(kerned.font.widthOf('AV', 40, kerning: false)),
    );
    final pdf = saved(
      page(width: 300, (c) {
        c
          ..text('AV', 10, 50, kerned)
          ..text('AV', 150, 50, unkerned);
      }),
    );
    final [kernedWord, unkernedWord] = words(pdf);
    expect(
      kernedWord.xMax - kernedWord.xMin,
      closeTo(kerned.measure('AV'), 0.5),
    );
    expect(
      unkernedWord.xMax - unkernedWord.xMin,
      closeTo(unkerned.measure('AV'), 0.5),
    );
  });

  test('rise, scaling and render modes', () {
    final style = PdfTextStyle(StandardFont.helvetica, 20);
    final pdf = saved(
      page(width: 300, (c) {
        c
          ..text('base', 10, 50, style)
          ..text(
            'up',
            100,
            50,
            PdfTextStyle(StandardFont.helvetica, 20, rise: 10),
          )
          ..text(
            'wide',
            150,
            50,
            PdfTextStyle(StandardFont.helvetica, 20, horizontalScaling: 200),
          )
          ..text(
            'hidden',
            10,
            10,
            PdfTextStyle(
              StandardFont.helvetica,
              20,
              renderMode: TextRenderMode.invisible,
            ),
          );
      }),
    );
    final found = {for (final w in words(pdf)) w.text: w};
    expect(found['up']!.yMax, closeTo(found['base']!.yMax - 10, 1));
    expect(
      found['wide']!.xMax - found['wide']!.xMin,
      closeTo(2 * style.measure('wide'), 1),
    );
    expect(found, contains('hidden'), reason: 'invisible text is still text');
    final image = render(pdf);
    for (var x = 10; x < 60; x += 2) {
      expect(image.at(x.toDouble(), 15), near(white));
    }
  });

  test('the open action and the page modes', () {
    final document = PdfDocument(
      pageMode: PageMode.fullScreen,
      nonFullScreenPageMode: PageMode.useOutlines,
    );
    final page = document.addPage(const PdfRect(0, 0, 200, 200));
    document.openAction = PdfDestination.fitHeight(page, left: 0);
    final pdf = saved(document);
    final qdf = run('qpdf', [
      '--qdf',
      '--object-streams=disable',
      pdf.path,
      '-',
    ]);
    expect(qdf, contains('/PageMode /FullScreen'));
    expect(qdf, contains('/NonFullScreenPageMode /UseOutlines'));
    expect(qdf, matches(RegExp(r'/OpenAction \[\s*\d+ 0 R\s*/FitV\s*0\s*\]')));
  });

  test('links, named destinations and outlines', () {
    final document = PdfDocument(
      info: const PdfInfo(title: 'Links'),
      pageMode: PageMode.useOutlines,
      displayTitle: true,
      language: 'en-US',
    );
    final first = document.addPage(const PdfRect(0, 0, 200, 200));
    final second = document.addPage(const PdfRect(0, 0, 200, 200));
    document
      ..addDestination('chapter-2', PdfDestination.xyz(second, top: 200))
      ..addDestination('ünïcode', PdfDestination.fit(second));
    final style = PdfTextStyle(StandardFont.helvetica, 12);
    for (final y in [15.0, 45.0, 75.0]) {
      first.canvas.text('link', 15, y, style);
    }
    first
      ..link(
        const PdfRect(10, 10, 50, 20),
        const LinkTarget.uri('https://example.org/ä b'),
      )
      ..link(const PdfRect(10, 40, 50, 20), const LinkTarget.named('chapter-2'))
      ..link(
        const PdfRect(10, 70, 50, 20),
        LinkTarget.destination(PdfDestination.fitWidth(second, top: 100)),
      );
    document
        .addOutline(
          'Chapter 1',
          LinkTarget.destination(PdfDestination.fit(first)),
          open: true,
          bold: true,
        )
        .add('Section «1.1»', const LinkTarget.named('chapter-2'));
    document.addOutline('Chapter 2', const LinkTarget.named('chapter-2'));
    final pdf = saved(document);

    final dests = run('pdfinfo', ['-dests', pdf.path]);
    expect(dests, contains('chapter-2'));
    // Name tree keys are byte strings, which poppler shows as
    // PDFDocEncoding: only the ASCII end of this one is compared.
    expect(dests, contains(RegExp(r'2 \[ Fit\s+\] ".*code"')));
    final info = run('pdfinfo', [pdf.path]);
    expect(info, matches(RegExp(r'Title:\s+Links')));
    final xml = run('pdftohtml', [
      '-xml',
      '-i',
      '-stdout',
      '-q',
      pdf.path,
    ], encoding: utf8);
    expect(xml, contains('href="https://example.org/%C3%A4 b"'));
    expect(xml, contains('<item page="1">Chapter 1</item>'));
    expect(xml, contains('<item page="2">Section «1.1»</item>'));
    expect(xml, contains('<item page="2">Chapter 2</item>'));
    final qdf = run('qpdf', [
      '--qdf',
      '--object-streams=disable',
      pdf.path,
      '-',
    ]);
    expect(qdf, contains('/PageMode /UseOutlines'));
    expect(qdf, contains('/DisplayDocTitle true'));
    expect(qdf, contains('/F 2'), reason: 'bold outline item');
    expect(qdf, contains('/Count 3'), reason: 'open root and chapter');
  });

  test('page boxes, rotation and labels', () {
    final document = PdfDocument();
    for (var i = 0; i < 5; i++) {
      document.addPage(
        const PdfRect(0, 0, 612, 792),
        cropBox: const PdfRect(9, 9, 594, 774),
        bleedBox: const PdfRect(9, 9, 594, 774),
        trimBox: const PdfRect(18, 18, 576, 756),
        artBox: const PdfRect(36, 36, 540, 720),
        rotation: i == 4 ? 90 : 0,
      );
    }
    document
      ..labelPages(0, const PageLabel(style: PageNumberStyle.lowerRoman))
      ..labelPages(2, const PageLabel())
      ..labelPages(
        4,
        const PageLabel(style: PageNumberStyle.upperLetters, prefix: 'App-'),
      );
    final pdf = saved(document);
    final boxes = run('pdfinfo', ['-box', '-f', '1', '-l', '5', pdf.path]);
    expect(
      boxes,
      matches(
        RegExp(r'Page\s+1 TrimBox:\s+18\.00\s+18\.00\s+594\.00\s+774\.00'),
      ),
    );
    expect(
      boxes,
      matches(
        RegExp(r'Page\s+1 ArtBox:\s+36\.00\s+36\.00\s+576\.00\s+756\.00'),
      ),
    );
    expect(boxes, matches(RegExp(r'Page\s+5 rot:\s+90')));
    final json = run('qpdf', ['--json', '--json-key=pages', pdf.path]);
    expect(
      RegExp(r'"label": \{[^}]*\}')
          .allMatches(json)
          .map((m) => m[0]!.replaceAll(RegExp(r'\s+'), ' '))
          .toList(),
      [
        // Each page's label, as qpdf works it out.
        '"label": { "/S": "/r", "/St": 1 }',
        '"label": { "/S": "/r", "/St": 2 }',
        '"label": { "/S": "/D", "/St": 1 }',
        '"label": { "/S": "/D", "/St": 2 }',
        '"label": { "/P": "u:App-", "/S": "/A", "/St": 1 }',
      ],
    );
  });

  test('a page left inside a path or save is reported', () {
    final open = PdfDocument();
    open.addPage(const PdfRect(0, 0, 10, 10)).canvas.save();
    expect(open.save, throwsStateError);
    final path = PdfDocument();
    path.addPage(const PdfRect(0, 0, 10, 10)).canvas.moveTo(0, 0);
    expect(path.save, throwsStateError);
    final canvas = PdfDocument().addPage(const PdfRect(0, 0, 10, 10)).canvas;
    expect(() => canvas.lineTo(1, 1), throwsStateError);
    expect(canvas.restore, throwsStateError);
  });

  test('output is the same bytes for the same document', () {
    Uint8List make() {
      final document = PdfDocument(info: const PdfInfo(title: 'Same'));
      document
          .addPage(const PdfRect(0, 0, 100, 100))
          .canvas
          .text('same', 10, 10, PdfTextStyle(StandardFont.courier, 10));
      return document.save(
        options: const PdfWriterOptions(deterministic: true),
      );
    }

    expect(make(), make());
  });
}

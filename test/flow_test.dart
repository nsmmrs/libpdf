import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:libpdf/libpdf.dart';
import 'package:test/test.dart';

final PdfTextStyle body = PdfTextStyle(StandardFont.helvetica, 10);
final PdfTextStyle heading = PdfTextStyle(
  StandardFont.named('Helvetica-Bold'),
  14,
);

/// The height of a line of [body] text.
final double lineHeight =
    (StandardFont.helvetica.ascender - StandardFont.helvetica.descender) / 100;

ParagraphBox para(String text, {int orphans = 2, int widows = 2}) =>
    ParagraphBox(
      Paragraph([TextRun(text, body)]),
      orphans: orphans,
      widows: widows,
    );

/// Text of [count] lines, each one word (so each is a line at any width).
String lines(int count, [String prefix = 'line']) =>
    [for (var i = 1; i <= count; i++) '$prefix$i'].join('\n');

/// A template whose region holds [rows] lines of body text.
PageTemplate rowsTemplate(
  double rows, {
  int columns = 1,
  List<LayoutBox> Function(PageInfo page)? header,
  List<LayoutBox> Function(PageInfo page)? footer,
}) => PageTemplate(
  PdfRect(0, 0, 300, 40 + rows * lineHeight),
  margins: const EdgeInsets.all(20),
  columns: columns,
  header: header,
  footer: footer,
);

bool _has(String tool) => Process.runSync('which', [tool]).exitCode == 0;

final bool _tools = ['pdftotext', 'pdfinfo', 'pdftoppm'].every(_has);

late Directory _dir;
var _count = 0;

/// The document saved to a file.
File save(PdfDocument document) => File('${_dir.path}/f${_count++}.pdf')
  ..writeAsBytesSync(
    document.save(options: const PdfWriterOptions(deterministic: true)),
  );

/// The text lines of each page.
List<List<String>> pageTexts(File pdf, int pages) => [
  for (var p = 1; p <= pages; p++)
    [
      for (final line
          in (Process.runSync('pdftotext', [
                    '-f',
                    '$p',
                    '-l',
                    '$p',
                    '-layout',
                    pdf.path,
                    '-',
                  ]).stdout
                  as String)
              .split('\n'))
        if (line.trim().isNotEmpty)
          line.trim().replaceAll(RegExp(' {2,}'), ' '),
    ],
];

/// [boxes] laid out with [template], rendered; returns the file and the
/// result.
(File, LayoutResult) render(
  List<LayoutBox> boxes,
  PageTemplate template, {
  String Function(int)? pageLabel,
}) {
  final result = FlowLayout(
    template: template,
    pageLabel: pageLabel,
  ).layout(boxes);
  final document = PdfDocument();
  result.render(document);
  return (save(document), result);
}

void main() {
  setUpAll(() => _dir = Directory.systemTemp.createTempSync('libpdf.'));
  tearDownAll(() => _dir.deleteSync(recursive: true));

  group('the default page breaker', () {
    const breaker = DefaultPageBreaker();
    final heights = List<double>.filled(6, 10);
    int fit(
      double available, {
      int orphans = 2,
      int widows = 2,
      bool atTop = false,
    }) => breaker.linesThatFit(
      heights,
      available,
      orphans: orphans,
      widows: widows,
      atTop: atTop,
    );

    test('as many lines as fit', () {
      expect(fit(100), 6);
      expect(fit(30), 3);
    });

    test('orphans move the paragraph, widows pull lines over', () {
      expect(fit(10), 0, reason: 'one line alone is an orphan');
      expect(fit(10, orphans: 1), 1);
      expect(fit(50), 4, reason: 'two lines left over: fine');
      expect(fit(55, widows: 3), 3, reason: 'leaves three for the next');
    });

    test('at the top of a region, at least one line', () {
      expect(fit(5, atTop: true), 1);
      expect(fit(10, atTop: true), 1);
    });

    test('kept boxes move when they fit a whole region', () {
      expect(breaker.moveKeptBox(50, 40, 100), isTrue);
      expect(breaker.moveKeptBox(150, 40, 100), isFalse);
      expect(breaker.moveKeptBox(30, 40, 100), isFalse);
    });
  });

  test('custom content lays itself out and splits across regions', () {
    // Lines of 10 points; a piece starting fresh adds a gap of 3 above.
    final result =
        FlowLayout(
          template: const PageTemplate(
            PdfRect(0, 0, 100, 100),
            margins: EdgeInsets.all(10),
          ),
        ).layout([
          const CustomBox(_Lines(20, 0), style: BoxStyle(anchor: 'start')),
        ]);
    // 80 points a region: 7 lines after the gap, so 7 + 7 + 6.
    expect(result.pageCount, 3);
    expect(result.anchors['start']!.page, 0);
    expect(result.anchors['line-19']!.page, 2);
    expect(result.anchors['line-7']!.page, 1);
  });

  test('decorations see each piece of a block', () {
    final pieces = <(double, bool, bool)>[];
    FlowLayout(template: rowsTemplate(4))
        .layout([
          BlockBox(
            [para(lines(6))],
            style: BoxStyle(
              decoration: (page, rect, {required first, required last}) =>
                  pieces.add((rect.height, first, last)),
            ),
          ),
        ])
        .render(PdfDocument());
    // Four lines, then two (widows keep two together).
    expect(pieces.map((p) => (p.$2, p.$3)), [(true, false), (false, true)]);
  });

  group('rendered', skip: _tools ? false : 'needs poppler', () {
    test('a paragraph splits across pages, keeping its lines in order', () {
      final (pdf, result) = render([para(lines(10))], rowsTemplate(4));
      expect(result.pageCount, 3);
      expect(pageTexts(pdf, 3), [
        ['line1', 'line2', 'line3', 'line4'],
        ['line5', 'line6', 'line7', 'line8'],
        ['line9', 'line10'],
      ]);
    });

    test('widows pull a line over; orphans move a paragraph', () {
      final (widowed, _) = render([para(lines(5))], rowsTemplate(4));
      expect(pageTexts(widowed, 2), [
        ['line1', 'line2', 'line3'],
        ['line4', 'line5'],
      ]);
      final (orphaned, _) = render([
        para(lines(3, 'a')),
        para(lines(3, 'b')),
      ], rowsTemplate(4));
      expect(pageTexts(orphaned, 2), [
        ['a1', 'a2', 'a3'],
        ['b1', 'b2', 'b3'],
      ]);
    });

    test('keep together and keep with next', () {
      final (kept, _) = render([
        para(lines(2, 'a')),
        BlockBox([
          para(lines(3, 'k')),
        ], style: const BoxStyle(keepTogether: true)),
      ], rowsTemplate(4));
      expect(pageTexts(kept, 2), [
        ['a1', 'a2'],
        ['k1', 'k2', 'k3'],
      ]);
      final (headed, _) = render([
        para(lines(3, 'a')),
        ParagraphBox(
          Paragraph([TextRun('Heading', body)]),
          style: const BoxStyle(keepWithNext: true),
        ),
        para(lines(3, 'b')),
      ], rowsTemplate(4));
      expect(pageTexts(headed, 2), [
        ['a1', 'a2', 'a3'],
        ['Heading', 'b1', 'b2', 'b3'],
      ]);
    });

    test('page breaks, ignored at the top of a page', () {
      final (pdf, result) = render([
        const BreakBox.page(),
        para('one'),
        const BreakBox.page(),
        para('two'),
      ], rowsTemplate(4));
      expect(result.pageCount, 2);
      expect(pageTexts(pdf, 2), [
        ['one'],
        ['two'],
      ]);
    });

    test('columns: of the page, and a column set', () {
      final (pdf, result) = render([
        para(lines(6)),
      ], rowsTemplate(3, columns: 2));
      expect(result.pageCount, 1);
      expect(
        pageTexts(pdf, 1).single,
        [
          'line1 line4',
          'line2 line5',
          'line3 line6',
        ].map((l) => [l]).expand((l) => l).toList(),
      );
      final (set, _) = render([
        para('intro'),
        ColumnsBox([para(lines(4, 'c'))]),
      ], rowsTemplate(3));
      expect(pageTexts(set, 1).single, ['intro', 'c1 c3', 'c2 c4']);
    });

    test('headers and footers: page numbers, count, running marks', () {
      final (pdf, _) = render(
        [
          ParagraphBox(
            Paragraph([TextRun('Chapter A', heading)]),
            style: const BoxStyle(marks: {'chapter': 'Alpha'}),
          ),
          para(lines(6, 'a')),
          ParagraphBox(
            Paragraph([TextRun('Chapter B', heading)]),
            style: const BoxStyle(marks: {'chapter': 'Beta'}),
          ),
          para(lines(2, 'b')),
        ],
        rowsTemplate(
          5,
          header: (page) => [
            ParagraphBox(
              Paragraph([
                TextRun(
                  '${page.mark('chapter')} - ${page.label}/${page.count}',
                  body,
                ),
              ]),
            ),
          ],
        ),
        pageLabel: (n) => 'p$n',
      );
      final pages = pageTexts(pdf, 3);
      expect(pages[0].first, 'Alpha - p1/3');
      // Chapter B starts on page 2: the first mark set on a page wins;
      // page 3 carries it over.
      expect(pages[1].first, 'Beta - p2/3');
      expect(pages[2].first, 'Beta - p3/3');
    });

    test('page references are resolved, laying out again', () {
      final (pdf, result) = render([
        ParagraphBox(
          Paragraph([TextRun('See ', body), PageReference('target', body)]),
        ),
        para(lines(9)),
        ParagraphBox(
          Paragraph([TextRun('Target', body)]),
          style: const BoxStyle(anchor: 'target'),
        ),
      ], rowsTemplate(4));
      expect(result.pageOf('target'), 3);
      expect(pageTexts(pdf, 1).single.first, 'See 3');
      final dests = Process.runSync('pdfinfo', ['-dests', pdf.path]).stdout;
      expect('$dests', contains('"target"'));
    });

    test('decorations: background and borders, open where a block splits', () {
      final (pdf, _) = render([
        BlockBox(
          [para(lines(6))],
          style: const BoxStyle(
            background: PdfColor.rgb(1, 0.9, 0.9),
            border: Border(
              widths: EdgeInsets.all(2),
              color: PdfColor.rgb(1, 0, 0),
            ),
            padding: EdgeInsets.all(4),
          ),
        ),
      ], rowsTemplate(4));
      // Each page holds two of the six lines.
      final [first, middle, last] = [
        for (final p in [1, 2, 3]) _raster(pdf, p),
      ];
      final top = first.height - 21; // just inside the region's top
      // The left border on every page.
      for (final page in [first, middle, last]) {
        expect(page.at(21, top - 4), (255, 0, 0));
      }
      // The top border only on the first page.
      expect(first.at(150, top), (255, 0, 0));
      expect(middle.at(150, top), isNot((255, 0, 0)));
      // The bottom border only on the last: below its 2 lines, the bottom
      // padding, then the border (sampled inside it).
      final bottom = top + 1 - 2 * lineHeight - 4 - 2 + 0.5;
      expect(last.at(150, bottom), (255, 0, 0));
      expect(first.at(150, bottom), _pink);
      expect(first.at(150, top - 10), _pink);
    });

    test('images shrink to fit a region; drawings are placed', () {
      final png = PdfImage.parse(
        File('test/images/pngsuite/basn2c08.png').readAsBytesSync(),
      );
      var drawn = const PdfRect(0, 0, 0, 0);
      final (pdf, result) = render([
        ImageBox(png, 100, 1000, align: BoxAlign.center),
        DrawingBox(10, (canvas, rect) {
          drawn = rect;
          canvas
            ..rect(rect)
            ..fill();
        }),
      ], rowsTemplate(4));
      expect(result.pageCount, 2);
      expect(drawn.width, 260);
      expect(pdf.lengthSync(), greaterThan(0));
    });
  });
}

/// The background (0.9 of 255 rounds either way).
final Matcher _pink = predicate<(int, int, int)>(
  (c) => c.$1 == 255 && (c.$2 - 230).abs() <= 1 && (c.$3 - 230).abs() <= 1,
  'the pink background',
);

/// A page rendered at 72 dpi; `at` takes y from the bottom.
final class _Raster {
  new(this.width, this.height, this.samples);

  final int width;
  final int height;
  final Uint8List samples;

  (int, int, int) at(num x, num y) {
    final i = ((height - 1 - y.floor()) * width + x.floor()) * 3;
    return (samples[i], samples[i + 1], samples[i + 2]);
  }
}

_Raster _raster(File pdf, int page) {
  final out = '${pdf.path}-$page';
  Process.runSync('pdftoppm', [
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
  final bytes = File('$out.ppm').readAsBytesSync();
  final header = latin1.decode(bytes.sublist(0, 20)).split(RegExp(r'\s+'));
  final width = int.parse(header[1]);
  final height = int.parse(header[2]);
  return _Raster(
    width,
    height,
    Uint8List.sublistView(bytes, bytes.length - width * height * 3),
  );
}

/// Custom content: [count] lines of 10 points from [from], with a gap of
/// 3 points above each piece.
final class _Lines implements CustomContent {
  const new(this.count, this.from);

  final int count;
  final int from;

  @override
  CustomPlacement? place(
    double width,
    double available, {
    required bool atTop,
  }) {
    final fit = ((available - 3) / 10).floor().clamp(0, count - from);
    if (fit == 0 && !atTop) return null;
    final n = fit == 0 ? 1 : fit;
    return CustomPlacement(
      height: 3 + n * 10,
      paint: (page, x, top) {},
      rest: from + n < count ? _Lines(count, from + n) : null,
      anchors: [
        for (var i = 0; i < n; i++) ('line-${from + i}', 0, 3 + i * 10),
      ],
    );
  }

  @override
  double minHeight(double width) => 13;

  @override
  (double, double) intrinsicWidths() => (10, 10);
}

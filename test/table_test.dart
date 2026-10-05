@Tags(['pdf-tools'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:libpdf/libpdf.dart';
import 'package:test/test.dart';

final PdfTextStyle body = PdfTextStyle(StandardFont.helvetica, 10);
final double lineHeight =
    (StandardFont.helvetica.ascender - StandardFont.helvetica.descender) / 100;

TableCell cell(
  String text, {
  int colSpan = 1,
  int rowSpan = 1,
  PdfColor? background,
  Border border = Border.none,
  VerticalAlign verticalAlign = VerticalAlign.top,
}) => TableCell(
  [
    ParagraphBox(Paragraph([TextRun(text, body)]), orphans: 1, widows: 1),
  ],
  colSpan: colSpan,
  rowSpan: rowSpan,
  background: background,
  border: border,
  verticalAlign: verticalAlign,
);

TableRow row(List<TableCell> cells) => TableRow(cells);

bool _has(String tool) => Process.runSync('which', [tool]).exitCode == 0;

late Directory _dir;
var _count = 0;

/// [boxes] on pages [height] tall (300 wide, 20 margins), rendered.
(File, LayoutResult) render(List<LayoutBox> boxes, {double height = 400}) {
  final result = FlowLayout(
    template: PageTemplate(
      PdfRect(0, 0, 300, height),
      margins: const EdgeInsets.all(20),
    ),
  ).layout(boxes);
  final document = PdfDocument();
  result.render(document);
  final file = File('${_dir.path}/t${_count++}.pdf')
    ..writeAsBytesSync(document.save());
  return (file, result);
}

typedef Word = ({String text, double x, double top, int page});

/// The words of every page, with their left edge and top (y down).
List<Word> words(File pdf) {
  final html =
      Process.runSync('pdftotext', ['-bbox', pdf.path, '-']).stdout as String;
  final result = <Word>[];
  var page = 0;
  for (final line in html.split('\n')) {
    if (line.contains('<page ')) page++;
    final m = RegExp(
      r'<word xMin="([\d.]+)" yMin="([\d.]+)"[^>]*>([^<]*)</word>',
    ).firstMatch(line);
    if (m != null) {
      result.add((
        text: m[3]!,
        x: double.parse(m[1]!),
        top: double.parse(m[2]!),
        page: page,
      ));
    }
  }
  return result;
}

Word word(List<Word> all, String text) => all.firstWhere((w) => w.text == text);

void main() {
  setUpAll(() => _dir = Directory.systemTemp.createTempSync('libpdf.'));
  tearDownAll(() => _dir.deleteSync(recursive: true));
  if (!['pdftotext', 'pdftoppm'].every(_has)) {
    test('tables', () {}, skip: 'needs poppler');
    return;
  }

  test('fixed and fraction columns', () {
    final (pdf, _) = render([
      TableBox(
        [
          row([cell('a'), cell('b'), cell('c')]),
        ],
        columns: const [
          ColumnWidth.fixed(60),
          ColumnWidth.fraction(1),
          ColumnWidth.fraction(3),
        ],
      ),
    ]);
    final all = words(pdf);
    // Padding 4: columns at 20, 80, 130.
    expect(word(all, 'a').x, closeTo(24, 0.5));
    expect(word(all, 'b').x, closeTo(84, 0.5));
    expect(word(all, 'c').x, closeTo(134, 0.5));
  });

  test('computed columns take a width from the table', () {
    final (pdf, _) = render([
      TableBox(
        [
          row([cell('a'), cell('b')]),
        ],
        columns: [
          ColumnWidth.computed((width) => width / 4),
          const ColumnWidth.fraction(1),
        ],
      ),
    ]);
    // A quarter of 260, then the rest.
    expect(word(words(pdf), 'b').x, closeTo(20 + 65 + 4, 0.5));
  });

  test('cells placed by offset and decorated by a callback', () {
    final pieces = <(PdfRect, bool, bool)>[];
    final (pdf, _) = render([
      TableBox(
        [
          row([
            TableCell(
              [
                ParagraphBox(
                  Paragraph([TextRun('low', body)]),
                  orphans: 1,
                  widows: 1,
                ),
              ],
              padding: EdgeInsets.zero,
              verticalOffset: (room, height) => room - height,
              decoration: (page, rect, {required first, required last}) =>
                  pieces.add((rect, first, last)),
            ),
            const TableCell([SpacerBox(100)], padding: EdgeInsets.zero),
          ]),
        ],
        columns: const [ColumnWidth.fixed(100), ColumnWidth.fixed(100)],
      ),
    ]);
    // At the bottom of the 100 points the row takes.
    expect(word(words(pdf), 'low').top, closeTo(20 + 100 - 10, 2));
    expect(pieces, hasLength(1));
    expect(pieces.single.$1.height, 100);
    expect((pieces.single.$2, pieces.single.$3), (true, true));
  });

  test('auto columns share the width by their content', () {
    final (pdf, _) = render([
      TableBox(
        [
          row([cell('x'), cell('a much longer cell of text')]),
        ],
        columns: const [ColumnWidth.auto(), ColumnWidth.auto()],
        shrinkToContent: true,
      ),
    ]);
    final all = words(pdf);
    final first = body.measure('x') + 8;
    expect(word(all, 'a').x, closeTo(20 + first + 4, 0.5));
    final (wide, _) = render([
      TableBox(
        [
          row([
            cell('short words only here'),
            cell(List.filled(30, 'long').join(' ')),
          ]),
        ],
        columns: const [ColumnWidth.auto(), ColumnWidth.auto()],
      ),
    ]);
    // Neither column below its widest word; the long one gets more room.
    final second = word(words(wide), 'long').x - 4 - 20;
    expect(second, greaterThan(body.measure('short') + 8));
    expect(second, lessThan(260 - body.measure('long') - 8));
  });

  test('column and row spans', () {
    final (pdf, _) = render([
      TableBox(
        [
          row([cell('span2', colSpan: 2), cell('c3')]),
          row([cell('tall', rowSpan: 2), cell('b2'), cell('b3')]),
          row([cell('c2'), cell('cc3')]),
        ],
        columns: const [
          ColumnWidth.fixed(80),
          ColumnWidth.fixed(80),
          ColumnWidth.fixed(80),
        ],
      ),
    ]);
    final all = words(pdf);
    expect(word(all, 'span2').x, closeTo(24, 0.5));
    expect(word(all, 'c3').x, closeTo(184, 0.5));
    expect(word(all, 'c2').x, closeTo(104, 0.5), reason: 'after the span');
    expect(word(all, 'cc3').x, closeTo(184, 0.5));
    expect(word(all, 'c2').top, greaterThan(word(all, 'b2').top));
  });

  test('header rows repeat on each page', () {
    final (pdf, result) = render([
      TableBox(
        [
          row([cell('Head')]),
          for (var i = 1; i <= 12; i++) row([cell('row$i')]),
        ],
        columns: const [ColumnWidth.fraction(1)],
        headerRows: 1,
      ),
    ], height: 40 + 5 * (lineHeight + 8));
    expect(result.pageCount, 3);
    final all = words(pdf);
    for (var page = 1; page <= 3; page++) {
      final first = all.where((w) => w.page == page).first;
      expect(first.text, 'Head', reason: 'page $page');
    }
    expect(all.where((w) => w.text != 'Head').map((w) => w.text), [
      for (var i = 1; i <= 12; i++) 'row$i',
    ]);
  });

  test('a row taller than a page splits its cells', () {
    final tall = List.generate(12, (i) => 'L${i + 1}').join('\n');
    final (pdf, result) = render([
      TableBox(
        [
          row([cell(tall), cell('side')]),
          row([cell('after'), cell('end')]),
        ],
        columns: const [ColumnWidth.fraction(1), ColumnWidth.fraction(1)],
      ),
    ], height: 40 + 5 * lineHeight + 8);
    expect(result.pageCount, greaterThan(2));
    final texts = words(pdf).map((w) => w.text).toList();
    expect(texts.where((t) => t.startsWith('L')).toList(), [
      for (var i = 1; i <= 12; i++) 'L$i',
    ]);
    expect(texts, containsAllInOrder(['side', 'after', 'end']));
  });

  test('a group joined by a row span moves together', () {
    final (pdf, _) = render([
      TableBox(
        [
          row([cell('a1'), cell('a2')]),
          row([cell('a3'), cell('a4')]),
          row([cell('span', rowSpan: 2), cell('b1')]),
          row([cell('b2')]),
        ],
        columns: const [ColumnWidth.fraction(1), ColumnWidth.fraction(1)],
      ),
    ], height: 40 + 3 * (lineHeight + 8));
    final all = words(pdf);
    expect(word(all, 'a3').page, 1);
    expect(word(all, 'span').page, 2);
    expect(word(all, 'b2').page, 2);
  });

  test('stripes start over in each region', () {
    const blue = PdfColor.rgb(0, 0, 1);
    final (pdf, _) = render([
      TableBox(
        [
          row([cell('head')]),
          for (var i = 0; i < 30; i++) row([cell('r$i')]),
        ],
        columns: const [ColumnWidth.fixed(100)],
        headerRows: 1,
        stripes: const [blue, null],
      ),
    ], height: 200);
    final all = words(pdf);
    // The first body row of each page is blue, the next one isn't.
    for (final page in {for (final w in all) w.page}) {
      final rows = all.where((w) => w.page == page && w.text != 'head');
      final first = rows.first;
      final second = rows.elementAt(1);
      final out = '${pdf.path}-p$page';
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
      final pixels = Uint8List.sublistView(
        bytes,
        bytes.length - width * int.parse(header[2]) * 3,
      );
      (int, int, int) at(double x, double yDown) {
        final i = (yDown.round() * width + x.round()) * 3;
        return (pixels[i], pixels[i + 1], pixels[i + 2]);
      }

      expect(at(21, first.top + 2), (0, 0, 255), reason: 'page $page');
      expect(at(21, second.top + 2), (255, 255, 255), reason: 'page $page');
    }
  });

  test('backgrounds, borders and vertical alignment', () {
    const red = PdfColor.rgb(1, 0, 0);
    final (pdf, _) = render([
      TableBox(
        [
          row([
            cell(
              'top',
              background: const PdfColor.rgb(0, 0, 1),
              border: const Border(widths: EdgeInsets.all(2), color: red),
            ),
            cell(List.filled(5, 'x').join('\n')),
            cell('mid', verticalAlign: VerticalAlign.middle),
          ]),
        ],
        columns: const [
          ColumnWidth.fixed(80),
          ColumnWidth.fixed(80),
          ColumnWidth.fixed(80),
        ],
      ),
    ]);
    final all = words(pdf);
    final rowHeight = 5 * lineHeight + 8;
    expect(
      word(all, 'mid').top - word(all, 'top').top,
      closeTo((rowHeight - 8 - lineHeight) / 2, 1),
    );
    final out = '${pdf.path}-1';
    Process.runSync('pdftoppm', ['-r', '72', '-singlefile', pdf.path, out]);
    final bytes = File('$out.ppm').readAsBytesSync();
    final header = latin1.decode(bytes.sublist(0, 20)).split(RegExp(r'\s+'));
    final width = int.parse(header[1]);
    final pixels = Uint8List.sublistView(
      bytes,
      bytes.length - width * int.parse(header[2]) * 3,
    );
    (int, int, int) at(int x, int yDown) {
      final i = (yDown * width + x) * 3;
      return (pixels[i], pixels[i + 1], pixels[i + 2]);
    }

    expect(at(60, 20 + rowHeight ~/ 2), (0, 0, 255), reason: 'background');
    expect(at(20, 20 + rowHeight ~/ 2), (255, 0, 0), reason: 'left border');
    expect(at(60, 20), (255, 0, 0), reason: 'top border');
  });
}

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

  group('floating boxes', () {
    // 80 points a region; lines of 10 after a gap of 3.
    LayoutResult layout(List<LayoutBox> content) => FlowLayout(
      template: const PageTemplate(
        PdfRect(0, 0, 100, 100),
        margins: EdgeInsets.all(10),
      ),
    ).layout(content);

    const figure = CustomBox(
      _Rigid(40),
      style: BoxStyle(anchor: 'fig', float: FloatPlacement.next),
    );

    test("that don't fit go to the next region, the text filling in", () {
      final result = layout([
        const CustomBox(_Lines(5, 0)),
        figure,
        const CustomBox(_Lines(2, 0, prefix: 'b')),
      ]);
      // 53 points of lines: the figure's 40 don't fit, the next 23 do.
      expect(result.anchors['b-1']!.page, 0);
      expect(result.anchors['fig']!.page, 1);
      expect(result.anchors['fig']!.y, closeTo(90, 1e-6));
      // Without floating, the figure and what follows move.
      final fixed = layout([
        const CustomBox(_Lines(5, 0)),
        const CustomBox(_Rigid(40), style: BoxStyle(anchor: 'fig')),
        const CustomBox(_Lines(2, 0, prefix: 'b')),
      ]);
      expect(fixed.anchors['b-0']!.page, 1);
    });

    test('are not passed by a barrier (a heading)', () {
      final result = layout([
        const CustomBox(_Lines(5, 0)),
        figure,
        const CustomBox(
          _Fixed(5),
          style: BoxStyle(anchor: 'heading', floatBarrier: true),
        ),
        const CustomBox(_Lines(1, 0, prefix: 'b')),
      ]);
      expect(result.anchors['fig']!.page, 1);
      expect(result.anchors['heading']!.page, 1);
      expect(result.anchors['heading']!.y, lessThan(result.anchors['fig']!.y));
    });

    test('go before a page break that comes after them', () {
      final result = layout([
        const CustomBox(_Lines(5, 0)),
        figure,
        const CustomBox(_Lines(1, 0, prefix: 'b')),
        const BreakBox.page(),
        const CustomBox(_Lines(1, 0, prefix: 'c')),
      ]);
      expect(result.anchors['b-0']!.page, 0);
      expect(result.anchors['fig']!.page, 1);
      expect(result.anchors['c-0']!.page, 2);
    });

    CustomBox figureAt(FloatPlacement float) => CustomBox(
      const _Rigid(20),
      style: BoxStyle(anchor: 'fig', float: float),
    );

    test('that fit may go to the bottom of the region', () {
      final result = layout([
        const CustomBox(_Lines(2, 0)),
        figureAt(FloatPlacement.bottom),
        const CustomBox(_Lines(2, 0, prefix: 'b')),
      ]);
      expect(result.pageCount, 1);
      // At the bottom: its top 20 points above the region's (10).
      expect(result.anchors['fig']!.y, closeTo(30, 1e-6));
      // The text after it right after the text before it (lines 10
      // points apart, a gap of 3 above each box).
      expect(
        result.anchors['line-1']!.y - result.anchors['b-0']!.y,
        closeTo(13, 1e-6),
      );
    });

    test('that fit may go to the top of the region', () {
      final result = layout([
        const CustomBox(_Lines(2, 0)),
        figureAt(FloatPlacement.top),
      ]);
      expect(result.anchors['fig']!.y, closeTo(90, 1e-6));
      expect(result.anchors['line-0']!.y, lessThan(70));
    });

    test('at the top, after a break at the top of the region', () {
      final result = layout([
        const BreakBox.page(),
        const CustomBox(_Lines(2, 0)),
        figureAt(FloatPlacement.top),
      ]);
      expect(result.pageCount, 1);
      expect(result.anchors['fig']!.y, closeTo(90, 1e-6));
      expect(result.anchors['line-0']!.page, 0);
    });

    test('stay in a framed block', () {
      final result = layout([
        BlockBox([
          const CustomBox(_Lines(2, 0)),
          figureAt(FloatPlacement.bottom),
          const CustomBox(_Lines(1, 0, prefix: 'b')),
        ], style: const BoxStyle(padding: EdgeInsets.all(2))),
      ]);
      // In the flow: the line after it below it.
      expect(result.anchors['fig']!.y, greaterThan(result.anchors['b-0']!.y));
    });

    test('auto: to the nearer edge', () {
      final early = layout([
        const CustomBox(_Lines(1, 0)),
        figureAt(FloatPlacement.auto),
        const CustomBox(_Lines(4, 0, prefix: 'b')),
      ]);
      expect(early.anchors['fig']!.y, closeTo(90, 1e-6));
      final late = layout([
        const CustomBox(_Lines(4, 0)),
        figureAt(FloatPlacement.auto),
        const CustomBox(_Lines(1, 0, prefix: 'b')),
      ]);
      expect(late.anchors['fig']!.y, closeTo(30, 1e-6));
    });

    test('are placed after the end of the content', () {
      final result = layout([const CustomBox(_Lines(5, 0)), figure]);
      expect(result.pageCount, 2);
      expect(result.anchors['fig']!.page, 1);
    });

    test('for the bottom that wait go to the bottom of the next region', () {
      final result = layout([
        const CustomBox(_Lines(5, 0)),
        const CustomBox(
          _Rigid(40),
          style: BoxStyle(anchor: 'fig', float: FloatPlacement.bottom),
        ),
        const CustomBox(_Lines(4, 0, prefix: 'b')),
      ]);
      expect(result.anchors['fig']!.page, 1);
      // At the bottom: its top 40 points above the region's bottom (10).
      expect(result.anchors['fig']!.y, closeTo(50, 1e-6));
      // The text it waited behind at the top of that region.
      expect(result.anchors['b-3']!.page, 1);
      expect(result.anchors['b-3']!.y, greaterThan(50));
    });

    test('keep their clearance from the text', () {
      LayoutResult at(double clearance) => layout([
        const CustomBox(_Lines(2, 0)),
        CustomBox(
          const _Rigid(20),
          style: BoxStyle(
            anchor: 'fig',
            float: FloatPlacement.top,
            floatClearance: clearance,
          ),
        ),
      ]);
      expect(at(0).anchors['fig']!.y, closeTo(90, 1e-6));
      expect(
        at(0).anchors['line-0']!.y - at(15).anchors['line-0']!.y,
        closeTo(15, 1e-6),
      );
    });
  });

  test("a block's margin below takes no more than the room left", () {
    final result =
        FlowLayout(
          template: const PageTemplate(
            PdfRect(0, 0, 100, 100),
            margins: EdgeInsets.all(10),
          ),
        ).layout([
          const BlockBox([
            CustomBox(_Rigid(75)),
          ], style: BoxStyle(margin: EdgeInsets(bottom: 20))),
          const CustomBox(_Rigid(10), style: BoxStyle(anchor: 'next')),
        ]);
    expect(result.anchors['next']!.page, 1);
  });

  test('a piece with cloned edges closes under its last box', () {
    // 80 points: a block padded 5, two boxes of 30 with 10 below each,
    // then one that goes on: the first piece ends 5 under the second box.
    final result =
        FlowLayout(
          template: const PageTemplate(
            PdfRect(0, 0, 100, 100),
            margins: EdgeInsets.all(10),
          ),
        ).layout([
          const BlockBox(
            [
              CustomBox(
                _Rigid(30),
                style: BoxStyle(margin: EdgeInsets(bottom: 10)),
              ),
              CustomBox(
                _Rigid(20),
                style: BoxStyle(margin: EdgeInsets(bottom: 10)),
              ),
              CustomBox(_Rigid(30), style: BoxStyle(anchor: 'rest')),
            ],
            style: BoxStyle(
              padding: EdgeInsets(top: 5, bottom: 5),
              cloneEdges: true,
            ),
          ),
        ]);
    expect(result.anchors['rest']!.page, 1);
  });

  test("a box's margin below takes no more than the room left", () {
    // 80 points: a box 75 tall with a margin of 20 below, then another.
    final result =
        FlowLayout(
          template: const PageTemplate(
            PdfRect(0, 0, 100, 100),
            margins: EdgeInsets.all(10),
          ),
        ).layout([
          const CustomBox(
            _Rigid(75),
            style: BoxStyle(margin: EdgeInsets(bottom: 20)),
          ),
          const CustomBox(_Rigid(10), style: BoxStyle(anchor: 'next')),
        ]);
    expect(result.anchors['next']!.page, 1);
    expect(result.anchors['next']!.y, closeTo(90, 1e-6));
  });

  group('a block split across regions', () {
    // 80 points a region, its top at 90.
    LayoutResult layout(List<LayoutBox> content) => FlowLayout(
      template: const PageTemplate(
        PdfRect(0, 0, 100, 100),
        margins: EdgeInsets.all(10),
      ),
    ).layout(content);

    BlockBox framed({required bool clone}) => BlockBox(
      [
        for (var i = 0; i < 5; i++)
          CustomBox(const _Rigid(25), style: BoxStyle(anchor: 'r$i')),
      ],
      style: BoxStyle(
        padding: const EdgeInsets(top: 5, bottom: 5),
        cloneEdges: clone,
      ),
    );

    test('with cloneEdges has its padding on every piece', () {
      final open = layout([framed(clone: false)]);
      // The first piece: its top padding, then rows to the region's end.
      expect(open.anchors['r2']!.page, 0);
      expect(open.anchors['r3']!.page, 1);
      expect(open.anchors['r3']!.y, closeTo(90, 1e-6));
      final cloned = layout([framed(clone: true)]);
      // Room for the bottom padding on the first page: a row less.
      expect(cloned.anchors['r1']!.page, 0);
      expect(cloned.anchors['r2']!.page, 1);
      // The second piece starts below its own top padding.
      expect(cloned.anchors['r2']!.y, closeTo(85, 1e-6));
    });

    test('that ends with a break carries nothing past it', () {
      final result = layout([
        const BlockBox([
          CustomBox(_Rigid(10)),
          BreakBox.page(),
        ], style: BoxStyle(margin: EdgeInsets(bottom: 30))),
        const CustomBox(_Rigid(10), style: BoxStyle(anchor: 'next')),
      ]);
      // The next box at the top of the next page: the margin is not
      // carried over.
      expect(result.anchors['next']!.page, 1);
      expect(result.anchors['next']!.y, closeTo(90, 1e-6));
    });
  });

  group('a block aligned in its region', () {
    // 80 points a region, its top at 90.
    LayoutResult layout(List<LayoutBox> content) => FlowLayout(
      template: const PageTemplate(
        PdfRect(0, 0, 100, 100),
        margins: EdgeInsets.all(10),
      ),
    ).layout(content);

    BlockBox aligned(VerticalAlign align, double height) => BlockBox([
      CustomBox(_Rigid(height), style: const BoxStyle(anchor: 'c')),
    ], style: BoxStyle(verticalAlign: align));

    test('sits in the middle or at the bottom of the room', () {
      expect(
        layout([aligned(VerticalAlign.middle, 20)]).anchors['c']!.y,
        closeTo(60, 1e-6),
      );
      expect(
        layout([aligned(VerticalAlign.bottom, 20)]).anchors['c']!.y,
        closeTo(30, 1e-6),
      );
      // After a page break too: it starts the region.
      final result = layout([
        const CustomBox(_Rigid(10)),
        const BreakBox.page(),
        aligned(VerticalAlign.middle, 20),
      ]);
      expect(result.anchors['c']!.page, 1);
      expect(result.anchors['c']!.y, closeTo(60, 1e-6));
      // Its margin below is outside it: still in the middle.
      final margined = layout([
        const BlockBox(
          [CustomBox(_Rigid(20), style: BoxStyle(anchor: 'c'))],
          style: BoxStyle(
            verticalAlign: VerticalAlign.middle,
            margin: EdgeInsets(bottom: 12),
          ),
        ),
      ]);
      expect(margined.anchors['c']!.y, closeTo(60, 1e-6));
    });

    test('stays where it is when it does not start the region or fit', () {
      final after = layout([
        const CustomBox(_Rigid(10)),
        aligned(VerticalAlign.middle, 20),
      ]);
      expect(after.anchors['c']!.y, closeTo(80, 1e-6));
      final tall = layout([aligned(VerticalAlign.middle, 80)]);
      expect(tall.anchors['c']!.y, closeTo(90, 1e-6));
    });
  });

  group('notes', () {
    // 80 points a region; lines of 10 after a gap of 3.
    LayoutResult layout(
      List<LayoutBox> content,
      Map<String, LayoutBox> notes,
    ) => FlowLayout(
      template: const PageTemplate(
        PdfRect(0, 0, 100, 100),
        margins: EdgeInsets.all(10),
      ),
      notes: notes,
    ).layout(content);

    test('go to the bottom of the region their anchor is in', () {
      final result = layout(
        [const CustomBox(_Lines(20, 0))],
        {
          'line-2': const CustomBox(
            _Fixed(25),
            style: BoxStyle(anchor: 'note'),
          ),
        },
      );
      // The content leaves the note 25 points: 5 lines on the first page.
      expect(result.anchors['line-4']!.page, 0);
      expect(result.anchors['line-5']!.page, 1);
      final note = result.anchors['note']!;
      expect(note.page, 0);
      // Its top 25 points above the region's bottom.
      expect(note.y, closeTo(35, 1e-6));
    });

    test('a note too long for the region goes on in the next', () {
      final result = layout(
        [const CustomBox(_Lines(3, 0))],
        {'line-1': const CustomBox(_Lines(12, 0, prefix: 'n'))},
      );
      // Under the 3 lines (33 points), 4 of the note's lines; then 7 on a
      // page of their own, then the last.
      expect(result.anchors['n-3']!.page, 0);
      expect(result.anchors['n-4']!.page, 1);
      expect(result.anchors['n-10']!.page, 1);
      expect(result.anchors['n-11']!.page, 2);
      expect(result.pageCount, 3);
    });

    test('are set once, with a separator above them', () {
      final result = FlowLayout(
        template: const PageTemplate(
          PdfRect(0, 0, 100, 100),
          margins: EdgeInsets.all(10),
        ),
        notes: {
          'line-0': const CustomBox(
            _Fixed(10),
            style: BoxStyle(anchor: 'note'),
          ),
        },
        noteSeparator: const CustomBox(
          _Fixed(5),
          style: BoxStyle(anchor: 'rule'),
        ),
      ).layout([const CustomBox(_Lines(2, 0))]);
      expect(result.pageCount, 1);
      expect(result.anchors['rule']!.y, closeTo(25, 1e-6));
      expect(result.anchors['note']!.y, closeTo(20, 1e-6));
    });
  });

  test('a block reserves its bottom padding only below its last child', () {
    // 80 points a region; lines of 10 after a gap of 3.
    LayoutResult layout(int count) =>
        FlowLayout(
          template: const PageTemplate(
            PdfRect(0, 0, 100, 100),
            margins: EdgeInsets.all(10),
          ),
        ).layout([
          BlockBox([
            CustomBox(_Lines(count, 0)),
          ], style: const BoxStyle(padding: EdgeInsets(bottom: 15))),
        ]);
    // Split: the first page takes 7 lines, as if there were no padding.
    var result = layout(20);
    expect(result.anchors['line-6']!.page, 0);
    expect(result.anchors['line-7']!.page, 1);
    // Whole but for the padding: the last line goes along with it.
    result = layout(7);
    expect(result.anchors['line-5']!.page, 0);
    expect(result.anchors['line-6']!.page, 1);
    // Whole with the padding: one page.
    expect(layout(6).pageCount, 1);
  });

  test('kept templates: a break template lasts; at the top it replaces', () {
    const portrait = PageTemplate(PdfRect(0, 0, 100, 200));
    const landscape = PageTemplate(PdfRect(0, 0, 200, 100));
    List<double> widths(List<LayoutBox> boxes) {
      final document = PdfDocument();
      final pages = FlowLayout(
        template: portrait,
        templates: {'landscape': landscape, 'portrait': portrait},
        keepTemplate: true,
      ).layout(boxes).render(document);
      return [for (final page in pages) page.width];
    }

    // The landscape pages go on until a break names another template.
    expect(
      widths([
        para('one'),
        const BreakBox.page(template: 'landscape'),
        para('two'),
        const BreakBox.page(),
        para('three'),
        const BreakBox.page(template: 'portrait'),
        para('four'),
      ]),
      [100, 200, 200, 100],
    );
    // At the top of an empty page, the break makes it a landscape page.
    expect(widths([const BreakBox.page(template: 'landscape'), para('one')]), [
      200,
    ]);
    // An anchor on the page it replaces goes along to the new page.
    final result =
        FlowLayout(
          template: portrait,
          templates: {'landscape': landscape, 'portrait': portrait},
          keepTemplate: true,
        ).layout([
          const BlockBox([], style: BoxStyle(anchor: 'start')),
          const BreakBox.page(template: 'landscape'),
          para('one'),
        ]);
    expect(result.pageCount, 1);
    expect(result.anchors['start']!.page, 0);
  });

  test('a break to a side inserts a blank page when needed', () {
    int pageOf(List<LayoutBox> boxes) =>
        FlowLayout(template: rowsTemplate(4)).layout(boxes).anchors['b']!.page;
    final b = BlockBox([para('b')], style: const BoxStyle(anchor: 'b'));
    // From page 1, the next recto is page 3: page 2 stays blank.
    expect(
      pageOf([para('a'), const BreakBox.page(side: PageSide.recto), b]),
      2,
    );
    // From page 1, the next verso is page 2.
    expect(
      pageOf([para('a'), const BreakBox.page(side: PageSide.verso), b]),
      1,
    );
    // At the top of a verso page, that page stays blank.
    expect(
      pageOf([
        para('a'),
        const BreakBox.page(),
        const BreakBox.page(side: PageSide.recto),
        b,
      ]),
      2,
    );
    // At the top of a recto page, nothing happens.
    expect(pageOf([const BreakBox.page(side: PageSide.recto), b]), 0);
  });

  test('a bleed grows the sheet past the trimmed page', () {
    final document = PdfDocument();
    FlowLayout(template: const PageTemplate(PdfRect(0, 0, 100, 200), bleed: 9))
        .layout([para('a')])
        .render(document);
    final page = document.pages.single;
    expect(
      page.mediaBox.toString(),
      const PdfRect(-9, -9, 118, 218).toString(),
    );
    expect(page.trimBox.toString(), const PdfRect(0, 0, 100, 200).toString());
    expect(page.bleedBox.toString(), page.mediaBox.toString());
  });

  test('the layout reports the pages of tagged boxes', () {
    final result = FlowLayout(template: rowsTemplate(4)).layout([
      ParagraphBox(
        Paragraph([TextRun(lines(2), body)]),
        style: const BoxStyle(tag: 'short'),
        orphans: 1,
        widows: 1,
      ),
      ParagraphBox(
        Paragraph([TextRun(lines(5), body)]),
        style: const BoxStyle(tag: 'long'),
        orphans: 1,
        widows: 1,
      ),
      BlockBox([para('in a block')], style: const BoxStyle(tag: 'block')),
    ]);
    expect(result.tagPages['short'], (first: 1, last: 1));
    expect(result.tagPages['long'], (first: 1, last: 2));
    expect(result.tagPages['block'], (first: 2, last: 2));
    const style = BoxStyle(margin: EdgeInsets(top: 3), anchor: 'a');
    final tagged = style.withTag('t');
    expect([tagged.tag, tagged.anchor, tagged.margin.top], ['t', 'a', 3]);
  });

  test('a page with nothing on it reads as empty', () {
    final empty = <bool>[];
    FlowLayout(
          template: rowsTemplate(
            4,
            footer: (page) {
              empty.add(page.isEmpty);
              return const [];
            },
          ),
        )
        .layout([
          para('a'),
          const BreakBox.page(side: PageSide.recto),
          para('b'),
        ])
        .render(PdfDocument());
    // Page 2 is the blank verso before the recto start.
    expect(empty, [false, true, false]);
  });

  test('templateForPage gives each page its template', () {
    const template = PageTemplate(PdfRect(0, 0, 100, 100));
    final margins = <double>[];
    FlowLayout(
          template: template,
          templateForPage: (template, number) => PageTemplate(
            template.size,
            margins: EdgeInsets(left: number.isOdd ? 20 : 10),
            footer: (page) {
              margins.add(page.template.margins.left);
              return const [];
            },
          ),
        )
        .layout([
          para('a'),
          const BreakBox.page(),
          para('b'),
          const BreakBox.page(),
          para('c'),
        ])
        .render(PdfDocument());
    expect(margins, [20, 10, 20]);
  });

  test('a custom box paints its decoration under its content', () {
    final rects = <PdfRect>[];
    FlowLayout(template: rowsTemplate(4))
        .layout([
          CustomBox(
            const _Fixed(30),
            style: BoxStyle(
              margin: const EdgeInsets(left: 5, top: 10),
              decoration: (page, rect, {required first, required last}) =>
                  rects.add(rect),
            ),
          ),
        ])
        .render(PdfDocument());
    expect(rects, hasLength(1));
    expect(rects.single.height, 30);
    expect(rects.single.left, rowsTemplate(4).regions.first.left + 5);
  });

  test('a template paints its foreground over the content', () {
    final order = <String>[];
    FlowLayout(
      template: PageTemplate(
        const PdfRect(0, 0, 100, 100),
        margins: const EdgeInsets.all(10),
        background: (canvas, page) => order.add('background'),
        foreground: (canvas, page) => order.add('foreground'),
        footer: (page) {
          order.add('footer');
          return const [];
        },
      ),
    ).layout([para('a')]).render(PdfDocument());
    expect(order, ['background', 'footer', 'foreground']);
  });

  test('render names destinations by the anchors, or as told', () {
    final result = FlowLayout(template: rowsTemplate(4)).layout([
      BlockBox([para('a')], style: const BoxStyle(anchor: 'ä')),
    ]);
    final named = PdfDocument();
    result.render(named, destinationName: (anchor) => 'x-$anchor');
    final saved = latin1.decode(
      named.save(options: const PdfWriterOptions(compact: false)),
    );
    expect(saved, contains('(x-'));
  });

  test('a trailing page break makes no empty page', () {
    final result = FlowLayout(template: rowsTemplate(4))
        .layout([para('one'), const BreakBox.page()]);
    expect(result.pageCount, 1);
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

    test('a forced page break leaves the top of a page blank', () {
      final result = FlowLayout(template: rowsTemplate(4)).layout([
        para('one'),
        const BreakBox.page(),
        const BreakBox.page(force: true),
        para('two'),
      ]);
      expect(result.pageCount, 3);
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

    test('a column set: its top counts as a region top', () {
      // A column break first thing in the set is no break.
      final (set, _) = render([
        para('intro'),
        ColumnsBox([const BreakBox.column(), para(lines(4, 'c'))]),
      ], rowsTemplate(3));
      expect(pageTexts(set, 1).single, ['intro', 'c1 c3', 'c2 c4']);
      // A forced one leaves the first column blank.
      final (_, forced) = render([
        para('intro'),
        ColumnsBox([
          const BreakBox.column(force: true),
          ParagraphBox(
            Paragraph([TextRun('c1', body)]),
            style: const BoxStyle(anchor: 'c1'),
          ),
        ]),
      ], rowsTemplate(3));
      // The second column starts at 20 + (260 - 12) / 2 + 12.
      expect(forced.anchors['c1']!.x, closeTo(156, 0.01));
      // No room for a line: the set starts on the next page.
      final (late, result) = render([
        para(lines(3)),
        ColumnsBox([para(lines(2, 'c'))]),
      ], rowsTemplate(3));
      expect(result.pageCount, 2);
      expect(pageTexts(late, 2)[1], ['c1', 'c2']);
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
          [para(lines(9))],
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
      // Three of the nine lines below the top border and padding, four on
      // the middle page (no padding where the block continues), two above
      // the bottom padding and border.
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
  const new(this.count, this.from, {this.prefix = 'line'});

  final int count;
  final int from;

  /// The anchors' names before their numbers.
  final String prefix;

  @override
  CustomPlacement? place(
    double width,
    double available, {
    required bool atTop,
  }) {
    final fit = available.isInfinite
        ? count - from
        : ((available - 3) / 10).floor().clamp(0, count - from);
    if (fit == 0 && !atTop) return null;
    final n = fit == 0 ? 1 : fit;
    return CustomPlacement(
      height: 3 + n * 10,
      paint: (page, x, top) {},
      rest: from + n < count ? _Lines(count, from + n, prefix: prefix) : null,
      anchors: [
        for (var i = 0; i < n; i++) ('$prefix-${from + i}', 0, 3 + i * 10),
      ],
    );
  }

  @override
  double minHeight(double width) => 13;

  @override
  (double, double) intrinsicWidths() => (10, 10);
}

/// Custom content of a fixed height.
final class _Fixed implements CustomContent {
  const new(this.height);

  final double height;

  @override
  CustomPlacement? place(
    double width,
    double available, {
    required bool atTop,
  }) => CustomPlacement(height: height, paint: (page, x, top) {});

  @override
  double minHeight(double width) => height;

  @override
  (double, double) intrinsicWidths() => (0, 0);
}

/// Custom content of a fixed height that moves on whole when it doesn't
/// fit (an image).
final class _Rigid implements CustomContent {
  const new(this.height);

  final double height;

  @override
  CustomPlacement? place(
    double width,
    double available, {
    required bool atTop,
  }) => height > available && !atTop
      ? null
      : CustomPlacement(height: height, paint: (page, x, top) {});

  @override
  double minHeight(double width) => height;

  @override
  (double, double) intrinsicWidths() => (0, 0);
}

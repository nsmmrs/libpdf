// A sample document exercising the layout engine, shared by the golden
// render test and the benchmark.
import 'package:libpdf/libpdf.dart';

final PdfTextStyle _body = PdfTextStyle(StandardFont.timesRoman, 10.5);
final PdfTextStyle _heading = PdfTextStyle(
  StandardFont.named('Helvetica-Bold'),
  15,
);
final PdfTextStyle _small = PdfTextStyle(StandardFont.helvetica, 8);

const String _text =
    'The quick brown fox jumps over the lazy dog. Typesetting a '
    'paragraph means choosing where its lines break, so that the spaces '
    'between words are even and no line is too loose or too tight; '
    'the Knuth-Plass algorithm looks at the whole paragraph at once. '
    'Hyphens, soft hyphens (extra­ordinary), em dashes—like this—and '
    r'numbers such as 1,234.56 or $(12.35) follow the Unicode rules.';

/// [chapters] chapters, each a heading, paragraphs, a table and a column
/// set.
List<LayoutBox> sampleContent({int chapters = 3}) => [
  for (var c = 1; c <= chapters; c++) ...[
    if (c > 1) const BreakBox.page(),
    ParagraphBox(
      Paragraph([TextRun('Chapter $c', _heading, anchor: 'chapter-$c')]),
      style: BoxStyle(
        margin: const EdgeInsets(bottom: 8),
        keepWithNext: true,
        marks: {'chapter': 'Chapter $c'},
      ),
    ),
    for (var p = 0; p < 4; p++)
      ParagraphBox(
        Paragraph(
          [
            TextRun(_text, _body),
            if (p == 1) ...[
              TextRun(' See ', _body),
              PageReference('chapter-${c % chapters + 1}', _body),
              TextRun('.', _body),
            ],
          ],
          align: TextAlign.justify,
          firstLineIndent: p == 0 ? 0 : 12,
        ),
        style: const BoxStyle(margin: EdgeInsets(bottom: 6)),
        lineBreaker: const KnuthPlassLineBreaker(),
      ),
    TableBox(
      [
        TableRow([
          for (final h in ['Item', 'Description', 'Price'])
            _cell(h, background: const PdfColor.gray(0.85)),
        ]),
        for (var r = 1; r <= 6; r++)
          TableRow([
            _cell('#$r'),
            _cell('A thing of some length, number $r, described in words.'),
            _cell('${r * 3}.99'),
          ]),
      ],
      columns: const [
        ColumnWidth.auto(),
        ColumnWidth.fraction(1),
        ColumnWidth.auto(),
      ],
      headerRows: 1,
      style: const BoxStyle(margin: EdgeInsets.symmetric(vertical: 8)),
    ),
    ColumnsBox([
      for (var p = 0; p < 2; p++)
        ParagraphBox(
          Paragraph([TextRun(_text, _small)]),
          style: const BoxStyle(margin: EdgeInsets(bottom: 4)),
        ),
    ]),
  ],
];

TableCell _cell(String text, {PdfColor? background}) => TableCell(
  [
    ParagraphBox(Paragraph([TextRun(text, _small)])),
  ],
  background: background,
  border: const Border(widths: EdgeInsets.all(0.5)),
);

/// A layout for the sample: A5 pages with a running header and a footer.
FlowLayout sampleLayout() => FlowLayout(
  template: PageTemplate(
    const PdfRect(0, 0, 420, 595),
    margins: const EdgeInsets.symmetric(vertical: 50, horizontal: 40),
    header: (page) => [
      const SpacerBox(20),
      ParagraphBox(
        Paragraph([
          TextRun(page.mark('chapter') ?? '', _small),
        ], align: TextAlign.right),
      ),
    ],
    footer: (page) => [
      const SpacerBox(16),
      ParagraphBox(
        Paragraph([
          TextRun('${page.label} / ${page.count}', _small),
        ], align: TextAlign.center),
      ),
    ],
  ),
);

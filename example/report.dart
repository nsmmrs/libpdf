// A styled report: headings, justified paragraphs, a table with a
// repeated header, running headers and footers with page numbers, and a
// table of contents whose page numbers the layout fills in.
//
//   dart run example/report.dart report.pdf
import 'dart:io';

import 'package:libpdf/libpdf.dart';

void main(List<String> args) {
  final body = PdfTextStyle(StandardFont.timesRoman, 11);
  final small = PdfTextStyle(StandardFont.helvetica, 8);
  final heading = PdfTextStyle(StandardFont.named('Helvetica-Bold'), 16);
  final accent = PdfColor.hex('#1565c0');
  const sections = ['Summary', 'Findings', 'Data', 'Outlook'];
  const text =
      'Quarterly results improved across every region, with the largest '
      'gains where the new distribution network opened. Costs fell as the '
      'older warehouses closed, and the backlog of orders that built up in '
      'the spring cleared by the end of the summer.';

  final content = <LayoutBox>[
    ParagraphBox(
      Paragraph([TextRun('Contents', heading, color: accent)]),
      style: const BoxStyle(margin: EdgeInsets(bottom: 8)),
    ),
    for (final (i, name) in sections.indexed)
      ParagraphBox(
        Paragraph([
          TextRun('${i + 1}. $name', body, link: LinkTarget.named(name)),
          TextRun('  ', body),
          PageReference(name, body),
        ]),
      ),
    for (final name in sections) ...[
      const BreakBox.page(),
      ParagraphBox(
        Paragraph([TextRun(name, heading, color: accent)]),
        style: BoxStyle(
          anchor: name,
          marks: {'section': name},
          keepWithNext: true,
          margin: const EdgeInsets(bottom: 6),
        ),
      ),
      for (var p = 0; p < 6; p++)
        ParagraphBox(
          Paragraph(
            [TextRun(text, body)],
            align: TextAlign.justify,
            firstLineIndent: p == 0 ? 0 : 14,
          ),
          lineBreaker: const KnuthPlassLineBreaker(),
          style: const BoxStyle(margin: EdgeInsets(bottom: 4)),
        ),
      if (name == 'Data')
        TableBox(
          [
            TableRow([
              for (final h in ['Region', 'Q1', 'Q2', 'Q3'])
                _cell(h, small, background: const PdfColor.gray(0.85)),
            ]),
            for (var r = 1; r <= 40; r++)
              TableRow([
                _cell('Region $r', small),
                for (var q = 1; q <= 3; q++) _cell('${r * q * 7 % 100}', small),
              ]),
          ],
          columns: const [
            ColumnWidth.fraction(2),
            ColumnWidth.fraction(1),
            ColumnWidth.fraction(1),
            ColumnWidth.fraction(1),
          ],
          headerRows: 1,
          style: const BoxStyle(margin: EdgeInsets(top: 8)),
        ),
    ],
  ];

  final layout = FlowLayout(
    template: PageTemplate(
      const PdfRect(0, 0, 595, 842),
      header: (page) => [
        const SpacerBox(36),
        ParagraphBox(
          Paragraph([
            TextRun(page.mark('section') ?? 'Report', small),
          ], align: TextAlign.right),
        ),
      ],
      footer: (page) => [
        const SpacerBox(30),
        ParagraphBox(
          Paragraph([
            TextRun('${page.number} / ${page.count}', small),
          ], align: TextAlign.center),
        ),
      ],
    ),
  );
  final result = layout.layout(content);
  final document = PdfDocument(info: const PdfInfo(title: 'Quarterly report'));
  final pages = result.render(document);
  for (final name in sections) {
    if (result.anchors[name] case final at?) {
      document.addOutline(
        name,
        LinkTarget.destination(PdfDestination.fit(pages[at.page])),
      );
    }
  }
  File(args.isEmpty ? 'report.pdf' : args.first)
      .writeAsBytesSync(document.save());
}

TableCell _cell(String text, PdfTextStyle style, {PdfColor? background}) =>
    TableCell(
      [
        ParagraphBox(Paragraph([TextRun(text, style)])),
      ],
      background: background,
      border: const Border(widths: EdgeInsets.all(0.5)),
    );

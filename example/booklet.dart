// A two-column booklet: A5 pages with two columns, page numbers on the
// outer edge, and a different first page.
//
//   dart run example/booklet.dart booklet.pdf
import 'dart:io';

import 'package:libpdf/libpdf.dart';

void main(List<String> args) {
  final body = PdfTextStyle(StandardFont.timesRoman, 9.5);
  final title = PdfTextStyle(StandardFont.named('Times-Bold'), 22);
  final small = PdfTextStyle(StandardFont.helvetica, 7);
  const text =
      'A booklet sets its text in narrow columns, which keeps lines short '
      'enough to read easily at a small size; the columns fill one after '
      'the other, and the text runs on to the next page.';
  const size = PdfRect(0, 0, 420, 595);
  const margins = EdgeInsets.symmetric(vertical: 48, horizontal: 36);
  final layout = FlowLayout(
    templates: {
      null: PageTemplate(
        size,
        margins: margins,
        columns: 2,
        columnGap: 14,
        footer: (page) => [
          const SpacerBox(20),
          ParagraphBox(
            Paragraph([
              TextRun('${page.number}', small),
            ], align: page.number.isOdd ? TextAlign.right : TextAlign.left),
          ),
        ],
      ),
      'title': const PageTemplate(size, margins: margins),
    },
    startTemplate: 'title',
  );
  final result = layout.layout([
    ParagraphBox(
      Paragraph([TextRun('The Booklet', title)], align: TextAlign.center),
      style: const BoxStyle(margin: EdgeInsets(top: 180)),
    ),
    const BreakBox.page(),
    for (var p = 0; p < 40; p++)
      ParagraphBox(
        Paragraph(
          [TextRun(text, body)],
          align: TextAlign.justify,
          firstLineIndent: 10,
        ),
        lineBreaker: const KnuthPlassLineBreaker(),
      ),
  ]);
  final document = PdfDocument();
  result.render(document);
  File(args.isEmpty ? 'booklet.pdf' : args.first)
      .writeAsBytesSync(document.save());
}

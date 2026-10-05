import 'dart:io';

import 'package:libpdf/libpdf.dart';

void main() {
  final document = PdfDocument(info: const PdfInfo(title: 'Hello'));
  final page = document.addPage(const PdfRect(0, 0, 595, 842)); // A4
  final style = PdfTextStyle(StandardFont.helvetica, 24);
  page.canvas
    ..setFillColor(PdfColor.hex('#1565c0'))
    ..roundedRect(const PdfRect(72, 700, 451, 60), 8)
    ..fill()
    ..setFillColor(const PdfColor.gray(1))
    ..text('Hello, PDF', 90, 722, style);
  page.link(
    const PdfRect(72, 700, 451, 60),
    const LinkTarget.uri('https://example.org/'),
  );
  File('hello.pdf').writeAsBytesSync(document.save());
}

# libpdf

A pure-Dart PDF library written from the specification (ISO 32000-2,
PDF 2.0; output stays readable by PDF 1.7 readers by declaring the lowest
version a document needs). It runs wherever Dart runs, including the web:
no native code, and no dependencies beyond the Dart team's packages.

Layers, each public and usable alone:

1. **Objects and writer.** The COS object model as sealed types, a writer
   with Flate compression (pure Dart), cross-reference tables or streams,
   object streams, document information, and a deterministic mode (fixed
   identifiers and dates) for reproducible output and golden tests.
2. **Drawing.** Content streams through a typed graphics API: paths,
   colors, transforms, clipping, transparency; text with embedded fonts;
   images; links, destinations, outlines and page labels.
3. **Layout.** A typed box tree is measured, broken into lines and pages,
   and painted. Line breaking and page breaking are pluggable strategies:
   libpdf ships defaults (first fit, Knuth-Plass), and callers can supply
   their own to reproduce another engine's behavior.
4. **Reading.** `PdfFile.parse` reads a PDF file's objects and pages
   (cross-reference tables and streams, object streams, damaged files
   rebuilt by scanning); its pages can be painted into another document.

Fonts: the 14 standard fonts with their metrics and kerning, and OpenType
fonts (TrueType and CFF outlines, or the WOFF and WOFF2 web fonts that wrap
them) embedded as subsets, with kerning, `liga` ligatures and a ToUnicode
map so text stays extractable. Reading and subsetting fonts is the
[fonts](https://github.com/nsmmrs/fonts) package's work, and compression
the [compression](https://github.com/nsmmrs/compression) package's. Images: JPEG,
PNG of every kind, and SVG (drawn as vector graphics).

The examples in [`example/`](example) make a one-page hello world, a
styled report, an SVG chart and a two-column booklet.

```dart
import 'dart:io';

import 'package:libpdf/libpdf.dart';

void main(List<String> args) {
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
  File(args.isEmpty ? 'hello.pdf' : args.first)
      .writeAsBytesSync(document.save());
}
```

Status: in development; not published to pub.dev. See
[`adr/0001-layered-design.md`](adr/0001-layered-design.md) for the design.

## License

MIT; see [LICENSE](LICENSE).

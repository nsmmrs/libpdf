// An SVG bar chart drawn as vector graphics on a page.
//
//   dart run example/svg_chart.dart chart.pdf
import 'dart:io';

import 'package:libpdf/libpdf.dart';

void main(List<String> args) {
  const values = [12, 19, 7, 15, 22, 9];
  final bars = StringBuffer();
  for (final (i, v) in values.indexed) {
    final x = 40 + i * 50;
    final h = v * 8;
    bars
      ..write('<rect x="$x" y="${220 - h}" width="34" height="$h" ')
      ..write('fill="url(#bar)" rx="3"/>')
      ..write(
        '<text x="${x + 17}" y="236" text-anchor="middle">Q${i + 1}</text>',
      );
  }
  final svg = SvgImage.parse('''
<svg xmlns="http://www.w3.org/2000/svg" width="360" height="250"
     font-family="sans-serif" font-size="11">
  <defs>
    <linearGradient id="bar" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#42a5f5"/>
      <stop offset="1" stop-color="#0d47a1"/>
    </linearGradient>
  </defs>
  <line x1="30" y1="220" x2="350" y2="220" stroke="#333"/>
  $bars
  <text x="180" y="20" text-anchor="middle" font-size="14" font-weight="bold">Sales</text>
</svg>''');
  final document = PdfDocument();
  final page = document.addPage(const PdfRect(0, 0, 595, 842));
  svg.draw(page.canvas, PdfRect(117, 500, svg.width * 1.5, svg.height * 1.5));
  File(args.isEmpty ? 'chart.pdf' : args.first)
      .writeAsBytesSync(document.save());
}

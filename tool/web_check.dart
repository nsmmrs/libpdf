// Compiles the library to JavaScript in CI and writes a deterministic PDF:
// nothing in the library may depend on dart:io, and the output must be
// the same bytes on the VM and on JavaScript (the CI job compares the
// digest it prints with the VM's).
import 'dart:convert';
import 'dart:typed_data';

import 'package:libpdf/libpdf.dart';

void main() {
  final out = BytesBuilder(copy: false);
  final writer = PdfWriter(
    out.add,
    options: const PdfWriterOptions(deterministic: true),
  );
  final catalog = writer.reserve();
  final pages = writer.reserve();
  final content = writer.write(
    PdfStream(latin1.encode('BT /F1 12 Tf 72 720 Td (${'web ' * 400}) Tj ET')),
  );
  final page = writer.write(
    PdfDict({
      'Type': const PdfName('Page'),
      'Parent': pages,
      'MediaBox': PdfArray.numbers([0, 0, 612, 792]),
      'Contents': content,
    }),
  );
  writer
    ..write(
      PdfDict({
        'Type': const PdfName('Pages'),
        'Kids': PdfArray([page]),
        'Count': const PdfInt(1),
      }),
      pages,
    )
    ..write(
      PdfDict({'Type': const PdfName('Catalog'), 'Pages': pages}),
      catalog,
    )
    ..close(root: catalog);
  final pdf = out.takeBytes();
  final digest = [for (final b in md5(pdf)) b.toRadixString(16).padLeft(2, '0')]
      .join();
  // The digest is the program's output.
  // ignore: avoid_print
  print('${pdf.length} $digest');
}

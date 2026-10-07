import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:libpdf/libpdf.dart';
import 'package:libpdf/src/writer.dart' show xmpPacket;
import 'package:test/test.dart';

/// A one-page document with [text] in Helvetica, written with [options].
Uint8List helloPdf(PdfWriterOptions options, {String text = 'Hello, PDF'}) {
  final out = BytesBuilder(copy: false);
  final writer = PdfWriter(out.add, options: options);
  final catalog = writer.reserve();
  final pages = writer.reserve();
  final font = writer.write(
    PdfDict({
      'Type': const PdfName('Font'),
      'Subtype': const PdfName('Type1'),
      'BaseFont': const PdfName('Helvetica'),
      'Encoding': const PdfName('WinAnsiEncoding'),
    }),
  );
  final content = writer.write(
    PdfStream(latin1.encode('BT /F1 24 Tf 72 720 Td ($text) Tj ET')),
  );
  final page = writer.write(
    PdfDict({
      'Type': const PdfName('Page'),
      'Parent': pages,
      'MediaBox': PdfArray.numbers([0, 0, 612, 792]),
      'Resources': PdfDict({
        'Font': PdfDict({'F1': font}),
      }),
      'Contents': content,
    }),
  );
  writer.write(
    PdfDict({
      'Type': const PdfName('Pages'),
      'Kids': PdfArray([page]),
      'Count': const PdfInt(1),
    }),
    pages,
  );
  final info = writer.writeInfo(
    const PdfInfo(title: 'Hello', author: 'libpdf', producer: 'libpdf'),
  );
  writer
    ..write(
      PdfDict({
        'Type': const PdfName('Catalog'),
        'Pages': pages,
        'Metadata': info.metadata,
      }),
      catalog,
    )
    ..close(root: catalog, info: info.info);
  return out.takeBytes();
}

bool get _hasQpdf =>
    Process.runSync('which', ['qpdf']).exitCode == 0 &&
    Process.runSync('which', ['pdftotext']).exitCode == 0;

void main() {
  final modes = {
    'xref table, uncompressed': const PdfWriterOptions(
      compact: false,
      compress: false,
    ),
    'xref table, compressed': const PdfWriterOptions(compact: false),
    'xref and object streams': const PdfWriterOptions(),
  };

  for (final MapEntry(key: name, value: options) in modes.entries) {
    test(
      '$name: qpdf finds no errors and the text extracts',
      () {
        final dir = Directory.systemTemp.createTempSync('libpdf.');
        addTearDown(() => dir.deleteSync(recursive: true));
        final file = File('${dir.path}/hello.pdf')
          ..writeAsBytesSync(helloPdf(options));
        final check = Process.runSync('qpdf', ['--check', file.path]);
        expect(check.exitCode, 0, reason: '${check.stdout}${check.stderr}');
        expect(
          '${check.stdout}',
          contains('No syntax or stream encoding errors found'),
        );
        final text = Process.runSync('pdftotext', [file.path, '-']);
        expect('${text.stdout}'.trim(), 'Hello, PDF');
        final info = Process.runSync('pdfinfo', [file.path]);
        expect('${info.stdout}', matches(RegExp(r'Title:\s+Hello')));
      },
      tags: ['pdf-tools'],
      skip: _hasQpdf ? false : 'qpdf or poppler missing',
    );
  }

  test('deterministic output is stable and matches the golden file', () {
    const options = PdfWriterOptions(deterministic: true);
    final a = helloPdf(options);
    final b = helloPdf(options);
    expect(a, b);
    final golden = File('test/golden/hello.pdf');
    if (!golden.existsSync() || Platform.environment['UPDATE_GOLDEN'] == '1') {
      golden
        ..createSync(recursive: true)
        ..writeAsBytesSync(a);
    }
    expect(a, golden.readAsBytesSync());
  });

  test('different content gets a different file identifier', () {
    const options = PdfWriterOptions(deterministic: true);
    String id(Uint8List pdf) =>
        RegExp(r'/ID \[<([0-9A-F]+)>').firstMatch(latin1.decode(pdf))![1]!;
    expect(id(helloPdf(options)), isNot(id(helloPdf(options, text: 'Other'))));
  });

  test('a reserved object must be written', () {
    final writer = PdfWriter((_) {});
    final root = writer.reserve();
    writer
      ..reserve()
      ..write(PdfDict(), root);
    expect(() => writer.close(root: root), throwsStateError);
  });

  test('XMP metadata: an identifier, contributors and rights', () {
    final xmp = xmpPacket(
      const PdfInfo(
        title: 'Book',
        identifier: 'urn:isbn:9780000000000',
        contributors: ['Ed One', 'Ed & Two'],
        rights: '© 2026 Ann',
      ),
      DateTime.utc(2026),
    );
    expect(
      xmp,
      contains('<dc:identifier>urn:isbn:9780000000000</dc:identifier>'),
    );
    expect(
      xmp,
      contains(
        '<dc:contributor><rdf:Bag><rdf:li>Ed One</rdf:li><rdf:li>Ed &amp; '
        'Two</rdf:li></rdf:Bag></dc:contributor>',
      ),
    );
    expect(xmp, contains('<rdf:li xml:lang="x-default">© 2026 Ann</rdf:li>'));
    // Without them, nothing.
    expect(
      xmpPacket(const PdfInfo(title: 'Book'), DateTime.utc(2026)),
      isNot(contains('dc:identifier')),
    );
  });

  test('PDF dates', () {
    expect(
      pdfDate(DateTime.utc(2026, 10, 5, 13, 4, 5)),
      "D:20261005130405+00'00'",
    );
  });
}

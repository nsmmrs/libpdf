/// Writes a PDF file (ISO 32000-2, 7.5): the header, indirect objects,
/// the cross-reference section (a table, or a stream with object streams)
/// and the trailer, streaming to a sink as objects are added.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:libpdf/src/flate.dart';
import 'package:libpdf/src/md5.dart';
import 'package:libpdf/src/objects.dart';

/// How a file is written.
final class PdfWriterOptions {
  /// Options: compress streams, and use cross-reference and object
  /// streams (PDF 1.5) unless [compact] is false.
  const new({
    this.compress = true,
    this.compact = true,
    this.deterministic = false,
    this.creationDate,
    this.compressionLevel = 6,
  });

  /// Whether stream data is compressed with Flate.
  final bool compress;

  /// Whether non-stream objects go into object streams and the
  /// cross-reference section is a stream (smaller files, PDF 1.5);
  /// otherwise a cross-reference table (any version).
  final bool compact;

  /// Whether the output is the same for the same content: the file
  /// identifier is derived from the content, and dates come from
  /// [creationDate] (or the epoch).
  final bool deterministic;

  /// The date written as the creation and modification date.
  final DateTime? creationDate;

  /// The Flate level (1–9).
  final int compressionLevel;
}

/// Document information (ISO 32000-2, 14.3.3), also written as XMP
/// metadata.
final class PdfInfo {
  /// Information about a document.
  const new({
    this.title,
    this.author,
    this.subject,
    this.keywords,
    this.creator,
    this.producer,
    this.trapped,
    this.pdfxVersion,
  });

  /// The title.
  final String? title;

  /// The author.
  final String? author;

  /// The subject.
  final String? subject;

  /// Keywords.
  final String? keywords;

  /// The application that created the original document.
  final String? creator;

  /// The application that produced the PDF.
  final String? producer;

  /// Whether the document has been trapped for print (`/Trapped`), when
  /// known; PDF/X requires it.
  final bool? trapped;

  /// The PDF/X version the document conforms to (`PDF/X-4`), written as
  /// `GTS_PDFXVersion` in the information and the XMP metadata.
  final String? pdfxVersion;
}

/// Writes a PDF file to a sink.
///
/// Reserve references with [reserve], write objects with [write] (in any
/// order), then [close] with the catalog. Streams are written to the sink
/// at once; other objects are held only until their object stream fills
/// (or written at once without `PdfWriterOptions.compact`).
final class PdfWriter {
  /// A writer to the sink with [options], declaring [version] (the writer
  /// raises it to 1.5 when it uses object or cross-reference streams).
  new(
    this._sink, {
    this.options = const PdfWriterOptions(),
    String version = '1.4',
  }) : _version = options.compact && _compare(version, '1.5') < 0
           ? '1.5'
           : version {
    _emit(ascii.encode('%PDF-$_version\n'));
    // A comment with high bytes marks the file as binary.
    _emit([0x25, 0xe2, 0xe3, 0xcf, 0xd3, 0x0a]);
  }

  final void Function(List<int> bytes) _sink;

  /// How the file is written.
  final PdfWriterOptions options;

  final String _version;
  int _offset = 0;
  int _nextNumber = 1;

  /// Where each object is: a byte offset, or (object stream, index).
  final Map<int, _Location> _locations = {};

  /// Objects waiting for an object stream.
  final List<(int, PdfObject)> _pending = [];

  /// The digest input in deterministic mode (the bytes written).
  final BytesBuilder _digest = BytesBuilder();

  void _emit(List<int> bytes) {
    _sink(bytes);
    _offset += bytes.length;
    if (options.deterministic) _digest.add(bytes);
  }

  /// A reference for an object to write later.
  PdfRef reserve() => PdfRef(_nextNumber++);

  /// Writes [object] as [ref] (default: a new reference); returns the
  /// reference.
  PdfRef write(PdfObject object, [PdfRef? ref]) {
    final target = ref ?? reserve();
    if (_locations.containsKey(target.number) ||
        _pending.any((p) => p.$1 == target.number)) {
      throw StateError('object ${target.number} is already written');
    }
    if (object is PdfStream || !options.compact) {
      _writeIndirect(target.number, object);
    } else {
      _pending.add((target.number, object));
      if (_pending.length >= 100) _flushObjectStream();
    }
    return target;
  }

  void _writeIndirect(int number, PdfObject object) {
    _locations[number] = _Offset(_offset);
    final out = BytesBuilder()..add(ascii.encode('$number 0 obj\n'));
    _encode(object).writeTo(out);
    out.add(ascii.encode('\nendobj\n'));
    _emit(out.takeBytes());
  }

  /// [object] with stream data compressed, when it should be.
  PdfObject _encode(PdfObject object) {
    if (object is! PdfStream ||
        !options.compress ||
        !object.compress ||
        object.dict['Filter'] != null) {
      return object;
    }
    final compressed = zlibEncode(object.data, level: options.compressionLevel);
    if (compressed.length >= object.data.length) return object;
    return PdfStream(
      compressed,
      dict: PdfDict({
        ...object.dict.entries,
        'Filter': const PdfName('FlateDecode'),
      }),
      compress: false,
    );
  }

  void _flushObjectStream() {
    if (_pending.isEmpty) return;
    final number = _nextNumber++;
    final offsets = BytesBuilder();
    final body = BytesBuilder();
    for (var i = 0; i < _pending.length; i++) {
      final (objectNumber, object) = _pending[i];
      offsets.add(ascii.encode('$objectNumber ${body.length} '));
      object.writeTo(body);
      body.addByte(0x0a);
      _locations[objectNumber] = _InStream(number, i);
    }
    final header = offsets.takeBytes();
    final stream = PdfStream(
      [...header, ...body.takeBytes()],
      dict: PdfDict({
        'Type': const PdfName('ObjStm'),
        'N': PdfInt(_pending.length),
        'First': PdfInt(header.length),
      }),
    );
    _pending.clear();
    _writeIndirect(number, stream);
  }

  /// Writes document information and XMP metadata for [info]; returns the
  /// references (`/Info` for the trailer, `/Metadata` for the catalog).
  ({PdfRef info, PdfRef metadata}) writeInfo(PdfInfo info) {
    final date =
        options.creationDate ??
        (options.deterministic ? DateTime.utc(1970) : DateTime.now().toUtc());
    final dict = PdfDict({
      if (info.title case final title?) 'Title': PdfString.text(title),
      if (info.author case final author?) 'Author': PdfString.text(author),
      if (info.subject case final subject?) 'Subject': PdfString.text(subject),
      if (info.keywords case final keywords?)
        'Keywords': PdfString.text(keywords),
      if (info.creator case final creator?) 'Creator': PdfString.text(creator),
      if (info.producer case final producer?)
        'Producer': PdfString.text(producer),
      'CreationDate': PdfString(ascii.encode(pdfDate(date))),
      'ModDate': PdfString(ascii.encode(pdfDate(date))),
      if (info.trapped case final trapped?)
        'Trapped': PdfName(trapped ? 'True' : 'False'),
      if (info.pdfxVersion case final version?)
        'GTS_PDFXVersion': PdfString.text(version),
    });
    final metadata = PdfStream(
      utf8.encode(xmpPacket(info, date)),
      dict: PdfDict({
        'Type': const PdfName('Metadata'),
        'Subtype': const PdfName('XML'),
      }),
      compress: false,
    );
    return (info: write(dict), metadata: write(metadata));
  }

  /// Finishes the file: the cross-reference section and the trailer with
  /// [root] (the catalog) and [info].
  void close({required PdfRef root, PdfRef? info}) {
    _flushObjectStream();
    for (var number = 1; number < _nextNumber; number++) {
      if (!_locations.containsKey(number)) {
        throw StateError('object $number was reserved but never written');
      }
    }
    final id = _fileId();
    if (options.compact) {
      _writeXrefStream(root, info, id);
    } else {
      _writeXrefTable(root, info, id);
    }
  }

  PdfArray _fileIdArray(Uint8List id) =>
      PdfArray([PdfString(id, hex: true), PdfString(id, hex: true)]);

  Uint8List _fileId() {
    if (options.deterministic) return md5(_digest.toBytes());
    final seed = utf8.encode(
      '${DateTime.now().microsecondsSinceEpoch} $_offset $_nextNumber',
    );
    return md5(seed);
  }

  void _writeXrefTable(PdfRef root, PdfRef? info, Uint8List id) {
    final start = _offset;
    final out = StringBuffer('xref\n0 $_nextNumber\n0000000000 65535 f\r\n');
    for (var number = 1; number < _nextNumber; number++) {
      final location = _locations[number]! as _Offset;
      out.write('${location.offset.toString().padLeft(10, '0')} 00000 n\r\n');
    }
    out.write('trailer\n');
    _emit(ascii.encode(out.toString()));
    final trailer = BytesBuilder();
    PdfDict({
      'Size': PdfInt(_nextNumber),
      'Root': root,
      'Info': ?info,
      'ID': _fileIdArray(id),
    }).writeTo(trailer);
    _emit(trailer.takeBytes());
    _emit(ascii.encode('\nstartxref\n$start\n%%EOF\n'));
  }

  void _writeXrefStream(PdfRef root, PdfRef? info, Uint8List id) {
    final number = _nextNumber++;
    final start = _offset;
    _locations[number] = _Offset(start);
    final widthOffset = _bytesFor(start);
    final rows = BytesBuilder();
    void row(int type, int field2, int field3) {
      rows.addByte(type);
      for (var k = widthOffset - 1; k >= 0; k--) {
        rows.addByte((field2 >> (8 * k)) & 0xff);
      }
      rows
        ..addByte((field3 >> 8) & 0xff)
        ..addByte(field3 & 0xff);
    }

    row(0, 0, 0xffff);
    for (var n = 1; n < _nextNumber; n++) {
      switch (_locations[n]!) {
        case _Offset(:final offset):
          row(1, offset, 0);
        case _InStream(:final stream, :final index):
          row(2, stream, index);
      }
    }
    final stream = PdfStream(
      rows.takeBytes(),
      dict: PdfDict({
        'Type': const PdfName('XRef'),
        'Size': PdfInt(_nextNumber),
        'W': PdfArray.numbers([1, widthOffset, 2]),
        'Root': root,
        'Info': ?info,
        'ID': _fileIdArray(id),
      }),
    );
    final out = BytesBuilder()..add(ascii.encode('$number 0 obj\n'));
    _encode(stream).writeTo(out);
    out.add(ascii.encode('\nendobj\nstartxref\n$start\n%%EOF\n'));
    _emit(out.takeBytes());
  }

  static int _bytesFor(int value) {
    var bytes = 1;
    while (value >= (1 << (8 * bytes))) {
      bytes += 1;
    }
    return bytes;
  }

  static int _compare(String a, String b) {
    final x = a.split('.').map(int.parse).toList();
    final y = b.split('.').map(int.parse).toList();
    return x[0] != y[0] ? x[0] - y[0] : x[1] - y[1];
  }
}

sealed class _Location {
  const new();
}

final class _Offset extends _Location {
  const new(this.offset);

  final int offset;
}

final class _InStream extends _Location {
  const new(this.stream, this.index);

  final int stream;
  final int index;
}

/// [date] as a PDF date string (ISO 32000-2, 7.9.4), in UTC.
String pdfDate(DateTime date) {
  final d = date.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  return "D:${d.year.toString().padLeft(4, '0')}${two(d.month)}${two(d.day)}"
      "${two(d.hour)}${two(d.minute)}${two(d.second)}+00'00'";
}

/// An XMP metadata packet (ISO 32000-2, 14.3.2) with [info] and [date].
String xmpPacket(PdfInfo info, DateTime date) {
  final iso = '${date.toUtc().toIso8601String().split('.').first}Z';
  String escape(String text) => text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
  final out = StringBuffer()
    ..write('<?xpacket begin="\u{feff}" id="W5M0MpCehiHzreSzNTczkc9d"?>\n')
    ..write('<x:xmpmeta xmlns:x="adobe:ns:meta/">\n')
    ..write(
      '<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\n',
    )
    ..write('<rdf:Description rdf:about=""\n')
    ..write(' xmlns:dc="http://purl.org/dc/elements/1.1/"\n')
    ..write(' xmlns:xmp="http://ns.adobe.com/xap/1.0/"\n')
    ..write(' xmlns:pdf="http://ns.adobe.com/pdf/1.3/"')
    ..write(
      info.pdfxVersion == null
          ? '>\n'
          : '\n xmlns:pdfxid="http://www.npes.org/pdfx/ns/id/">\n',
    );
  if (info.pdfxVersion case final version?) {
    out.write(
      '<pdfxid:GTS_PDFXVersion>${escape(version)}</pdfxid:GTS_PDFXVersion>\n',
    );
  }
  if (info.trapped case final trapped?) {
    out.write('<pdf:Trapped>${trapped ? 'True' : 'False'}</pdf:Trapped>\n');
  }
  if (info.title case final title?) {
    out.write(
      '<dc:title><rdf:Alt><rdf:li xml:lang="x-default">${escape(title)}'
      '</rdf:li></rdf:Alt></dc:title>\n',
    );
  }
  if (info.author case final author?) {
    out.write(
      '<dc:creator><rdf:Seq><rdf:li>${escape(author)}</rdf:li></rdf:Seq>'
      '</dc:creator>\n',
    );
  }
  if (info.subject case final subject?) {
    out.write(
      '<dc:description><rdf:Alt><rdf:li xml:lang="x-default">'
      '${escape(subject)}</rdf:li></rdf:Alt></dc:description>\n',
    );
  }
  if (info.keywords case final keywords?) {
    out.write('<pdf:Keywords>${escape(keywords)}</pdf:Keywords>\n');
  }
  if (info.producer case final producer?) {
    out.write('<pdf:Producer>${escape(producer)}</pdf:Producer>\n');
  }
  if (info.creator case final creator?) {
    out.write('<xmp:CreatorTool>${escape(creator)}</xmp:CreatorTool>\n');
  }
  out
    ..write('<xmp:CreateDate>$iso</xmp:CreateDate>\n')
    ..write('<xmp:ModifyDate>$iso</xmp:ModifyDate>\n')
    ..write('</rdf:Description>\n</rdf:RDF>\n</x:xmpmeta>\n')
    ..write('<?xpacket end="w"?>');
  return out.toString();
}

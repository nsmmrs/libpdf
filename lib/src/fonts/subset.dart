/// Subsetting TrueType fonts for embedding: the glyphs a document uses
/// (with the glyphs composite glyphs are made of) keep their outlines and
/// their glyph ids; the others are emptied, so the font program shrinks
/// while text keeps addressing glyphs by id (CID = GID).
library;

import 'dart:typed_data';

import 'package:libpdf/src/fonts/opentype.dart';

/// The glyphs to keep for [used]: `.notdef`, [used], and the components
/// of composite glyphs, recursively.
Set<int> glyphClosure(OpenTypeFont font, Iterable<int> used) {
  final keep = <int>{0};
  final queue = [...used];
  while (queue.isNotEmpty) {
    final glyph = queue.removeLast();
    if (glyph < 0 || glyph >= font.numGlyphs || !keep.add(glyph)) continue;
    queue.addAll(font.components(glyph));
  }
  return keep;
}

/// The tables of a subset TrueType font program.
const List<String> _keptTables = [
  'cvt ', 'fpgm', 'glyf', 'head', 'hhea', 'hmtx', 'loca', 'maxp', 'prep', //
];

/// A TrueType font program with only [glyphs]' outlines (glyph ids kept);
/// without the `cmap`, `name`, `post` and layout tables, which a PDF
/// reader doesn't use for a CID font addressed by glyph id.
Uint8List subsetTrueType(OpenTypeFont font, Set<int> glyphs) {
  if (!font.isTrueType) {
    throw const FontFormatException('only TrueType outlines can be subset');
  }
  final glyf = BytesBuilder(copy: false);
  final loca = ByteData(4 * (font.numGlyphs + 1));
  for (var g = 0; g < font.numGlyphs; g++) {
    loca.setUint32(4 * g, glyf.length);
    if (glyphs.contains(g)) {
      final data = font.glyphData(g);
      glyf.add(data);
      // Keep every glyph 4-byte aligned.
      for (var pad = data.length % 4; pad != 0 && pad < 4; pad++) {
        glyf.addByte(0);
      }
    }
  }
  loca.setUint32(4 * font.numGlyphs, glyf.length);

  final head = Uint8List.fromList(font.table('head')!);
  final headView = ByteData.sublistView(head)
    ..setUint32(8, 0) // checkSumAdjustment, set below
    ..setInt16(50, 1); // long loca offsets

  final tables = <String, Uint8List>{
    for (final tag in _keptTables) tag: ?font.table(tag),
    'glyf': glyf.takeBytes(),
    'loca': loca.buffer.asUint8List(),
    'head': head,
  };
  final file = _assemble(tables);
  headView.setUint32(8, (0xb1b0afba - _checksum(file)) & 0xffffffff);
  return _assemble(tables);
}

/// A font file with [tables] (sorted by tag) and a table directory.
Uint8List _assemble(Map<String, Uint8List> tables) {
  final tags = tables.keys.toList()..sort();
  final count = tags.length;
  var entrySelector = 0;
  while (1 << (entrySelector + 1) <= count) {
    entrySelector += 1;
  }
  final searchRange = (1 << entrySelector) * 16;
  final header = ByteData(12 + 16 * count)
    ..setUint32(0, 0x00010000)
    ..setUint16(4, count)
    ..setUint16(6, searchRange)
    ..setUint16(8, entrySelector)
    ..setUint16(10, count * 16 - searchRange);
  final body = BytesBuilder(copy: false);
  var offset = 12 + 16 * count;
  for (var i = 0; i < count; i++) {
    final data = tables[tags[i]]!;
    final record = 12 + 16 * i;
    for (var k = 0; k < 4; k++) {
      header.setUint8(record + k, tags[i].codeUnitAt(k));
    }
    header
      ..setUint32(record + 4, _checksum(data))
      ..setUint32(record + 8, offset)
      ..setUint32(record + 12, data.length);
    body.add(data);
    final padding = (4 - data.length % 4) % 4;
    for (var k = 0; k < padding; k++) {
      body.addByte(0);
    }
    offset += data.length + padding;
  }
  return (BytesBuilder(copy: false)
        ..add(header.buffer.asUint8List())
        ..add(body.takeBytes()))
      .takeBytes();
}

int _checksum(List<int> data) {
  var sum = 0;
  for (var i = 0; i < data.length; i += 4) {
    var word = 0;
    for (var k = 0; k < 4; k++) {
      word = (word << 8) | (i + k < data.length ? data[i + k] : 0);
    }
    sum = (sum + word) & 0xffffffff;
  }
  return sum;
}

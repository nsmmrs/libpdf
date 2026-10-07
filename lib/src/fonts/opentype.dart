/// Reading TrueType and OpenType fonts (the OpenType specification 1.9):
/// the tables a PDF writer needs for metrics, character mapping, glyph
/// outlines (for subsetting), kerning and ligatures.
library;

import 'dart:convert';
import 'dart:typed_data';

/// A font file that could not be read.
final class FontFormatException implements Exception {
  /// An exception with [message].
  const new(this.message);

  /// What is wrong with the font.
  final String message;

  @override
  String toString() => 'FontFormatException: $message';
}

/// Big-endian reads from font data.
final class _Data {
  new(this.bytes) : _view = ByteData.sublistView(bytes);

  final Uint8List bytes;
  final ByteData _view;

  int u8(int at) {
    _check(at, 1);
    return _view.getUint8(at);
  }

  int u16(int at) {
    _check(at, 2);
    return _view.getUint16(at);
  }

  int i16(int at) {
    _check(at, 2);
    return _view.getInt16(at);
  }

  int u32(int at) {
    _check(at, 4);
    return _view.getUint32(at);
  }

  int i32(int at) {
    _check(at, 4);
    return _view.getInt32(at);
  }

  String tag(int at) {
    _check(at, 4);
    return latin1.decode(bytes.sublist(at, at + 4));
  }

  /// The [length] bytes at [at].
  Uint8List slice(int at, int length) {
    _check(at, length);
    return Uint8List.sublistView(bytes, at, at + length);
  }

  /// A 16.16 fixed-point number.
  double fixed(int at) => i32(at) / 65536;

  void _check(int at, int length) {
    if (at < 0 || at + length > bytes.length) {
      throw FontFormatException('read past the end of the font at $at');
    }
  }
}

/// A table record of the font's table directory.
final class _Table {
  const new(this.offset, this.length);

  final int offset;
  final int length;
}

/// A TrueType or OpenType font.
final class OpenTypeFont {
  new _(this.bytes, this._data, this._tables) {
    _readHead();
    _readHhea();
    numGlyphs = _data.u16(_require('maxp').offset + 4);
    _readHmtx();
    _readOs2();
    _readPost();
    _readNames();
  }

  /// Reads the font in [bytes]; for a font collection (`.ttc`), the font
  /// at [index].
  factory parse(List<int> bytes, {int index = 0}) {
    final data = _Data(bytes is Uint8List ? bytes : Uint8List.fromList(bytes));
    var directory = 0;
    if (data.bytes.length >= 12 && data.tag(0) == 'ttcf') {
      final count = data.u32(8);
      if (index < 0 || index >= count) {
        throw FontFormatException('the collection has no font $index');
      }
      directory = data.u32(12 + 4 * index);
    }
    final version = data.u32(directory);
    if (version != 0x00010000 &&
        version != 0x4f54544f && // OTTO
        version != 0x74727565) {
      // true
      throw const FontFormatException('not a TrueType or OpenType font');
    }
    final numTables = data.u16(directory + 4);
    final tables = <String, _Table>{};
    for (var i = 0; i < numTables; i++) {
      final record = directory + 12 + 16 * i;
      tables[data.tag(record)] = _Table(
        data.u32(record + 8),
        data.u32(record + 12),
      );
    }
    return OpenTypeFont._(data.bytes, data, tables);
  }

  /// The number of fonts in the collection in [bytes] (1 for a font).
  static int fontCount(List<int> bytes) {
    final data = _Data(bytes is Uint8List ? bytes : Uint8List.fromList(bytes));
    return data.bytes.length >= 12 && data.tag(0) == 'ttcf' ? data.u32(8) : 1;
  }

  /// The font file.
  final Uint8List bytes;
  final _Data _data;
  final Map<String, _Table> _tables;

  /// Whether the font has [tag] (`glyf`, `CFF `...).
  bool hasTable(String tag) => _tables.containsKey(tag);

  /// The bytes of table [tag], or `null`.
  Uint8List? table(String tag) {
    final t = _tables[tag];
    return t == null ? null : _data.slice(t.offset, t.length);
  }

  /// The table tags, in the directory's order.
  Iterable<String> get tableTags => _tables.keys;

  _Table _require(String tag) =>
      _tables[tag] ?? (throw FontFormatException('the font has no $tag table'));

  /// Whether the outlines are TrueType (`glyf`) rather than CFF.
  bool get isTrueType => hasTable('glyf');

  /// Font units per em.
  late final int unitsPerEm;

  /// The bounding box of all glyphs: xMin, yMin, xMax, yMax.
  late final List<int> bbox;

  /// 0 for short `loca` offsets, 1 for long.
  late final int indexToLocFormat;

  /// Typographic metrics (`hhea`, or `OS/2` when it has them).
  late final int ascender;

  /// The descender (negative below the baseline).
  late final int descender;

  /// The line gap.
  late final int lineGap;

  late final int _numberOfHMetrics;

  /// The number of glyphs.
  late final int numGlyphs;

  late final Uint16List _advances;

  /// The height of capital letters, when the font says.
  int? capHeight;

  /// The `OS/2` typographic ascender (`sTypoAscender`), if any.
  int? typoAscender;

  /// The `OS/2` typographic descender (`sTypoDescender`), if any.
  int? typoDescender;

  /// The `OS/2` typographic line gap (`sTypoLineGap`), if any.
  int? typoLineGap;

  /// The height of lowercase letters, when the font says.
  int? xHeight;

  /// The weight class (400 regular, 700 bold).
  int weightClass = 400;

  /// The `OS/2` embedding permissions (`fsType`).
  int fsType = 0;

  /// The italic angle, in degrees.
  double italicAngle = 0;

  /// Whether every glyph has the same width.
  bool isFixedPitch = false;

  /// The top of the underline, in font units (negative: below the
  /// baseline), from `post`.
  int? underlinePosition;

  /// The underline's thickness, in font units, from `post`.
  int? underlineThickness;

  /// The PostScript name.
  String postScriptName = 'Font';

  /// The family name.
  String? familyName;

  /// Whether the font's license forbids embedding it (`fsType` bit 1,
  /// "restricted license embedding").
  bool get embeddingRestricted => fsType & 0x000f == 0x0002;

  void _readHead() {
    final at = _require('head').offset;
    unitsPerEm = _data.u16(at + 18);
    bbox = [
      _data.i16(at + 36),
      _data.i16(at + 38),
      _data.i16(at + 40),
      _data.i16(at + 42),
    ];
    indexToLocFormat = _data.i16(at + 50);
  }

  void _readHhea() {
    final at = _require('hhea').offset;
    ascender = _data.i16(at + 4);
    descender = _data.i16(at + 6);
    lineGap = _data.i16(at + 8);
    _numberOfHMetrics = _data.u16(at + 34);
  }

  void _readHmtx() {
    final at = _require('hmtx').offset;
    _advances = Uint16List(numGlyphs);
    var last = 0;
    for (var g = 0; g < numGlyphs; g++) {
      if (g < _numberOfHMetrics) last = _data.u16(at + 4 * g);
      _advances[g] = last;
    }
  }

  void _readOs2() {
    final t = _tables['OS/2'];
    if (t == null) return;
    final at = t.offset;
    final version = _data.u16(at);
    weightClass = _data.u16(at + 4);
    fsType = _data.u16(at + 8);
    if (t.length >= 74) {
      typoAscender = _data.i16(at + 68);
      typoDescender = _data.i16(at + 70);
      typoLineGap = _data.i16(at + 72);
    }
    if (version >= 2 && t.length >= 90) {
      xHeight = _data.i16(at + 86);
      capHeight = _data.i16(at + 88);
    }
  }

  void _readPost() {
    final t = _tables['post'];
    if (t == null) return;
    italicAngle = _data.fixed(t.offset + 4);
    underlinePosition = _data.i16(t.offset + 8);
    underlineThickness = _data.i16(t.offset + 10);
    isFixedPitch = _data.u32(t.offset + 12) != 0;
  }

  void _readNames() {
    final t = _tables['name'];
    if (t == null) return;
    final at = t.offset;
    final count = _data.u16(at + 2);
    final strings = at + _data.u16(at + 4);
    String? read(int nameId) {
      String? fallback;
      for (var i = 0; i < count; i++) {
        final record = at + 6 + 12 * i;
        if (_data.u16(record + 6) != nameId) continue;
        final platform = _data.u16(record);
        final length = _data.u16(record + 8);
        final offset = strings + _data.u16(record + 10);
        final raw = _data.slice(offset, length);
        if (platform == 3 || platform == 0) {
          final units = [
            for (var k = 0; k + 1 < raw.length; k += 2)
              (raw[k] << 8) | raw[k + 1],
          ];
          return String.fromCharCodes(units);
        }
        fallback ??= latin1.decode(raw);
      }
      return fallback;
    }

    postScriptName = _postScriptSafe(read(6) ?? read(4) ?? 'Font');
    familyName = read(1);
  }

  static String _postScriptSafe(String name) {
    final safe = name.replaceAll(RegExp(r'[^!-~]|[\[\](){}<>/%]'), '');
    return safe.isEmpty ? 'Font' : safe;
  }

  /// The advance width of glyph [glyph], in font units.
  int advance(int glyph) =>
      glyph >= 0 && glyph < numGlyphs ? _advances[glyph] : 0;

  /// The glyph for each character the font maps (from its best `cmap`
  /// subtable).
  late final Map<int, int> characterMap = _readCmap();

  /// The glyph for [codePoint], or 0 (`.notdef`).
  int glyphFor(int codePoint) => characterMap[codePoint] ?? 0;

  Map<int, int> _readCmap() {
    final t = _require('cmap');
    final at = t.offset;
    final count = _data.u16(at + 2);
    // Prefer full Unicode (3,10 or 0,4+), then BMP (3,1 or 0,x).
    int? best;
    var bestScore = -1;
    for (var i = 0; i < count; i++) {
      final record = at + 4 + 8 * i;
      final platform = _data.u16(record);
      final encoding = _data.u16(record + 2);
      final offset = at + _data.u32(record + 4);
      final format = _data.u16(offset);
      final score = switch ((platform, encoding)) {
        (3, 10) || (0, 4) || (0, 6) => 4,
        (0, _) => 3,
        (3, 1) => 2,
        (3, 0) => 1,
        _ => 0,
      };
      if (const [0, 4, 6, 12].contains(format) && score > bestScore) {
        best = offset;
        bestScore = score;
      }
    }
    if (best == null) return {};
    return _cmapSubtable(best);
  }

  Map<int, int> _cmapSubtable(int at) {
    final map = <int, int>{};
    switch (_data.u16(at)) {
      case 0:
        for (var c = 0; c < 256; c++) {
          final g = _data.u8(at + 6 + c);
          if (g != 0) map[c] = g;
        }
      case 4:
        final segCount = _data.u16(at + 6) ~/ 2;
        final ends = at + 14;
        final starts = ends + 2 * segCount + 2;
        final deltas = starts + 2 * segCount;
        final rangeOffsets = deltas + 2 * segCount;
        for (var s = 0; s < segCount; s++) {
          final end = _data.u16(ends + 2 * s);
          final start = _data.u16(starts + 2 * s);
          final delta = _data.i16(deltas + 2 * s);
          final rangeOffsetAt = rangeOffsets + 2 * s;
          final rangeOffset = _data.u16(rangeOffsetAt);
          if (start == 0xffff) continue;
          for (var c = start; c <= end && c != 0x10000; c++) {
            int g;
            if (rangeOffset == 0) {
              g = (c + delta) & 0xffff;
            } else {
              final glyphAt = rangeOffsetAt + rangeOffset + 2 * (c - start);
              g = _data.u16(glyphAt);
              if (g != 0) g = (g + delta) & 0xffff;
            }
            if (g != 0) map[c] = g;
          }
        }
      case 6:
        final first = _data.u16(at + 6);
        final count = _data.u16(at + 8);
        for (var i = 0; i < count; i++) {
          final g = _data.u16(at + 10 + 2 * i);
          if (g != 0) map[first + i] = g;
        }
      case 12:
        final groups = _data.u32(at + 12);
        for (var i = 0; i < groups; i++) {
          final group = at + 16 + 12 * i;
          final start = _data.u32(group);
          final end = _data.u32(group + 4);
          final glyph = _data.u32(group + 8);
          for (var c = start; c <= end; c++) {
            map[c] = glyph + (c - start);
          }
        }
    }
    return map;
  }

  /// The `glyf` data of [glyph] (empty for a glyph without outline).
  Uint8List glyphData(int glyph) {
    final (start, end) = _glyphRange(glyph);
    final glyf = _require('glyf');
    if (end < start) {
      throw FontFormatException('glyph $glyph has a negative length');
    }
    return _data.slice(glyf.offset + start, end - start);
  }

  (int, int) _glyphRange(int glyph) {
    final loca = _require('loca').offset;
    if (indexToLocFormat == 0) {
      return (
        _data.u16(loca + 2 * glyph) * 2,
        _data.u16(loca + 2 * glyph + 2) * 2,
      );
    }
    return (_data.u32(loca + 4 * glyph), _data.u32(loca + 4 * glyph + 4));
  }

  /// The glyphs composite glyph [glyph] is made of (directly).
  List<int> components(int glyph) {
    final data = glyphData(glyph);
    if (data.length < 10) return const [];
    final view = _Data(data);
    if (view.i16(0) >= 0) return const [];
    final result = <int>[];
    var at = 10;
    while (true) {
      final flags = view.u16(at);
      result.add(view.u16(at + 2));
      at += 4;
      at += flags & 0x0001 != 0 ? 4 : 2; // ARG_1_AND_2_ARE_WORDS
      if (flags & 0x0008 != 0) {
        at += 2; // WE_HAVE_A_SCALE
      } else if (flags & 0x0040 != 0) {
        at += 4; // WE_HAVE_AN_X_AND_Y_SCALE
      } else if (flags & 0x0080 != 0) {
        at += 8; // WE_HAVE_A_TWO_BY_TWO
      }
      if (flags & 0x0020 == 0) break; // MORE_COMPONENTS
    }
    return result;
  }

  /// Kerning between glyphs [left] and [right], in font units: GPOS pair
  /// adjustment (`kern` feature) when the font has it, else the `kern`
  /// table.
  int kerning(int left, int right) =>
      _gposKerning?.call(left, right) ?? _kernTable[(left << 16) | right] ?? 0;

  /// Kerning between glyphs [left] and [right] from the `kern` table
  /// alone (its horizontal format 0 subtables), in font units; null when
  /// it has no pair. [subtable] limits it to that subtable (by its place
  /// in the table: Prawn, say, reads only the first).
  int? kernTablePair(int left, int right, {int? subtable}) {
    final key = (left << 16) | right;
    if (subtable == null) return _kernTable[key];
    final tables = _kernSubtables;
    return subtable < tables.length ? tables[subtable][key] : null;
  }

  /// Whether the font has a `kern` table with pairs.
  bool get hasKernTable => _kernTable.isNotEmpty;

  late final Map<int, int> _kernTable = {
    for (final table in _kernSubtables) ...table,
  };

  /// The pairs of each subtable of the `kern` table, in order (none for a
  /// subtable that isn't horizontal format 0).
  late final List<Map<int, int>> _kernSubtables = _readKernSubtables();

  List<Map<int, int>> _readKernSubtables() {
    final t = _tables['kern'];
    final tables = <Map<int, int>>[];
    if (t == null) return tables;
    final at = t.offset;
    final count = _data.u16(at + 2);
    var sub = at + 4;
    for (var i = 0; i < count; i++) {
      final length = _data.u16(sub + 2);
      final coverage = _data.u16(sub + 4);
      final pairs = <int, int>{};
      // Format 0, horizontal kerning.
      if (coverage >> 8 == 0 && coverage & 0x1 != 0) {
        final nPairs = _data.u16(sub + 6);
        for (var p = 0; p < nPairs; p++) {
          final pair = sub + 14 + 6 * p;
          pairs[(_data.u16(pair) << 16) | _data.u16(pair + 2)] = _data.i16(
            pair + 4,
          );
        }
      }
      tables.add(pairs);
      sub += length;
    }
    return tables;
  }

  late final int? Function(int, int)? _gposKerning = _readGposKerning();

  int? Function(int, int)? _readGposKerning() {
    final t = _tables['GPOS'];
    if (t == null) return null;
    final lookups = _featureLookups(t.offset, 'kern');
    if (lookups.isEmpty) return null;
    final lookupList = t.offset + _data.u16(t.offset + 8);
    // The pair adjustment subtables of each lookup.
    final byLookup = <List<int>>[];
    for (final index in lookups) {
      final lookup = lookupList + _data.u16(lookupList + 2 + 2 * index);
      final lookupType = _data.u16(lookup);
      final count = _data.u16(lookup + 4);
      final subtables = <int>[];
      for (var s = 0; s < count; s++) {
        var sub = lookup + _data.u16(lookup + 6 + 2 * s);
        var type = lookupType;
        if (type == 9) {
          // Extension: the real type and an offset to the subtable.
          type = _data.u16(sub + 2);
          sub += _data.u32(sub + 4);
        }
        if (type == 2) subtables.add(sub);
      }
      if (subtables.isNotEmpty) byLookup.add(subtables);
    }
    if (byLookup.isEmpty) return null;
    // Each lookup applies in turn (their adjustments add up); within one,
    // the first subtable that covers the pair.
    return (left, right) {
      var total = 0;
      for (final subtables in byLookup) {
        for (final sub in subtables) {
          if (_pairAdjustment(sub, left, right) case final value?) {
            total += value;
            break;
          }
        }
      }
      return total;
    };
  }

  /// The lookups of feature [feature] in a GSUB or GPOS table at [table]
  /// (default script and language, else every script).
  List<int> _featureLookups(int table, String feature) {
    final featureList = table + _data.u16(table + 6);
    final count = _data.u16(featureList);
    final result = <int>{};
    for (var i = 0; i < count; i++) {
      final record = featureList + 2 + 6 * i;
      if (_data.tag(record) != feature) continue;
      final featureTable = featureList + _data.u16(record + 4);
      final lookupCount = _data.u16(featureTable + 2);
      for (var k = 0; k < lookupCount; k++) {
        result.add(_data.u16(featureTable + 4 + 2 * k));
      }
    }
    return result.toList()..sort();
  }

  int? _pairAdjustment(int sub, int left, int right) {
    final format = _data.u16(sub);
    final coverage = _coverageIndex(sub + _data.u16(sub + 2), left);
    if (coverage == null) return null;
    final valueFormat1 = _data.u16(sub + 4);
    final valueFormat2 = _data.u16(sub + 6);
    final size1 = _valueSize(valueFormat1);
    final size2 = _valueSize(valueFormat2);
    if (format == 1) {
      final pairSet = sub + _data.u16(sub + 10 + 2 * coverage);
      final count = _data.u16(pairSet);
      for (var i = 0; i < count; i++) {
        final record = pairSet + 2 + (2 + size1 + size2) * i;
        if (_data.u16(record) == right) {
          return _xAdvance(record + 2, valueFormat1);
        }
      }
      return null;
    }
    if (format == 2) {
      final class1 = _classOf(sub + _data.u16(sub + 8), left);
      final class2 = _classOf(sub + _data.u16(sub + 10), right);
      final class2Count = _data.u16(sub + 14);
      final record =
          sub + 16 + (class1 * class2Count + class2) * (size1 + size2);
      return _xAdvance(record, valueFormat1);
    }
    return null;
  }

  static int _valueSize(int format) {
    var size = 0;
    for (var bit = 0; bit < 8; bit++) {
      if (format & (1 << bit) != 0) size += 2;
    }
    return size;
  }

  int _xAdvance(int at, int format) {
    if (format & 0x0004 == 0) return 0;
    var offset = 0;
    if (format & 0x0001 != 0) offset += 2;
    if (format & 0x0002 != 0) offset += 2;
    return _data.i16(at + offset);
  }

  int? _coverageIndex(int coverage, int glyph) {
    final format = _data.u16(coverage);
    final count = _data.u16(coverage + 2);
    if (format == 1) {
      var lo = 0;
      var hi = count - 1;
      while (lo <= hi) {
        final mid = (lo + hi) >> 1;
        final g = _data.u16(coverage + 4 + 2 * mid);
        if (g == glyph) return mid;
        if (g < glyph) {
          lo = mid + 1;
        } else {
          hi = mid - 1;
        }
      }
      return null;
    }
    if (format == 2) {
      for (var i = 0; i < count; i++) {
        final range = coverage + 4 + 6 * i;
        final start = _data.u16(range);
        final end = _data.u16(range + 2);
        if (glyph >= start && glyph <= end) {
          return _data.u16(range + 4) + glyph - start;
        }
      }
    }
    return null;
  }

  int _classOf(int classDef, int glyph) {
    final format = _data.u16(classDef);
    if (format == 1) {
      final start = _data.u16(classDef + 2);
      final count = _data.u16(classDef + 4);
      if (glyph >= start && glyph < start + count) {
        return _data.u16(classDef + 6 + 2 * (glyph - start));
      }
      return 0;
    }
    if (format == 2) {
      final count = _data.u16(classDef + 2);
      for (var i = 0; i < count; i++) {
        final range = classDef + 4 + 6 * i;
        if (glyph >= _data.u16(range) && glyph <= _data.u16(range + 2)) {
          return _data.u16(range + 4);
        }
      }
    }
    return 0;
  }

  final Map<String, Map<int, int>> _singles = {};

  /// The glyph each glyph becomes in [feature] (`onum`, `smcp`...): the
  /// feature's single substitutions (GSUB lookup type 1, and type 2's
  /// one-glyph sequences); empty when the
  /// font hasn't the feature.
  Map<int, int> singleSubstitutions(String feature) =>
      _singles[feature] ??= _readSingles(feature);

  /// Whether the font's GSUB has [feature].
  bool hasFeature(String feature) {
    final t = _tables['GSUB'];
    return t != null && _featureLookups(t.offset, feature).isNotEmpty;
  }

  Map<int, int> _readSingles(String feature) {
    final t = _tables['GSUB'];
    final result = <int, int>{};
    if (t == null) return result;
    final lookupList = t.offset + _data.u16(t.offset + 8);
    for (final index in _featureLookups(t.offset, feature)) {
      final lookup = lookupList + _data.u16(lookupList + 2 + 2 * index);
      final lookupType = _data.u16(lookup);
      final count = _data.u16(lookup + 4);
      for (var s = 0; s < count; s++) {
        var sub = lookup + _data.u16(lookup + 6 + 2 * s);
        var type = lookupType;
        if (type == 7) {
          type = _data.u16(sub + 2);
          sub += _data.u32(sub + 4);
        }
        // Multiple substitutions (type 2) of one glyph each are single
        // ones too (Libertinus's `smcp`).
        if (type != 1 && type != 2) continue;
        final format = _data.u16(sub);
        final glyphs = _coverageGlyphs(sub + _data.u16(sub + 2));
        int? oneOf(int k) {
          if (k >= _data.u16(sub + 4)) return null;
          final sequence = sub + _data.u16(sub + 6 + 2 * k);
          return _data.u16(sequence) == 1 ? _data.u16(sequence + 2) : null;
        }

        for (final (k, glyph) in glyphs.indexed) {
          final substitute = switch ((type, format)) {
            (1, 1) => (glyph + _data.i16(sub + 4)) & 0xffff,
            (1, 2) when k < _data.u16(sub + 4) => _data.u16(sub + 6 + 2 * k),
            (2, 1) => oneOf(k),
            _ => null,
          };
          if (substitute != null) result.putIfAbsent(glyph, () => substitute);
        }
      }
    }
    return result;
  }

  /// The ligatures of the `liga` feature: for a first glyph, the
  /// sequences that follow it and the glyph replacing them, longest
  /// first.
  late final Map<int, List<(List<int>, int)>> ligatures = _readLigatures();

  Map<int, List<(List<int>, int)>> _readLigatures() {
    final t = _tables['GSUB'];
    final result = <int, List<(List<int>, int)>>{};
    if (t == null) return result;
    final lookupList = t.offset + _data.u16(t.offset + 8);
    for (final index in _featureLookups(t.offset, 'liga')) {
      final lookup = lookupList + _data.u16(lookupList + 2 + 2 * index);
      final lookupType = _data.u16(lookup);
      final count = _data.u16(lookup + 4);
      for (var s = 0; s < count; s++) {
        var sub = lookup + _data.u16(lookup + 6 + 2 * s);
        var type = lookupType;
        if (type == 7) {
          type = _data.u16(sub + 2);
          sub += _data.u32(sub + 4);
        }
        if (type != 4) continue;
        final coverage = sub + _data.u16(sub + 2);
        final setCount = _data.u16(sub + 4);
        final firstGlyphs = _coverageGlyphs(coverage);
        for (var k = 0; k < setCount && k < firstGlyphs.length; k++) {
          final set = sub + _data.u16(sub + 6 + 2 * k);
          final ligatureCount = _data.u16(set);
          for (var l = 0; l < ligatureCount; l++) {
            final ligature = set + _data.u16(set + 2 + 2 * l);
            final glyph = _data.u16(ligature);
            final components = _data.u16(ligature + 2);
            final rest = [
              for (var c = 1; c < components; c++)
                _data.u16(ligature + 2 + 2 * c),
            ];
            (result[firstGlyphs[k]] ??= []).add((rest, glyph));
          }
        }
      }
    }
    for (final list in result.values) {
      list.sort((a, b) => b.$1.length - a.$1.length);
    }
    return result;
  }

  List<int> _coverageGlyphs(int coverage) {
    final format = _data.u16(coverage);
    final count = _data.u16(coverage + 2);
    if (format == 1) {
      return [for (var i = 0; i < count; i++) _data.u16(coverage + 4 + 2 * i)];
    }
    final glyphs = <int>[];
    for (var i = 0; i < count; i++) {
      final range = coverage + 4 + 6 * i;
      for (var g = _data.u16(range); g <= _data.u16(range + 2); g++) {
        glyphs.add(g);
      }
    }
    return glyphs;
  }
}

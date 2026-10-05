/// Fonts for PDF text: the 14 standard fonts (metrics only, never
/// embedded) and embedded TrueType/OpenType fonts (subset to the glyphs
/// used, as Type0 fonts with Identity-H and a ToUnicode map).
library;

import 'dart:convert';

import 'package:libpdf/src/fonts/encoding.dart';
import 'package:libpdf/src/fonts/opentype.dart';
import 'package:libpdf/src/fonts/standard_metrics.dart';
import 'package:libpdf/src/fonts/standard_metrics.g.dart';
import 'package:libpdf/src/fonts/subset.dart';
import 'package:libpdf/src/md5.dart';
import 'package:libpdf/src/objects.dart';
import 'package:libpdf/src/writer.dart';

/// A glyph of shaped text: what to draw and how far it moves.
final class ShapedGlyph {
  /// A glyph [id] standing for [text], advancing [advance] plus [kerning]
  /// (in 1000ths of the em).
  const new(this.id, this.text, this.advance, [this.kerning = 0]);

  /// The glyph: its id in an embedded font, its code in a standard font.
  final int id;

  /// The characters the glyph stands for (several for a ligature).
  final String text;

  /// The glyph's advance width, in 1000ths of the em.
  final double advance;

  /// The kerning before the next glyph, in 1000ths of the em (negative
  /// brings it closer).
  final double kerning;
}

/// A font text can be set in.
sealed class PdfFont {
  new _();

  /// The PostScript name.
  String get name;

  /// The ascender, in 1000ths of the em.
  double get ascender;

  /// The descender (negative), in 1000ths of the em.
  double get descender;

  /// The line gap, in 1000ths of the em.
  double get lineGap;

  /// The height of capital letters, in 1000ths of the em.
  double get capHeight;

  /// The height of lowercase letters, in 1000ths of the em.
  double get xHeight;

  /// Whether the font has a glyph for [codePoint].
  bool covers(int codePoint);

  /// [text] as glyphs, with kerning (and ligatures in an embedded font)
  /// when asked.
  List<ShapedGlyph> shape(
    String text, {
    bool kerning = true,
    bool ligatures = false,
  });

  /// The width of [text] at [size] points.
  double widthOf(String text, double size, {bool kerning = true}) {
    var width = 0.0;
    for (final glyph in shape(text, kerning: kerning)) {
      width += glyph.advance + glyph.kerning;
    }
    return width * size / 1000;
  }

  /// The bytes that show [glyphs] in a content stream (`Tj`), recording
  /// them as used.
  List<int> encode(List<ShapedGlyph> glyphs);

  /// The reference the font is written under, reserved from [writer].
  PdfRef reference(PdfWriter writer) =>
      _references[writer] ??= writer.reserve();

  final Expando<PdfRef> _references = Expando<PdfRef>();

  /// Writes the font's objects to [writer] (after all text is encoded).
  void writeTo(PdfWriter writer);
}

/// One of the 14 standard fonts, which every PDF reader provides.
final class StandardFont extends PdfFont {
  new _(this._data) : super._();

  /// The standard font [name] (`Helvetica`, `Times-Bold`...).
  factory named(String name) => _cache[name] ??= StandardFont._(
    standardFontData[name] ??
        (throw ArgumentError.value(name, 'name', 'is not a standard font')),
  );

  static final Map<String, StandardFont> _cache = {};

  /// Helvetica.
  static final StandardFont helvetica = StandardFont.named('Helvetica');

  /// Times-Roman.
  static final StandardFont timesRoman = StandardFont.named('Times-Roman');

  /// Courier.
  static final StandardFont courier = StandardFont.named('Courier');

  final StandardFontData _data;

  @override
  String get name => _data.name;

  @override
  double get ascender => _data.ascender.toDouble();

  @override
  double get descender => _data.descender.toDouble();

  @override
  double get lineGap => 0;

  @override
  double get capHeight => _data.capHeight.toDouble();

  @override
  double get xHeight => _data.xHeight.toDouble();

  late final _StandardGlyphs _glyphs = _StandardGlyphs.parse(_data);

  int? _code(int codePoint) => _data.symbolic
      ? _glyphs.codeForUnicode[codePoint]
      : winAnsiCode(codePoint);

  @override
  bool covers(int codePoint) {
    final code = _code(codePoint);
    return code != null &&
        _glyphs.widthForCode(code, symbolic: _data.symbolic) != null;
  }

  @override
  List<ShapedGlyph> shape(
    String text, {
    bool kerning = true,
    bool ligatures = false,
  }) {
    final glyphs = <ShapedGlyph>[];
    String? previousName;
    for (final rune in text.runes) {
      final code = _code(rune) ?? (_data.symbolic ? 0x20 : 0x3f); // '?'
      final width = _glyphs.widthForCode(code, symbolic: _data.symbolic) ?? 0;
      final name = _glyphs.nameForCode(code, symbolic: _data.symbolic);
      if (kerning &&
          previousName != null &&
          name != null &&
          glyphs.isNotEmpty) {
        final kern = _glyphs.kerning['$previousName $name'];
        if (kern != null) {
          final last = glyphs.removeLast();
          glyphs.add(
            ShapedGlyph(last.id, last.text, last.advance, kern.toDouble()),
          );
        }
      }
      glyphs.add(
        ShapedGlyph(code, String.fromCharCode(rune), width.toDouble()),
      );
      previousName = name;
    }
    return glyphs;
  }

  @override
  List<int> encode(List<ShapedGlyph> glyphs) => [for (final g in glyphs) g.id];

  @override
  void writeTo(PdfWriter writer) {
    writer.write(
      PdfDict({
        'Type': const PdfName('Font'),
        'Subtype': const PdfName('Type1'),
        'BaseFont': PdfName(name),
        if (!_data.symbolic) 'Encoding': const PdfName('WinAnsiEncoding'),
      }),
      reference(writer),
    );
  }
}

final class _StandardGlyphs {
  new(this._byCode, this._byName, this.codeForUnicode, this.kerning);

  factory parse(StandardFontData data) {
    final byCode = <int, (String, int)>{};
    final byName = <String, int>{};
    final codeForUnicode = <int, int>{};
    for (final entry in data.glyphs.split(';')) {
      final [code, name, width, unicode] = entry.split(' ');
      final c = int.parse(code);
      final w = int.parse(width);
      byName[name] = w;
      if (c >= 0) {
        byCode[c] = (name, w);
        if (unicode != '-') codeForUnicode[int.parse(unicode, radix: 16)] = c;
      }
    }
    final kerning = <String, int>{};
    if (data.kerning.isNotEmpty) {
      for (final pair in data.kerning.split(';')) {
        final [left, right, value] = pair.split(' ');
        kerning['$left $right'] = int.parse(value);
      }
    }
    // Latin fonts are used through WinAnsiEncoding: their glyphs by name
    // (the AFM codes are StandardEncoding's).
    final unicodeNames = <int, String>{};
    for (final entry in data.glyphs.split(';')) {
      final [_, name, _, unicode] = entry.split(' ');
      if (unicode != '-') {
        unicodeNames.putIfAbsent(int.parse(unicode, radix: 16), () => name);
      }
    }
    return _StandardGlyphs(byCode, byName, codeForUnicode, kerning)
      .._unicodeNames = unicodeNames;
  }

  final Map<int, (String, int)> _byCode;
  final Map<String, int> _byName;
  final Map<int, int> codeForUnicode;
  final Map<String, int> kerning;
  Map<int, String> _unicodeNames = const {};

  String? nameForCode(int code, {required bool symbolic}) {
    if (symbolic) return _byCode[code]?.$1;
    final character = winAnsiCharacter(code);
    return character == null ? null : _unicodeNames[character];
  }

  int? widthForCode(int code, {required bool symbolic}) {
    final name = nameForCode(code, symbolic: symbolic);
    return name == null ? null : _byName[name];
  }
}

/// A TrueType or OpenType font embedded in the document: subset to the
/// glyphs used (TrueType outlines) and written as a Type0 font with
/// Identity-H encoding and a ToUnicode map, so text extracts and searches.
final class EmbeddedFont extends PdfFont {
  new _(this.font, {required this.subset}) : super._();

  /// The font in [bytes] (the font at [index] of a collection); with
  /// [subset] (the default), only the glyphs used are embedded.
  factory parse(List<int> bytes, {int index = 0, bool subset = true}) =>
      EmbeddedFont._(OpenTypeFont.parse(bytes, index: index), subset: subset);

  /// The font program.
  final OpenTypeFont font;

  /// Whether only the glyphs used are embedded.
  final bool subset;

  /// The glyphs used so far, with the text each stands for.
  final Map<int, String> _used = {};

  /// Whether text used a character the font has no glyph for.
  bool _usedNotdef = false;

  /// Whether text has used characters the font has no glyph for (shown as
  /// `.notdef`).
  bool get missedGlyphs => _usedNotdef;

  double _scale(num units) => units * 1000 / font.unitsPerEm;

  @override
  String get name => font.postScriptName;

  @override
  double get ascender => _scale(font.ascender);

  @override
  double get descender => _scale(font.descender);

  @override
  double get lineGap => _scale(font.lineGap);

  @override
  double get capHeight => _scale(font.capHeight ?? font.ascender);

  @override
  double get xHeight => _scale(font.xHeight ?? (font.ascender ~/ 2));

  @override
  bool covers(int codePoint) => font.glyphFor(codePoint) != 0;

  @override
  List<ShapedGlyph> shape(
    String text, {
    bool kerning = true,
    bool ligatures = false,
  }) {
    final runes = text.runes.toList();
    final ids = <int>[];
    final texts = <String>[];
    var i = 0;
    while (i < runes.length) {
      final glyph = font.glyphFor(runes[i]);
      var matched = false;
      if (ligatures) {
        for (final (rest, ligature)
            in font.ligatures[glyph] ?? const <(List<int>, int)>[]) {
          if (i + rest.length >= runes.length) continue;
          var all = true;
          for (var k = 0; all && k < rest.length; k++) {
            all = font.glyphFor(runes[i + 1 + k]) == rest[k];
          }
          if (!all) continue;
          ids.add(ligature);
          texts.add(
            String.fromCharCodes(runes.sublist(i, i + 1 + rest.length)),
          );
          i += 1 + rest.length;
          matched = true;
          break;
        }
      }
      if (!matched) {
        ids.add(glyph);
        texts.add(String.fromCharCode(runes[i]));
        i += 1;
      }
    }
    return [
      for (var k = 0; k < ids.length; k++)
        ShapedGlyph(
          ids[k],
          texts[k],
          _scale(font.advance(ids[k])),
          kerning && k + 1 < ids.length
              ? _scale(font.kerning(ids[k], ids[k + 1]))
              : 0,
        ),
    ];
  }

  @override
  List<int> encode(List<ShapedGlyph> glyphs) {
    final bytes = <int>[];
    for (final glyph in glyphs) {
      // `.notdef` stands for no character: it stays out of the ToUnicode
      // map (and still goes into the subset).
      if (glyph.id == 0) {
        _usedNotdef = true;
      } else {
        _used.putIfAbsent(glyph.id, () => glyph.text);
      }
      bytes
        ..add(glyph.id >> 8)
        ..add(glyph.id & 0xff);
    }
    return bytes;
  }

  /// The six-letter tag of the subset (ISO 32000-2, 9.9.2), derived from
  /// the glyphs used so the same use gives the same tag.
  String get _subsetTag {
    final digest = md5(utf8.encode((_used.keys.toList()..sort()).join(',')));
    return String.fromCharCodes([
      for (final b in digest.take(6)) 0x41 + b % 26,
    ]);
  }

  @override
  void writeTo(PdfWriter writer) {
    final glyphs = glyphClosure(font, _used.keys);
    final trueType = font.isTrueType;
    final program = trueType && subset
        ? subsetTrueType(font, glyphs)
        : font.bytes;
    final baseName = subset && trueType ? '$_subsetTag+$name' : name;
    final fontFile = writer.write(
      PdfStream(
        program,
        dict: PdfDict({
          if (trueType)
            'Length1': PdfInt(program.length)
          else
            'Subtype': const PdfName('OpenType'),
        }),
      ),
    );
    final flags =
        4 | // symbolic: glyphs addressed by id
        (font.isFixedPitch ? 1 : 0) |
        (font.italicAngle != 0 ? 64 : 0);
    final descriptor = writer.write(
      PdfDict({
        'Type': const PdfName('FontDescriptor'),
        'FontName': PdfName(baseName),
        'Flags': PdfInt(flags),
        'FontBBox': PdfArray.numbers([
          for (final v in font.bbox) _scale(v).round(),
        ]),
        'ItalicAngle': PdfReal(font.italicAngle),
        'Ascent': PdfInt(ascender.round()),
        'Descent': PdfInt(descender.round()),
        'CapHeight': PdfInt(capHeight.round()),
        'StemV': PdfInt(font.weightClass >= 600 ? 120 : 80),
        if (trueType) 'FontFile2': fontFile else 'FontFile3': fontFile,
      }),
    );
    final descendant = writer.write(
      PdfDict({
        'Type': const PdfName('Font'),
        'Subtype': PdfName(trueType ? 'CIDFontType2' : 'CIDFontType0'),
        'BaseFont': PdfName(baseName),
        'CIDSystemInfo': PdfDict({
          'Registry': PdfString(ascii.encode('Adobe')),
          'Ordering': PdfString(ascii.encode('Identity')),
          'Supplement': const PdfInt(0),
        }),
        'FontDescriptor': descriptor,
        'DW': PdfInt(_scale(font.advance(0)).round()),
        'W': _widths(),
        if (trueType) 'CIDToGIDMap': const PdfName('Identity'),
      }),
    );
    final toUnicode = writer.write(PdfStream(utf8.encode(_toUnicodeCMap())));
    writer.write(
      PdfDict({
        'Type': const PdfName('Font'),
        'Subtype': const PdfName('Type0'),
        'BaseFont': PdfName(baseName),
        'Encoding': const PdfName('Identity-H'),
        'DescendantFonts': PdfArray([descendant]),
        'ToUnicode': toUnicode,
      }),
      reference(writer),
    );
  }

  /// The widths of the glyphs used (`/W`): runs of consecutive glyph ids.
  PdfArray _widths() {
    final ids = _used.keys.toList()..sort();
    final items = <PdfObject>[];
    var i = 0;
    while (i < ids.length) {
      final start = ids[i];
      final run = <PdfObject>[];
      while (i < ids.length && ids[i] == start + run.length) {
        run.add(PdfInt(_scale(font.advance(ids[i])).round()));
        i += 1;
      }
      items
        ..add(PdfInt(start))
        ..add(PdfArray(run));
    }
    return PdfArray(items);
  }

  /// A ToUnicode CMap (ISO 32000-2, 9.10.3) mapping each glyph used to its
  /// text.
  String _toUnicodeCMap() {
    String hex4(int v) => v.toRadixString(16).padLeft(4, '0').toUpperCase();
    String utf16(String text) =>
        [for (final unit in text.codeUnits) hex4(unit)].join();
    final ids = _used.keys.toList()..sort();
    final out = StringBuffer()
      ..write('/CIDInit /ProcSet findresource begin\n')
      ..write('12 dict begin\nbegincmap\n')
      ..write(
        '/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n',
      )
      ..write('/CMapName /Adobe-Identity-UCS def\n/CMapType 2 def\n')
      ..write('1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n');
    for (var start = 0; start < ids.length; start += 100) {
      final chunk = ids.sublist(start, (start + 100).clamp(0, ids.length));
      out.write('${chunk.length} beginbfchar\n');
      for (final id in chunk) {
        out.write('<${hex4(id)}> <${utf16(_used[id]!)}>\n');
      }
      out.write('endbfchar\n');
    }
    out.write(
      'endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n',
    );
    return out.toString();
  }
}

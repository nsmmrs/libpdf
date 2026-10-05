/// The metrics of a standard font, as generated from its AFM file.
library;

/// A standard font's metrics, with its glyphs and kerning pairs as compact
/// strings (parsed on first use).
final class StandardFontData {
  /// Metrics of a standard font.
  const new({
    required this.name,
    required this.bbox,
    required this.ascender,
    required this.descender,
    required this.capHeight,
    required this.xHeight,
    required this.italicAngle,
    required this.stemV,
    required this.fixedPitch,
    required this.symbolic,
    required this.glyphs,
    required this.kerning,
  });

  /// The PostScript name (`Helvetica`).
  final String name;

  /// The font bounding box, in 1000ths of the em.
  final List<int> bbox;

  /// Metrics, in 1000ths of the em.
  final int ascender;

  /// The descender (negative).
  final int descender;

  /// The height of capital letters.
  final int capHeight;

  /// The height of lowercase letters.
  final int xHeight;

  /// The italic angle, in degrees.
  final num italicAngle;

  /// The dominant vertical stem width.
  final int stemV;

  /// Whether every glyph has the same width.
  final bool fixedPitch;

  /// Whether the font has its own encoding (Symbol, ZapfDingbats) rather
  /// than the Latin text encodings.
  final bool symbolic;

  /// `code name width unicode` per glyph, separated by `;` (code `-1`
  /// for a glyph outside the built-in encoding, unicode `-` for none).
  final String glyphs;

  /// `left right value` per kerning pair, separated by `;`.
  final String kerning;
}

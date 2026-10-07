/// The OpenType `MATH` table (OpenType 1.9, "MATH — The Mathematical
/// Typesetting Table"): the constants a math layout is measured by, the
/// glyphs' italic corrections and accent attachment points, and the
/// larger variants and assemblies of stretchy glyphs.
library;

import 'dart:typed_data';

/// The constants of a `MATH` table, in font design units (percentages
/// for the scale-downs and the radical degree's raise).
enum MathConstant {
  /// `ScriptPercentScaleDown`.
  scriptPercentScaleDown,

  /// `ScriptScriptPercentScaleDown`.
  scriptScriptPercentScaleDown,

  /// `DelimitedSubFormulaMinHeight`.
  delimitedSubFormulaMinHeight,

  /// `DisplayOperatorMinHeight`.
  displayOperatorMinHeight,

  /// `MathLeading`.
  mathLeading,

  /// `AxisHeight`.
  axisHeight,

  /// `AccentBaseHeight`.
  accentBaseHeight,

  /// `FlattenedAccentBaseHeight`.
  flattenedAccentBaseHeight,

  /// `SubscriptShiftDown`.
  subscriptShiftDown,

  /// `SubscriptTopMax`.
  subscriptTopMax,

  /// `SubscriptBaselineDropMin`.
  subscriptBaselineDropMin,

  /// `SuperscriptShiftUp`.
  superscriptShiftUp,

  /// `SuperscriptShiftUpCramped`.
  superscriptShiftUpCramped,

  /// `SuperscriptBottomMin`.
  superscriptBottomMin,

  /// `SuperscriptBaselineDropMax`.
  superscriptBaselineDropMax,

  /// `SubSuperscriptGapMin`.
  subSuperscriptGapMin,

  /// `SuperscriptBottomMaxWithSubscript`.
  superscriptBottomMaxWithSubscript,

  /// `SpaceAfterScript`.
  spaceAfterScript,

  /// `UpperLimitGapMin`.
  upperLimitGapMin,

  /// `UpperLimitBaselineRiseMin`.
  upperLimitBaselineRiseMin,

  /// `LowerLimitGapMin`.
  lowerLimitGapMin,

  /// `LowerLimitBaselineDropMin`.
  lowerLimitBaselineDropMin,

  /// `StackTopShiftUp`.
  stackTopShiftUp,

  /// `StackTopDisplayStyleShiftUp`.
  stackTopDisplayStyleShiftUp,

  /// `StackBottomShiftDown`.
  stackBottomShiftDown,

  /// `StackBottomDisplayStyleShiftDown`.
  stackBottomDisplayStyleShiftDown,

  /// `StackGapMin`.
  stackGapMin,

  /// `StackDisplayStyleGapMin`.
  stackDisplayStyleGapMin,

  /// `StretchStackTopShiftUp`.
  stretchStackTopShiftUp,

  /// `StretchStackBottomShiftDown`.
  stretchStackBottomShiftDown,

  /// `StretchStackGapAboveMin`.
  stretchStackGapAboveMin,

  /// `StretchStackGapBelowMin`.
  stretchStackGapBelowMin,

  /// `FractionNumeratorShiftUp`.
  fractionNumeratorShiftUp,

  /// `FractionNumeratorDisplayStyleShiftUp`.
  fractionNumeratorDisplayStyleShiftUp,

  /// `FractionDenominatorShiftDown`.
  fractionDenominatorShiftDown,

  /// `FractionDenominatorDisplayStyleShiftDown`.
  fractionDenominatorDisplayStyleShiftDown,

  /// `FractionNumeratorGapMin`.
  fractionNumeratorGapMin,

  /// `FractionNumDisplayStyleGapMin`.
  fractionNumDisplayStyleGapMin,

  /// `FractionRuleThickness`.
  fractionRuleThickness,

  /// `FractionDenominatorGapMin`.
  fractionDenominatorGapMin,

  /// `FractionDenomDisplayStyleGapMin`.
  fractionDenomDisplayStyleGapMin,

  /// `SkewedFractionHorizontalGap`.
  skewedFractionHorizontalGap,

  /// `SkewedFractionVerticalGap`.
  skewedFractionVerticalGap,

  /// `OverbarVerticalGap`.
  overbarVerticalGap,

  /// `OverbarRuleThickness`.
  overbarRuleThickness,

  /// `OverbarExtraAscender`.
  overbarExtraAscender,

  /// `UnderbarVerticalGap`.
  underbarVerticalGap,

  /// `UnderbarRuleThickness`.
  underbarRuleThickness,

  /// `UnderbarExtraDescender`.
  underbarExtraDescender,

  /// `RadicalVerticalGap`.
  radicalVerticalGap,

  /// `RadicalDisplayStyleVerticalGap`.
  radicalDisplayStyleVerticalGap,

  /// `RadicalRuleThickness`.
  radicalRuleThickness,

  /// `RadicalExtraAscender`.
  radicalExtraAscender,

  /// `RadicalKernBeforeDegree`.
  radicalKernBeforeDegree,

  /// `RadicalKernAfterDegree`.
  radicalKernAfterDegree,

  /// `RadicalDegreeBottomRaisePercent`.
  radicalDegreeBottomRaisePercent,
}

/// A larger version of a glyph: its id and its size in the direction it
/// grows (design units).
typedef MathVariant = ({int glyph, int advance});

/// A piece of a glyph assembly: the glyph, its connectors' lengths at
/// its start and end, its full size in the direction it grows, and
/// whether it may repeat (an extender).
typedef GlyphPart = ({
  int glyph,
  int startConnector,
  int endConnector,
  int fullAdvance,
  bool extender,
});

/// How a glyph grows in one direction: its ready-made variants, smallest
/// first (the glyph itself among them), and the parts it may be built
/// from when none is large enough.
final class GlyphConstruction {
  /// A construction of [variants] and [parts] (empty when it has no
  /// assembly).
  const new(this.variants, this.parts, this.italicsCorrection);

  /// The variants, smallest first.
  final List<MathVariant> variants;

  /// The parts of the assembly, from bottom (or left) to top (or right).
  final List<GlyphPart> parts;

  /// The assembly's italic correction.
  final int italicsCorrection;
}

/// A font's `MATH` table.
final class OpenTypeMathTable {
  new _(this._data, this._constants);

  /// The `MATH` table in [bytes], or null when it isn't one.
  static OpenTypeMathTable? parse(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    if (bytes.length < 10 || data.getUint16(0) != 1) return null;
    final at = data.getUint16(4);
    final constants = <int>[
      data.getInt16(at),
      data.getInt16(at + 2),
      data.getUint16(at + 4),
      data.getUint16(at + 6),
      // The 51 MathValueRecords (a value, then a device table offset).
      for (var i = 0; i < 51; i++) data.getInt16(at + 8 + 4 * i),
      data.getInt16(at + 8 + 4 * 51),
    ];
    return OpenTypeMathTable._(data, constants);
  }

  final ByteData _data;
  final List<int> _constants;

  /// The value of [constant].
  int operator [](MathConstant constant) => _constants[constant.index];

  int get _glyphInfo => _data.getUint16(6);
  int get _variants => _data.getUint16(8);

  /// The italic corrections of the glyphs that have one, by glyph.
  late final Map<int, int> italicsCorrections = _valueRecords(0);

  /// Where an accent over a glyph is centered, from its left, by glyph
  /// (a glyph without one: the middle of its advance).
  late final Map<int, int> topAccentAttachments = _valueRecords(2);

  /// The glyphs whose shapes extend (no accent attachment correction).
  late final Set<int> extendedShapes = () {
    final info = _glyphInfo;
    final offset = _data.getUint16(info + 4);
    if (offset == 0) return <int>{};
    return _coverage(info + offset).toSet();
  }();

  Map<int, int> _valueRecords(int field) {
    final info = _glyphInfo;
    final offset = _data.getUint16(info + field);
    if (offset == 0) return const {};
    final at = info + offset;
    final glyphs = _coverage(at + _data.getUint16(at));
    final count = _data.getUint16(at + 2);
    return {
      for (var i = 0; i < count && i < glyphs.length; i++)
        glyphs[i]: _data.getInt16(at + 4 + 4 * i),
    };
  }

  /// The overlap two parts of an assembly keep at least.
  int get minConnectorOverlap => _data.getUint16(_variants);

  /// How [glyph] grows vertically, or null.
  GlyphConstruction? vertical(int glyph) => _vertical[glyph];

  /// How [glyph] grows horizontally, or null.
  GlyphConstruction? horizontal(int glyph) => _horizontal[glyph];

  late final Map<int, GlyphConstruction> _vertical = _constructions(true);
  late final Map<int, GlyphConstruction> _horizontal = _constructions(false);

  Map<int, GlyphConstruction> _constructions(bool vertical) {
    final at = _variants;
    final coverageOffset = _data.getUint16(at + (vertical ? 2 : 4));
    final vertCount = _data.getUint16(at + 6);
    final horizCount = _data.getUint16(at + 8);
    if (coverageOffset == 0) return const {};
    final glyphs = _coverage(at + coverageOffset);
    final count = vertical ? vertCount : horizCount;
    final first = at + 10 + (vertical ? 0 : 2 * vertCount);
    final result = <int, GlyphConstruction>{};
    for (var i = 0; i < count && i < glyphs.length; i++) {
      final construction = at + _data.getUint16(first + 2 * i);
      final assemblyOffset = _data.getUint16(construction);
      final variantCount = _data.getUint16(construction + 2);
      final variants = <MathVariant>[
        for (var v = 0; v < variantCount; v++)
          (
            glyph: _data.getUint16(construction + 4 + 4 * v),
            advance: _data.getUint16(construction + 6 + 4 * v),
          ),
      ];
      var parts = <GlyphPart>[];
      var italics = 0;
      if (assemblyOffset != 0) {
        final assembly = construction + assemblyOffset;
        italics = _data.getInt16(assembly);
        final partCount = _data.getUint16(assembly + 4);
        parts = [
          for (var p = 0; p < partCount; p++)
            (
              glyph: _data.getUint16(assembly + 6 + 10 * p),
              startConnector: _data.getUint16(assembly + 8 + 10 * p),
              endConnector: _data.getUint16(assembly + 10 + 10 * p),
              fullAdvance: _data.getUint16(assembly + 12 + 10 * p),
              extender: _data.getUint16(assembly + 14 + 10 * p) & 1 != 0,
            ),
        ];
      }
      result[glyphs[i]] = GlyphConstruction(variants, parts, italics);
    }
    return result;
  }

  /// The glyphs of the coverage table at [at], in coverage order.
  List<int> _coverage(int at) {
    final format = _data.getUint16(at);
    final count = _data.getUint16(at + 2);
    if (format == 1) {
      return [for (var i = 0; i < count; i++) _data.getUint16(at + 4 + 2 * i)];
    }
    final glyphs = <int>[];
    for (var i = 0; i < count; i++) {
      final range = at + 4 + 6 * i;
      final start = _data.getUint16(range);
      final end = _data.getUint16(range + 2);
      for (var g = start; g <= end; g++) {
        glyphs.add(g);
      }
    }
    return glyphs;
  }
}

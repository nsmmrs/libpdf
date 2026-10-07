/// Math layout: a [MathNode] tree set in a font with an OpenType `MATH`
/// table, by the rules of the `MATH` table's specification and MathML
/// Core (which follow TeX's): script shifts and gaps, fractions,
/// radicals, limits and accents, stretchy delimiters and large operators
/// from the font's variants and glyph assemblies, and TeX's spacing
/// between atoms.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fonts/fonts.dart';
import 'package:libpdf/src/drawing/canvas.dart';
import 'package:libpdf/src/drawing/color.dart';
import 'package:libpdf/src/drawing/geometry.dart';
import 'package:libpdf/src/drawing/graphic.dart';
import 'package:libpdf/src/fonts/fonts.dart';
import 'package:libpdf/src/math/math_table.dart';
import 'package:libpdf/src/math/mathml.dart';

/// A formula laid out: as wide as [width], [height] above its baseline
/// and [depth] below it (points), drawn with [paintAt].
final class MathBox implements Graphic {
  new _(this.width, this.height, this.depth, this._items);

  /// The width, in points.
  final double width;

  /// The height above the baseline, in points.
  final double height;

  /// The depth below the baseline (positive), in points.
  final double depth;

  final List<_Item> _items;

  @override
  double get intrinsicWidth => width;

  @override
  double get intrinsicHeight => height + depth;

  /// Draws the formula with its baseline starting at ([x], [y]), in the
  /// canvas's fill color where the formula sets none.
  void paintAt(PdfCanvas canvas, double x, double y) {
    canvas.save();
    for (final item in _items) {
      if (item.color case final color?) {
        canvas
          ..setFillColor(color)
          ..setStrokeColor(color);
      }
      switch (item) {
        case _Glyph(
          :final font,
          :final glyph,
          :final text,
          :final advance,
          :final size,
        ):
          canvas.glyphs(
            [ShapedGlyph(glyph, text, advance)],
            x + item.x,
            y + item.y,
            PdfTextStyle(font, size),
          );
        case _Rule(:final w, :final h):
          canvas
            ..rect(PdfRect(x + item.x, y + item.y, w, h))
            ..fill();
        case _Stroke(:final kind, :final w, :final h, :final lineWidth):
          canvas.setLineWidth(lineWidth);
          final left = x + item.x;
          final bottom = y + item.y;
          switch (kind) {
            case _StrokeKind.line:
              canvas
                ..moveTo(left, bottom)
                ..lineTo(left + w, bottom + h);
            case _StrokeKind.rect:
              canvas.rect(PdfRect(left, bottom, w, h));
            case _StrokeKind.roundedRect:
              canvas.roundedRect(
                PdfRect(left, bottom, w, h),
                math.min(w, h) / 4,
              );
            case _StrokeKind.ellipse:
              canvas.ellipse(left + w / 2, bottom + h / 2, w / 2, h / 2);
          }
          canvas.stroke();
      }
      if (item.color != null) {
        canvas
          ..restore()
          ..save();
      }
    }
    canvas.restore();
  }

  @override
  void paint(PdfCanvas canvas, PdfRect rect) {
    final sx = width == 0 ? 1.0 : rect.width / width;
    final sy = height + depth == 0 ? 1.0 : rect.height / (height + depth);
    if ((sx - 1).abs() < 1e-6 && (sy - 1).abs() < 1e-6) {
      paintAt(canvas, rect.left, rect.bottom + depth);
      return;
    }
    canvas
      ..save()
      ..translate(rect.left, rect.bottom)
      ..scale(sx, sy);
    paintAt(canvas, 0, depth);
    canvas.restore();
  }
}

sealed class _Item {
  new(this.x, this.y, this.color);

  final double x;
  final double y;
  final PdfColor? color;

  _Item moved(double dx, double dy);
}

final class _Glyph extends _Item {
  new(
    this.font,
    this.glyph,
    this.text,
    this.advance,
    this.size,
    super.x,
    super.y,
    super.color,
  );

  final EmbeddedFont font;
  final int glyph;
  final String text;

  /// The advance, in 1000ths of the em.
  final double advance;
  final double size;

  @override
  _Item moved(double dx, double dy) =>
      _Glyph(font, glyph, text, advance, size, x + dx, y + dy, color);
}

final class _Rule extends _Item {
  new(super.x, super.y, this.w, this.h, super.color);

  final double w;
  final double h;

  @override
  _Item moved(double dx, double dy) => _Rule(x + dx, y + dy, w, h, color);
}

enum _StrokeKind { line, rect, roundedRect, ellipse }

final class _Stroke extends _Item {
  new(this.kind, super.x, super.y, this.w, this.h, this.lineWidth, super.color);

  final _StrokeKind kind;
  final double w;
  final double h;
  final double lineWidth;

  @override
  _Item moved(double dx, double dy) =>
      _Stroke(kind, x + dx, y + dy, w, h, lineWidth, color);
}

/// TeX's classes of atoms, for the space between them.
enum _Class { ord, op, bin, rel, open, close, punct, inner }

/// A part of a formula laid out (points, y up from its baseline).
final class _Box {
  new(
    this.width,
    this.height,
    this.depth,
    this.items, {
    this.italic = 0,
    this.accentAttach,
    this.cls = _Class.ord,
    this.token,
    this.largeOp = false,
    this.movableLimits = false,
    double? inkBottom,
  }) : inkBottom = inkBottom ?? -depth;

  static final _Box empty = _Box(0, 0, 0, const []);

  final double width;
  final double height;
  final double depth;
  final List<_Item> items;

  /// The italic correction of its last glyph.
  final double italic;

  /// Where an accent over it is centered, from its left (null: the
  /// middle).
  final double? accentAttach;

  _Class cls;

  /// The operator it is, when it is one alone (to stretch it).
  final ({String text, _Style style, bool stretchy})? token;

  final bool largeOp;
  final bool movableLimits;

  /// The lowest point of its ink (above the baseline for an accent).
  final double inkBottom;

  /// The items moved by ([dx], [dy]).
  List<_Item> shifted(double dx, double dy) => [
    for (final item in items) item.moved(dx, dy),
  ];
}

/// The style a part is set in: display or text, its script level, cramped
/// or not, and the color and variant it inherits.
final class _Style {
  const new({
    required this.display,
    required this.level,
    required this.cramped,
    this.color,
    this.variant,
  });

  final bool display;
  final int level;
  final bool cramped;
  final PdfColor? color;
  final String? variant;

  _Style copyWith({
    bool? display,
    int? level,
    bool? cramped,
    PdfColor? color,
    String? variant,
  }) => _Style(
    display: display ?? this.display,
    level: level ?? this.level,
    cramped: cramped ?? this.cramped,
    color: color ?? this.color,
    variant: variant ?? this.variant,
  );

  /// The style of a script of a part in this one.
  _Style script({bool? cramped}) => copyWith(
    display: false,
    level: level + 1,
    cramped: cramped ?? this.cramped,
  );
}

/// Lays out formulas in [font], which must have an OpenType `MATH` table.
final class MathLayout {
  /// A layout in [font]; a character it lacks in the first of
  /// [fallbacks] that has it.
  new(this.font, {this.fallbacks = const []})
    : _math = OpenTypeMathTable.parse(_mathTable(font.font));

  static Uint8List _mathTable(OpenTypeFont font) =>
      font.table('MATH') ?? (throw ArgumentError('the font has no MATH table'));

  /// The font, with a `MATH` table.
  final EmbeddedFont font;

  /// The fonts for the characters [font] lacks.
  final List<EmbeddedFont> fallbacks;

  final OpenTypeMathTable? _math;
  OpenTypeMathTable get _table => _math!;
  OpenTypeFont get _otf => font.font;

  late final double _upem = _otf.unitsPerEm.toDouble();

  double _base = 10;

  /// [node] set at [size] points, in display style when [display].
  MathBox layout(MathNode node, {required double size, bool display = false}) {
    _base = size;
    final box = _layout(
      node,
      _Style(display: display, level: 0, cramped: false),
    );
    return MathBox._(box.width, box.height, box.depth, box.items);
  }

  double _size(_Style s) {
    final level = math.max(0, s.level);
    if (level == 0) return _base;
    final factor = level == 1
        ? _table[MathConstant.scriptPercentScaleDown]
        : _table[MathConstant.scriptScriptPercentScaleDown];
    return _base * (factor == 0 ? (level == 1 ? 71 : 50) : factor) / 100;
  }

  /// [constant] in points at [s]'s size.
  double _c(MathConstant constant, _Style s) =>
      _table[constant] * _size(s) / _upem;

  double _em(_Style s) => _size(s);

  _Box _layout(MathNode node, _Style s) => switch (node) {
    MathToken() => _token(node, s),
    MathRow(:final children) => _row([
      for (final child in children) _layout(child, s),
    ], s),
    MathStyled() => _layout(node.child, _styled(node, s)),
    MathScripts(:final base, :final sub, :final sup) => _scripts(
      _layout(base, s),
      sub,
      sup,
      s,
    ),
    MathUnderOver() => _underOver(node, s),
    MathFraction() => _fraction(node, s),
    MathRadical() => _radical(node, s),
    MathTable() => _matrix(node, s),
    MathEnclose() => _enclose(node, s),
    MathSpace(:final width) => _Box(_length(width, s) ?? 0, 0, 0, const []),
  };

  _Style _styled(MathStyled node, _Style s) {
    var level = s.level;
    if (node.scriptLevel case final value?) {
      final n = int.tryParse(value.replaceFirst('+', ''));
      if (n != null) {
        level = value.startsWith('+') || value.startsWith('-') ? level + n : n;
      }
    }
    return s.copyWith(
      display: node.display,
      level: level,
      color: node.color,
      variant: node.variant,
    );
  }

  /// A length ([text]: `em`, `ex`, `pt`, `px`, `mu`, or a named space) in
  /// points.
  double? _length(String? text, _Style s) {
    if (text == null) return null;
    final value = text.trim();
    final named = switch (value) {
      'veryverythinmathspace' => 1 / 18,
      'verythinmathspace' => 2 / 18,
      'thinmathspace' => 3 / 18,
      'mediummathspace' => 4 / 18,
      'thickmathspace' => 5 / 18,
      'verythickmathspace' => 6 / 18,
      'veryverythickmathspace' => 7 / 18,
      _ => null,
    };
    if (named != null) return named * _em(s);
    final m = RegExp(r'^(-?[\d.]+)\s*([a-z%]*)$').firstMatch(value);
    if (m == null) return null;
    final n = double.tryParse(m[1]!);
    if (n == null) return null;
    return switch (m[2]) {
      'em' => n * _em(s),
      'ex' => n * _c(MathConstant.accentBaseHeight, s),
      'pt' || '' => n,
      'px' => n * 0.75,
      'mu' => n * _em(s) / 18,
      'in' => n * 72,
      'cm' => n * 72 / 2.54,
      'mm' => n * 72 / 25.4,
      _ => null,
    };
  }

  // Tokens.

  _Box _token(MathToken token, _Style s) {
    final variant = token.variant ?? s.variant;
    var text = token.text;
    var cls = _Class.ord;
    var largeOp = false;
    var movable = false;
    var stretchy = false;
    switch (token.kind) {
      case MathTokenKind.identifier:
        final single = text.runes.length == 1;
        text = _variant(text, variant ?? (single ? 'auto-italic' : 'normal'));
        if (!single && text.isNotEmpty) cls = _Class.op;
      case MathTokenKind.number || MathTokenKind.text:
        if (variant != null) text = _variant(text, variant);
      case MathTokenKind.operator:
        text = switch (text) {
          '-' => '\u2212',
          "'" => '\u2032',
          _ => text,
        };
        if (variant != null) text = _variant(text, variant);
        final info = _operator(text);
        cls = info.cls;
        largeOp = token.largeOperator ?? info.largeOp;
        movable = token.movableLimits ?? info.movable;
        stretchy = token.stretchy ?? info.stretchy;
        if (token.fence ?? false) {
          cls = token.form == 'postfix' ? _Class.close : cls;
        }
    }
    if (text.isEmpty) return _Box(0, 0, 0, const [], cls: cls);
    if (largeOp) return _largeOperator(text, s, cls, movable);
    final box = _glyphs(text, s, italicCorrection: true);
    return _Box(
      box.width,
      box.height,
      box.depth,
      box.items,
      italic: box.italic,
      accentAttach: box.accentAttach,
      inkBottom: box.inkBottom,
      cls: cls,
      token: token.kind == MathTokenKind.operator
          ? (text: text, style: s, stretchy: stretchy)
          : null,
      movableLimits: movable,
    );
  }

  /// [text] set glyph by glyph (the font's cmap; a character it lacks as
  /// its `.notdef`).
  _Box _glyphs(String text, _Style s, {bool italicCorrection = false}) {
    final size = _size(s);
    final scale = size / _upem;
    var x = 0.0;
    var top = 0.0;
    var bottom = 0.0;
    var ink = double.infinity;
    final items = <_Item>[];
    var last = 0;
    for (final rune in text.runes) {
      var glyph = _glyphOf(rune);
      var face = font;
      if (glyph == 0) {
        for (final fallback in fallbacks) {
          final other = fallback.font.glyphFor(rune);
          if (other != 0) {
            (face, glyph) = (fallback, other);
            break;
          }
        }
      }
      final otf = face.font;
      final upem = otf.unitsPerEm.toDouble();
      final faceScale = size / upem;
      final advance = otf.advance(glyph).toDouble();
      final (_, yMin, _, yMax) = otf.glyphBounds(glyph);
      items.add(
        _Glyph(
          face,
          glyph,
          String.fromCharCode(rune),
          advance * 1000 / upem,
          size,
          x,
          0,
          s.color,
        ),
      );
      top = math.max(top, yMax * faceScale);
      bottom = math.max(bottom, -yMin * faceScale);
      if (yMax > yMin) ink = math.min(ink, yMin * faceScale);
      x += advance * faceScale;
      last = face == font ? glyph : 0;
    }
    final italic = italicCorrection
        ? (_table.italicsCorrections[last] ?? 0) * scale
        : 0.0;
    final single = text.runes.length == 1;
    final attach = single
        ? switch (_table.topAccentAttachments[last]) {
            final a? => a * scale,
            null => null,
          }
        : null;
    return _Box(
      x,
      top,
      bottom,
      items,
      italic: italic,
      accentAttach: attach,
      inkBottom: ink.isFinite ? ink : 0,
    );
  }

  /// The glyph of [rune], or of the character that stands for it when
  /// the font lacks it (the angle brackets of U+2329 and U+232A, which
  /// Unicode deprecates for U+27E8 and U+27E9...).
  int _glyphOf(int rune) {
    final glyph = _otf.glyphFor(rune);
    if (glyph != 0) return glyph;
    final substitute = switch (rune) {
      0x2329 => 0x27e8,
      0x232a => 0x27e9,
      0x2010 || 0x2011 || 0x2012 || 0x2013 => 0x2212,
      0x00b7 => 0x22c5,
      0x2032 => 0x27,
      0x025b => 0x03b5,
      _ => null,
    };
    return substitute == null ? 0 : _otf.glyphFor(substitute);
  }

  /// A single glyph [glyph] (standing for [text]) at [s]'s size.
  _Box _glyph(int glyph, String text, _Style s) {
    final size = _size(s);
    final scale = size / _upem;
    final advance = _otf.advance(glyph).toDouble();
    final (_, yMin, _, yMax) = _otf.glyphBounds(glyph);
    return _Box(
      advance * scale,
      yMax * scale,
      -yMin * scale,
      [_Glyph(font, glyph, text, advance * 1000 / _upem, size, 0, 0, s.color)],
      italic: (_table.italicsCorrections[glyph] ?? 0) * scale,
      accentAttach: switch (_table.topAccentAttachments[glyph]) {
        final a? => a * scale,
        null => null,
      },
      inkBottom: yMin * scale,
    );
  }

  _Box _largeOperator(String text, _Style s, _Class cls, bool movable) {
    final glyph = _otf.glyphFor(text.runes.first);
    if (text.runes.length != 1 || glyph == 0) {
      final box = _glyphs(text, s);
      return _Box(
        box.width,
        box.height,
        box.depth,
        box.items,
        cls: _Class.op,
        largeOp: true,
        movableLimits: movable,
      );
    }
    var chosen = glyph;
    if (s.display) {
      final min = _table[MathConstant.displayOperatorMinHeight];
      final variants = _table.vertical(glyph)?.variants ?? const [];
      for (final v in variants) {
        chosen = v.glyph;
        if (v.advance >= min) break;
      }
      if (variants.isNotEmpty && chosen == glyph && variants.length > 1) {
        chosen = variants[1].glyph;
      }
    }
    final box = _glyph(chosen, text, s);
    // Centered on the math axis.
    final shift = _c(MathConstant.axisHeight, s) - (box.height - box.depth) / 2;
    return _Box(
      box.width,
      box.height + shift,
      box.depth - shift,
      box.shifted(0, shift),
      italic: box.italic,
      cls: _Class.op,
      largeOp: true,
      movableLimits: movable,
    );
  }

  // Rows.

  _Box _row(List<_Box> boxes, _Style s) {
    if (boxes.isEmpty) return _Box.empty;
    if (boxes.length == 1) return boxes.single;
    // Fences that may stretch: open and close delimiters (a bar opens at
    // the start of a row and closes at its end).
    for (final (i, box) in boxes.indexed) {
      final token = box.token;
      if (token == null) continue;
      if (_bars.contains(token.text)) {
        box.cls = i == 0
            ? _Class.open
            : i == boxes.length - 1
            ? _Class.close
            : _Class.ord;
      }
    }
    // The extent the stretchy delimiters cover: of everything else.
    var height = 0.0;
    var depth = 0.0;
    var hasOther = false;
    for (final box in boxes) {
      if (_isFence(box)) continue;
      hasOther = true;
      height = math.max(height, box.height);
      depth = math.max(depth, box.depth);
    }
    final stretched = [
      for (final box in boxes)
        if (_isFence(box) && hasOther)
          _stretchVertically(box, height, depth)
        else
          box,
    ];
    // TeX's binary operators: ordinary where nothing they could join is
    // on one side.
    for (var i = 0; i < stretched.length; i++) {
      final box = stretched[i];
      if (box.cls != _Class.bin) continue;
      final before = i == 0 ? null : stretched[i - 1].cls;
      final after = i + 1 < stretched.length ? stretched[i + 1].cls : null;
      if (before == null ||
          before == _Class.bin ||
          before == _Class.op ||
          before == _Class.rel ||
          before == _Class.open ||
          before == _Class.punct ||
          after == null ||
          after == _Class.rel ||
          after == _Class.close ||
          after == _Class.punct) {
        box.cls = _Class.ord;
      }
    }
    final items = <_Item>[];
    var x = 0.0;
    var top = 0.0;
    var bottom = 0.0;
    _Class? previous;
    for (final box in stretched) {
      if (previous != null) x += _space(previous, box.cls, s);
      items.addAll(box.shifted(x, 0));
      x += box.width;
      top = math.max(top, box.height);
      bottom = math.max(bottom, box.depth);
      previous = box.cls;
    }
    return _Box(x, top, bottom, items, italic: stretched.last.italic);
  }

  static const Set<String> _bars = {'|', '\u2016', '\u2225'};

  bool _isFence(_Box box) =>
      box.token != null &&
      box.token!.stretchy &&
      (box.cls == _Class.open || box.cls == _Class.close);

  /// TeX's space between an atom of [left] and one of [right] class:
  /// none, thin (1), medium (2) or thick (3); the medium and thick spaces
  /// (and the thin ones in parentheses in TeX's table) only outside
  /// scripts.
  double _space(_Class left, _Class right, _Style s) {
    const o = 0;
    const table = <List<int>>[
      // ord op bin rel open close punct inner
      [o, 1, -2, -3, o, o, o, -1], // ord
      [1, 1, o, -3, o, o, o, -1], // op
      [-2, -2, o, o, -2, o, o, -2], // bin
      [-3, -3, o, o, -3, o, o, -3], // rel
      [o, o, o, o, o, o, o, o], // open
      [o, 1, -2, -3, o, o, o, -1], // close
      [-1, -1, o, -1, -1, -1, -1, -1], // punct
      [-1, 1, -2, -3, -1, o, -1, -1], // inner
    ];
    final value = table[left.index][right.index];
    if (value == 0) return 0;
    if (value < 0 && s.level > 0) return 0;
    return switch (value.abs()) {
          1 => 3,
          2 => 4,
          _ => 5,
        } /
        18 *
        _em(s);
  }

  /// The delimiter [box] grown to cover [height] above and [depth] below
  /// the baseline, symmetric about the math axis (as TeX: 90% of it, or
  /// all of it but 5 points).
  _Box _stretchVertically(_Box box, double height, double depth) {
    final token = box.token!;
    final s = token.style;
    final axis = _c(MathConstant.axisHeight, s);
    final half = math.max(height - axis, depth + axis);
    final target = math.max(2 * half * 0.901, 2 * half - 5 * _base / 10);
    if (target <= box.height + box.depth) return box;
    final glyph = _glyphOf(token.text.runes.first);
    final construction = _table.vertical(glyph);
    if (construction == null) return box;
    final scale = _size(s) / _upem;
    _Box? grown;
    for (final v in construction.variants) {
      if (v.advance * scale >= target) {
        grown = _glyph(v.glyph, token.text, s);
        break;
      }
    }
    if (grown == null && construction.parts.isNotEmpty) {
      grown = _assembly(construction, token.text, target, s, vertical: true);
    }
    grown ??= _glyph(construction.variants.last.glyph, token.text, s);
    final shift = axis - (grown.height - grown.depth) / 2;
    return _Box(
      grown.width,
      grown.height + shift,
      grown.depth - shift,
      grown.shifted(0, shift),
      cls: box.cls,
      token: token,
    );
  }

  /// A glyph assembly of [construction] at least [target] points long:
  /// its parts end to end, the extenders repeated as often as it needs,
  /// the overlaps between parts shared out evenly.
  _Box _assembly(
    GlyphConstruction construction,
    String text,
    double target,
    _Style s, {
    required bool vertical,
  }) {
    final size = _size(s);
    final scale = size / _upem;
    final minOverlap = _table.minConnectorOverlap.toDouble();
    final goal = target / scale;
    final parts = construction.parts;
    List<GlyphPart> expanded(int repeats) => [
      for (final part in parts)
        if (part.extender)
          for (var r = 0; r < repeats; r++) part
        else
          part,
    ];
    double longest(List<GlyphPart> list) =>
        list.fold<double>(0, (sum, p) => sum + p.fullAdvance) -
        minOverlap * (list.length - 1);
    var repeats = 1;
    var list = expanded(repeats);
    while (longest(list) < goal &&
        repeats < 100 &&
        parts.any((p) => p.extender)) {
      list = expanded(++repeats);
    }
    // The overlap that makes it the goal's length (no less than the
    // minimum, no more than the connectors allow).
    var overlap = minOverlap;
    if (list.length > 1) {
      final total = list.fold<double>(0, (sum, p) => sum + p.fullAdvance);
      var most = double.infinity;
      for (var i = 0; i + 1 < list.length; i++) {
        most = math.min(
          most,
          math.min(list[i].endConnector, list[i + 1].startConnector).toDouble(),
        );
      }
      overlap = ((total - goal) / (list.length - 1)).clamp(
        minOverlap,
        math.max(minOverlap, most),
      );
    }
    final items = <_Item>[];
    var at = 0.0;
    var width = 0.0;
    var top = 0.0;
    var bottom = 0.0;
    for (final part in list) {
      final advance = _otf.advance(part.glyph).toDouble();
      final (xMin, yMin, xMax, yMax) = _otf.glyphBounds(part.glyph);
      if (vertical) {
        items.add(
          _Glyph(
            font,
            part.glyph,
            text,
            advance * 1000 / _upem,
            size,
            0,
            at * scale,
            s.color,
          ),
        );
        width = math.max(width, advance * scale);
        top = math.max(top, (at + yMax) * scale);
        bottom = math.min(bottom, (at + yMin) * scale);
      } else {
        items.add(
          _Glyph(
            font,
            part.glyph,
            text,
            advance * 1000 / _upem,
            size,
            at * scale,
            0,
            s.color,
          ),
        );
        width = math.max(width, (at + math.max(xMax, advance)) * scale);
        top = math.max(top, yMax * scale);
        bottom = math.min(bottom, yMin * scale);
      }
      at += part.fullAdvance - overlap;
    }
    // A vertical assembly starts at its baseline; as a glyph would, its
    // extent is from its lowest to its highest ink.
    return _Box(width, top, -bottom, items);
  }

  /// The operator [text] grown to [width] points wide (a horizontal
  /// variant or assembly), or null when it doesn't grow.
  _Box? _stretchHorizontally(String text, double width, _Style s) {
    if (text.runes.length != 1) return null;
    final glyph = _otf.glyphFor(text.runes.first);
    final construction = _table.horizontal(glyph);
    if (construction == null) return null;
    final scale = _size(s) / _upem;
    if (_otf.advance(glyph) * scale >= width) return null;
    for (final v in construction.variants) {
      if (v.advance * scale >= width) return _glyph(v.glyph, text, s);
    }
    if (construction.parts.isNotEmpty) {
      return _assembly(construction, text, width, s, vertical: false);
    }
    return _glyph(construction.variants.last.glyph, text, s);
  }

  // Scripts.

  _Box _scripts(_Box base, MathNode? subNode, MathNode? supNode, _Style s) {
    final sub = subNode == null
        ? null
        : _layout(subNode, s.script(cramped: true));
    final sup = supNode == null ? null : _layout(supNode, s.script());
    final token = base.token != null || base.items.length == 1;
    var u = 0.0;
    var v = 0.0;
    if (sup != null) {
      u = math.max(
        s.cramped
            ? _c(MathConstant.superscriptShiftUpCramped, s)
            : _c(MathConstant.superscriptShiftUp, s),
        math.max(
          token
              ? 0.0
              : base.height - _c(MathConstant.superscriptBaselineDropMax, s),
          sup.depth + _c(MathConstant.superscriptBottomMin, s),
        ),
      );
    }
    if (sub != null) {
      v = math.max(
        _c(MathConstant.subscriptShiftDown, s),
        math.max(
          token
              ? 0.0
              : base.depth + _c(MathConstant.subscriptBaselineDropMin, s),
          sub.height - _c(MathConstant.subscriptTopMax, s),
        ),
      );
    }
    if (sub != null && sup != null) {
      final gap = (u - sup.depth) - (sub.height - v);
      final min = _c(MathConstant.subSuperscriptGapMin, s);
      if (gap < min) {
        v += min - gap;
        final lift =
            _c(MathConstant.superscriptBottomMaxWithSubscript, s) -
            (u - sup.depth);
        if (lift > 0) {
          u += lift;
          v -= lift;
        }
      }
    }
    final supX = base.width + (base.largeOp ? 0 : base.italic);
    final subX = base.width - (base.largeOp ? base.italic : 0);
    final items = [...base.items];
    var width = base.width;
    var height = base.height;
    var depth = base.depth;
    if (sup != null) {
      items.addAll(sup.shifted(supX, u));
      width = math.max(width, supX + sup.width);
      height = math.max(height, u + sup.height);
      depth = math.max(depth, sup.depth - u);
    }
    if (sub != null) {
      items.addAll(sub.shifted(subX, -v));
      width = math.max(width, subX + sub.width);
      height = math.max(height, sub.height - v);
      depth = math.max(depth, v + sub.depth);
    }
    width += _c(MathConstant.spaceAfterScript, s);
    return _Box(width, height, depth, items, cls: base.cls);
  }

  // Under and over.

  static const Set<String> _bars2 = {
    '\u00af',
    '\u203e',
    '\u0305',
    '_',
    '\u0332',
  };

  _Box _underOver(MathUnderOver node, _Style s) {
    final base = _layout(node.base, s);
    // A large operator's limits, in text style: scripts.
    if (base.movableLimits && !s.display) {
      return _scripts(base, node.under, node.over, s);
    }
    final overStyle = node.accent ? s : s.script();
    final underStyle = node.accentUnder
        ? s.copyWith(cramped: true)
        : s.script(cramped: true);
    final items = [...base.items];
    var width = base.width;
    var height = base.height;
    var depth = base.depth;
    final pieces = <(_Box, double, double)>[]; // (box, x, y)

    _Box? stretched(MathNode? node, _Style style) {
      if (node case MathToken(kind: MathTokenKind.operator, :final text)) {
        return _stretchHorizontally(text, base.width, style);
      }
      return null;
    }

    final rule = _c(MathConstant.overbarRuleThickness, s);
    if (node.over case final overNode?) {
      if (overNode case MathToken(:final text) when _bars2.contains(text)) {
        // An overbar: a rule.
        final gap = _c(MathConstant.overbarVerticalGap, s);
        final bottom = base.height + gap;
        items.add(_Rule(0, bottom, base.width, rule, s.color));
        height = bottom + rule + _c(MathConstant.overbarExtraAscender, s);
      } else {
        final over =
            stretched(overNode, overStyle) ?? _layout(overNode, overStyle);
        final double y;
        if (node.accent) {
          // Its ink a rule's thickness over the base (or over the height
          // accents are drawn for, when the base is lower).
          y =
              math.max(base.height, _c(MathConstant.accentBaseHeight, s)) +
              rule -
              over.inkBottom;
        } else if (base.largeOp) {
          y =
              base.height +
              math.max(
                _c(MathConstant.upperLimitGapMin, s) + over.depth,
                _c(MathConstant.upperLimitBaselineRiseMin, s),
              );
        } else {
          y =
              base.height +
              _c(MathConstant.stretchStackGapAboveMin, s) +
              over.depth;
        }
        final double x;
        if (node.accent && over.width < base.width * 1.05) {
          final attach = base.accentAttach ?? base.width / 2;
          final own = over.accentAttach ?? over.width / 2;
          x = attach - own;
        } else {
          x =
              (base.width - over.width) / 2 +
              (base.largeOp ? base.italic / 2 : 0);
        }
        pieces.add((over, x, y));
        height = math.max(height, y + over.height);
      }
    }
    if (node.under case final underNode?) {
      if (underNode case MathToken(:final text) when _bars2.contains(text)) {
        final ruleUnder = _c(MathConstant.underbarRuleThickness, s);
        final top = -base.depth - _c(MathConstant.underbarVerticalGap, s);
        items.add(_Rule(0, top - ruleUnder, base.width, ruleUnder, s.color));
        depth = -top + ruleUnder + _c(MathConstant.underbarExtraDescender, s);
      } else {
        final under =
            stretched(underNode, underStyle) ?? _layout(underNode, underStyle);
        final double y;
        if (node.accentUnder) {
          y =
              -base.depth -
              _c(MathConstant.underbarVerticalGap, s) -
              under.height;
        } else if (base.largeOp) {
          y =
              -base.depth -
              math.max(
                _c(MathConstant.lowerLimitGapMin, s) + under.height,
                _c(MathConstant.lowerLimitBaselineDropMin, s),
              );
        } else {
          y =
              -base.depth -
              _c(MathConstant.stretchStackGapBelowMin, s) -
              under.height;
        }
        final x =
            (base.width - under.width) / 2 -
            (base.largeOp ? base.italic / 2 : 0);
        pieces.add((under, x, y));
        depth = math.max(depth, -y + under.depth);
      }
    }
    // Everything centered on the widest.
    var left = 0.0;
    for (final (box, x, _) in pieces) {
      left = math.min(left, x);
      width = math.max(width, x + box.width);
    }
    final shiftAll = -left;
    final all = <_Item>[
      for (final item in items) item.moved(shiftAll, 0),
      for (final (box, x, y) in pieces) ...box.shifted(x + shiftAll, y),
    ];
    return _Box(
      width + shiftAll,
      height,
      depth,
      all,
      cls: base.cls,
      accentAttach: base.accentAttach == null
          ? null
          : base.accentAttach! + shiftAll,
      italic: node.over == null ? base.italic : 0,
    );
  }

  // Fractions.

  _Box _fraction(MathFraction node, _Style s) {
    final inner = s.display ? s.copyWith(display: false) : s.script();
    final num = _layout(node.numerator, inner);
    final den = _layout(node.denominator, inner.copyWith(cramped: true));
    final axis = _c(MathConstant.axisHeight, s);
    final thickness = switch (node.lineThickness) {
      null || 'medium' => _c(MathConstant.fractionRuleThickness, s),
      'thin' => _c(MathConstant.fractionRuleThickness, s) / 2,
      'thick' => _c(MathConstant.fractionRuleThickness, s) * 2,
      final value =>
        double.tryParse(value) != null
            ? double.parse(value) * _c(MathConstant.fractionRuleThickness, s)
            : _length(value, s) ?? _c(MathConstant.fractionRuleThickness, s),
    };
    final display = s.display;
    double up;
    double down;
    if (thickness > 0) {
      up = math.max(
        display
            ? _c(MathConstant.fractionNumeratorDisplayStyleShiftUp, s)
            : _c(MathConstant.fractionNumeratorShiftUp, s),
        axis +
            thickness / 2 +
            (display
                ? _c(MathConstant.fractionNumDisplayStyleGapMin, s)
                : _c(MathConstant.fractionNumeratorGapMin, s)) +
            num.depth,
      );
      down = math.max(
        display
            ? _c(MathConstant.fractionDenominatorDisplayStyleShiftDown, s)
            : _c(MathConstant.fractionDenominatorShiftDown, s),
        den.height +
            (display
                ? _c(MathConstant.fractionDenomDisplayStyleGapMin, s)
                : _c(MathConstant.fractionDenominatorGapMin, s)) +
            thickness / 2 -
            axis,
      );
    } else {
      up = display
          ? _c(MathConstant.stackTopDisplayStyleShiftUp, s)
          : _c(MathConstant.stackTopShiftUp, s);
      down = display
          ? _c(MathConstant.stackBottomDisplayStyleShiftDown, s)
          : _c(MathConstant.stackBottomShiftDown, s);
      final gap = (up - num.depth) - (den.height - down);
      final min = display
          ? _c(MathConstant.stackDisplayStyleGapMin, s)
          : _c(MathConstant.stackGapMin, s);
      if (gap < min) {
        up += (min - gap) / 2;
        down += (min - gap) / 2;
      }
    }
    // A little space on each side (TeX's null delimiter space).
    final pad = 0.12 * _em(s);
    final width = math.max(num.width, den.width) + 2 * pad;
    final items = <_Item>[
      ...num.shifted((width - num.width) / 2, up),
      ...den.shifted((width - den.width) / 2, -down),
      if (thickness > 0)
        _Rule(pad, axis - thickness / 2, width - 2 * pad, thickness, s.color),
    ];
    return _Box(
      width,
      math.max(up + num.height, axis + thickness / 2),
      math.max(down + den.depth, thickness / 2 - axis),
      items,
      cls: _Class.inner,
    );
  }

  // Radicals.

  _Box _radical(MathRadical node, _Style s) {
    final radicand = _layout(node.radicand, s.copyWith(cramped: true));
    final thickness = _c(MathConstant.radicalRuleThickness, s);
    var gap = s.display
        ? _c(MathConstant.radicalDisplayStyleVerticalGap, s)
        : _c(MathConstant.radicalVerticalGap, s);
    final target = radicand.height + radicand.depth + gap + thickness;
    const sign = '\u221a';
    final glyph = _otf.glyphFor(sign.runes.first);
    final construction = _table.vertical(glyph);
    final scale = _size(s) / _upem;
    var surd = _glyph(glyph, sign, s);
    if (surd.height + surd.depth < target && construction != null) {
      _Box? grown;
      for (final v in construction.variants) {
        if (v.advance * scale >= target) {
          grown = _glyph(v.glyph, sign, s);
          break;
        }
      }
      if (grown == null && construction.parts.isNotEmpty) {
        grown = _assembly(construction, sign, target, s, vertical: true);
      }
      surd = grown ?? _glyph(construction.variants.last.glyph, sign, s);
    }
    // Any extra length of the sign: half of it to the gap.
    final extra = surd.height + surd.depth - target;
    if (extra > 0) gap += extra / 2;
    final ruleTop = radicand.height + gap + thickness;
    final surdShift = ruleTop - surd.height;
    final items = <_Item>[];
    var x = 0.0;
    var height = ruleTop + _c(MathConstant.radicalExtraAscender, s);
    final depth = math.max(radicand.depth, surd.depth - surdShift);
    if (node.index case final indexNode?) {
      final index = _layout(
        indexNode,
        s.copyWith(display: false, level: s.level + 2),
      );
      final before = _c(MathConstant.radicalKernBeforeDegree, s);
      final after = _c(MathConstant.radicalKernAfterDegree, s);
      final raise =
          _table[MathConstant.radicalDegreeBottomRaisePercent] /
              100 *
              (surd.height + surd.depth) -
          (surd.depth - surdShift);
      items.addAll(index.shifted(before, raise));
      x = math.max(0, before + index.width + after);
      height = math.max(height, raise + index.height);
    }
    items.addAll(surd.shifted(x, surdShift));
    x += surd.width;
    items
      ..add(_Rule(x, ruleTop - thickness, radicand.width, thickness, s.color))
      ..addAll(radicand.shifted(x, 0));
    return _Box(x + radicand.width, height, depth, items);
  }

  // Tables.

  _Box _matrix(MathTable node, _Style s) {
    final cellStyle = s.copyWith(display: false);
    final cells = [
      for (final row in node.rows)
        [for (final cell in row) _layout(cell, cellStyle)],
    ];
    if (cells.isEmpty) return _Box.empty;
    final columns = cells.fold<int>(0, (n, row) => math.max(n, row.length));
    final widths = List<double>.filled(columns, 0);
    for (final row in cells) {
      for (final (c, cell) in row.indexed) {
        widths[c] = math.max(widths[c], cell.width);
      }
    }
    final aligns = (node.columnAlign ?? 'center').split(RegExp(r'\s+'));
    String alignOf(int c) => aligns[math.min(c, aligns.length - 1)];
    final columnGap = 0.8 * _em(s);
    final rowGap = 0.5 * _em(s);
    final strutHeight = 0.7 * _em(s);
    final strutDepth = 0.3 * _em(s);
    final rows = [
      for (final row in cells)
        (
          height: row.fold<double>(
            strutHeight,
            (h, c) => math.max(h, c.height),
          ),
          depth: row.fold<double>(strutDepth, (d, c) => math.max(d, c.depth)),
        ),
    ];
    final total =
        rows.fold<double>(0, (t, r) => t + r.height + r.depth) +
        rowGap * (rows.length - 1);
    final axis = _c(MathConstant.axisHeight, s);
    final top = axis + total / 2;
    final items = <_Item>[];
    var y = top;
    for (final (r, row) in cells.indexed) {
      y -= rows[r].height;
      var x = 0.0;
      for (var c = 0; c < columns; c++) {
        if (c < row.length) {
          final cell = row[c];
          final dx = switch (alignOf(c)) {
            'left' => 0.0,
            'right' => widths[c] - cell.width,
            _ => (widths[c] - cell.width) / 2,
          };
          items.addAll(cell.shifted(x + dx, y));
        }
        x += widths[c] + columnGap;
      }
      y -= rows[r].depth + rowGap;
    }
    final width =
        widths.fold<double>(0, (a, b) => a + b) + columnGap * (columns - 1);
    return _Box(width, top, total - top, items, cls: _Class.inner);
  }

  // Enclosures.

  _Box _enclose(MathEnclose node, _Style s) {
    final child = _layout(node.child, s);
    final line = _c(MathConstant.fractionRuleThickness, s);
    final framed = node.notations.any(
      (n) => const {
        'box',
        'roundedbox',
        'circle',
        'top',
        'bottom',
        'left',
        'right',
        'longdiv',
        'actuarial',
      }.contains(n),
    );
    final pad = framed ? 0.2 * _em(s) + line : 0.0;
    final width = child.width + 2 * pad;
    final height = child.height + pad;
    final depth = child.depth + pad;
    final items = <_Item>[...child.shifted(pad, 0)];
    final color = s.color;
    for (final notation in node.notations) {
      switch (notation) {
        case 'box':
          items.add(
            _Stroke(
              _StrokeKind.rect,
              line / 2,
              -depth + line / 2,
              width - line,
              height + depth - line,
              line,
              color,
            ),
          );
        case 'roundedbox':
          items.add(
            _Stroke(
              _StrokeKind.roundedRect,
              line / 2,
              -depth + line / 2,
              width - line,
              height + depth - line,
              line,
              color,
            ),
          );
        case 'circle':
          items.add(
            _Stroke(
              _StrokeKind.ellipse,
              line / 2,
              -depth + line / 2,
              width - line,
              height + depth - line,
              line,
              color,
            ),
          );
        case 'updiagonalstrike':
          items.add(
            _Stroke(
              _StrokeKind.line,
              0,
              -depth,
              width,
              height + depth,
              line,
              color,
            ),
          );
        case 'downdiagonalstrike':
          items.add(
            _Stroke(
              _StrokeKind.line,
              0,
              height,
              width,
              -height - depth,
              line,
              color,
            ),
          );
        case 'horizontalstrike':
          final y = _c(MathConstant.axisHeight, s);
          items.add(_Stroke(_StrokeKind.line, 0, y, width, 0, line, color));
        case 'verticalstrike':
          items.add(
            _Stroke(
              _StrokeKind.line,
              width / 2,
              -depth,
              0,
              height + depth,
              line,
              color,
            ),
          );
        case 'top':
          items.add(_Rule(0, height - line, width, line, color));
        case 'bottom':
          items.add(_Rule(0, -depth, width, line, color));
        case 'left' || 'longdiv':
          items.add(_Rule(0, -depth, line, height + depth, color));
          if (notation == 'longdiv') {
            items.add(_Rule(0, height - line, width, line, color));
          }
        case 'right' || 'actuarial':
          items.add(_Rule(width - line, -depth, line, height + depth, color));
          if (notation == 'actuarial') {
            items.add(_Rule(0, height - line, width, line, color));
          }
      }
    }
    return _Box(width, height, depth, items);
  }

  // Operators.

  static const String _relations =
      '=<>\u2264\u2265\u2260\u2248\u2261\u223c\u2245\u221d\u2192\u2190'
      '\u2194\u21d2\u21d0\u21d4\u21a6\u2208\u2209\u220b\u2282\u2283\u2286'
      '\u2287\u2284\u2285\u227a\u227b\u2aaf\u2ab0\u2223\u22a5\u2225\u226a'
      '\u226b\u22a8\u22a2\u22a3\u2254\u2243\u2250\u21c4\u21c6\u27f6\u27f5'
      '\u27f9\u27f8\u27fa\u21aa\u21a9\u2197\u2198\u2196\u2199\u21bf\u21be'
      '\u2191\u2193\u21d1\u21d3\u21cb\u21cc\u2a7d\u2a7e\u2272\u2273\u2266'
      '\u2267\u2259\u225c\u2234\u2235:';
  static const String _binaries =
      '+\u2212\u00b1\u2213\u00d7\u00f7\u22c5\u2218\u2217\u22c6\u2229\u222a'
      '\u2227\u2228\u2295\u2297\u2299\u2216\u22c9\u22ca\u2296\u2298\u229a'
      '\u228e\u2293\u2294\u25b3\u25bd\u2020\u2021\u2240\u22c4';
  static const String _opens = '([{\u27e8\u230a\u2308\u2329\u27e6\u2983';
  static const String _closes = ')]}\u27e9\u230b\u2309\u232a\u27e7\u2984';
  static const String _largeOps =
      '\u2211\u220f\u2210\u222b\u222c\u222d\u222e\u222f\u2230\u22c3\u22c2'
      '\u22c1\u22c0\u2a00\u2a01\u2a02\u2a04\u2a06\u2a0c';
  static const String _integrals = '\u222b\u222c\u222d\u222e\u222f\u2230\u2a0c';
  static const Set<String> _limitWords = {
    'lim',
    'max',
    'min',
    'sup',
    'inf',
    'det',
    'gcd',
    'Pr',
    'liminf',
    'limsup',
  };

  ({_Class cls, bool largeOp, bool movable, bool stretchy}) _operator(
    String text,
  ) {
    if (text.runes.length > 1) {
      if (_limitWords.contains(text)) {
        return (cls: _Class.op, largeOp: false, movable: true, stretchy: false);
      }
      if (text.runes.every(
        (r) => _relations.contains(String.fromCharCode(r)),
      )) {
        return (
          cls: _Class.rel,
          largeOp: false,
          movable: false,
          stretchy: false,
        );
      }
      final letters = RegExp(r'^\p{L}+$', unicode: true).hasMatch(text);
      return (
        cls: letters ? _Class.op : _Class.ord,
        largeOp: false,
        movable: false,
        stretchy: false,
      );
    }
    if (_largeOps.contains(text)) {
      return (
        cls: _Class.op,
        largeOp: true,
        movable: !_integrals.contains(text),
        stretchy: false,
      );
    }
    if (_opens.contains(text)) {
      return (cls: _Class.open, largeOp: false, movable: false, stretchy: true);
    }
    if (_closes.contains(text)) {
      return (
        cls: _Class.close,
        largeOp: false,
        movable: false,
        stretchy: true,
      );
    }
    if (_bars.contains(text)) {
      return (cls: _Class.ord, largeOp: false, movable: false, stretchy: true);
    }
    if (_relations.contains(text)) {
      return (cls: _Class.rel, largeOp: false, movable: false, stretchy: false);
    }
    if (_binaries.contains(text)) {
      return (cls: _Class.bin, largeOp: false, movable: false, stretchy: false);
    }
    if (text == ',' || text == ';') {
      return (
        cls: _Class.punct,
        largeOp: false,
        movable: false,
        stretchy: false,
      );
    }
    return (cls: _Class.ord, largeOp: false, movable: false, stretchy: false);
  }

  // Variants (Unicode's Mathematical Alphanumeric Symbols).

  static const Map<String, (int?, int?, int?, int?, int?)> _variantStarts = {
    // capital, small, digit, Greek capital, Greek small
    'bold': (0x1d400, 0x1d41a, 0x1d7ce, 0x1d6a8, 0x1d6c2),
    'italic': (0x1d434, 0x1d44e, null, 0x1d6e2, 0x1d6fc),
    'bold-italic': (0x1d468, 0x1d482, null, 0x1d71c, 0x1d736),
    'script': (0x1d49c, 0x1d4b6, null, null, null),
    'bold-script': (0x1d4d0, 0x1d4ea, null, null, null),
    'fraktur': (0x1d504, 0x1d51e, null, null, null),
    'double-struck': (0x1d538, 0x1d552, 0x1d7d8, null, null),
    'bold-fraktur': (0x1d56c, 0x1d586, null, null, null),
    'sans-serif': (0x1d5a0, 0x1d5ba, 0x1d7e2, null, null),
    'bold-sans-serif': (0x1d5d4, 0x1d5ee, 0x1d7ec, 0x1d756, 0x1d770),
    'sans-serif-italic': (0x1d608, 0x1d622, null, null, null),
    'sans-serif-bold-italic': (0x1d63c, 0x1d656, null, 0x1d790, 0x1d7aa),
    'monospace': (0x1d670, 0x1d68a, 0x1d7f6, null, null),
  };

  /// The letters Unicode encodes outside the block (its holes).
  static const Map<String, Map<String, int>> _holes = {
    'italic': {'h': 0x210e},
    'script': {
      'B': 0x212c,
      'E': 0x2130,
      'F': 0x2131,
      'H': 0x210b,
      'I': 0x2110,
      'L': 0x2112,
      'M': 0x2133,
      'R': 0x211b,
      'e': 0x212f,
      'g': 0x210a,
      'o': 0x2134,
    },
    'fraktur': {
      'C': 0x212d,
      'H': 0x210c,
      'I': 0x2111,
      'R': 0x211c,
      'Z': 0x2128,
    },
    'double-struck': {
      'C': 0x2102,
      'H': 0x210d,
      'N': 0x2115,
      'P': 0x2119,
      'Q': 0x211a,
      'R': 0x211d,
      'Z': 0x2124,
    },
  };

  /// [text] in the characters of [variant] (`auto-italic`: a single
  /// identifier's, italic for Latin letters and small Greek ones).
  String _variant(String text, String variant) {
    if (variant == 'normal') return text;
    final greekCapitals = variant != 'auto-italic';
    final name = variant == 'auto-italic' ? 'italic' : variant;
    final starts = _variantStarts[name];
    if (starts == null) return text;
    final (capital, small, digit, greekCapital, greekSmall) = starts;
    final holes = _holes[name] ?? const {};
    return String.fromCharCodes([
      for (final rune in text.runes)
        if (holes[String.fromCharCode(rune)] case final hole?)
          hole
        else if (rune >= 0x41 && rune <= 0x5a && capital != null)
          capital + rune - 0x41
        else if (rune >= 0x61 && rune <= 0x7a && small != null)
          small + rune - 0x61
        else if (rune >= 0x30 && rune <= 0x39 && digit != null)
          digit + rune - 0x30
        else if (rune >= 0x391 &&
            rune <= 0x3a9 &&
            greekCapital != null &&
            greekCapitals)
          greekCapital + rune - 0x391
        else if (rune >= 0x3b1 && rune <= 0x3c9 && greekSmall != null)
          greekSmall + rune - 0x3b1
        else
          rune,
    ]);
  }
}

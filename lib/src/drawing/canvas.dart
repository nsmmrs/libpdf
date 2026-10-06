/// The canvas pages and forms are drawn on: a typed front for the
/// content-stream operators (ISO 32000-2, 8 and 9), keeping track of the
/// resources the content uses. There is no hidden state beyond what PDF
/// itself keeps (the graphics state stack): text is always drawn at an
/// explicit position.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:libpdf/src/drawing/color.dart';
import 'package:libpdf/src/drawing/geometry.dart';
import 'package:libpdf/src/drawing/shading.dart';
import 'package:libpdf/src/fonts/fonts.dart';
import 'package:libpdf/src/images/images.dart';
import 'package:libpdf/src/objects.dart';
import 'package:libpdf/src/reader/reader.dart';
import 'package:meta/meta.dart';

/// The shape at the ends of stroked open lines.
enum LineCap {
  /// Squared off at the end.
  butt,

  /// A semicircle around the end.
  round,

  /// Squared off half the line width past the end.
  projectingSquare,
}

/// The shape of corners of stroked lines.
enum LineJoin {
  /// A pointed corner, beveled past the miter limit.
  miter,

  /// A rounded corner.
  round,

  /// A beveled corner.
  bevel,
}

/// How text is painted (ISO 32000-2, 9.3.6).
enum TextRenderMode {
  /// Filled.
  fill,

  /// Stroked.
  stroke,

  /// Filled, then stroked.
  fillStroke,

  /// Neither (invisible, still selectable).
  invisible,

  /// Filled, and added to the clipping path.
  fillClip,

  /// Stroked, and added to the clipping path.
  strokeClip,

  /// Filled, stroked, and added to the clipping path.
  fillStrokeClip,

  /// Added to the clipping path.
  clip,
}

/// How colors painted over others combine (ISO 32000-2, 11.3.5).
enum BlendMode {
  /// The source color.
  normal('Normal'),

  /// Multiplied.
  multiply('Multiply'),

  /// Screened.
  screen('Screen'),

  /// Multiply or screen, by the backdrop.
  overlay('Overlay'),

  /// The darker.
  darken('Darken'),

  /// The lighter.
  lighten('Lighten'),

  /// Backdrop brightened.
  colorDodge('ColorDodge'),

  /// Backdrop darkened.
  colorBurn('ColorBurn'),

  /// Multiply or screen, by the source.
  hardLight('HardLight'),

  /// Darken or lighten, by the source.
  softLight('SoftLight'),

  /// The difference.
  difference('Difference'),

  /// Like difference, lower in contrast.
  exclusion('Exclusion');

  new(this.pdfName);

  /// The blend mode's PDF name.
  final String pdfName;
}

/// What a soft mask takes from its form (ISO 32000-2, 11.6.5.2).
enum SoftMaskKind {
  /// The luminosity of the form's colors.
  luminosity('Luminosity'),

  /// The form's alpha.
  alpha('Alpha');

  new(this.pdfName);

  /// The kind's PDF name.
  final String pdfName;
}

/// How text is set: the font and size, and the text state parameters.
@immutable
final class PdfTextStyle {
  /// Text in [font] at [size] points.
  const new(
    this.font,
    this.size, {
    this.characterSpacing = 0,
    this.wordSpacing = 0,
    this.rise = 0,
    this.horizontalScaling = 100,
    this.renderMode = TextRenderMode.fill,
    this.kerning = true,
    this.ligatures = false,
    this.features = const {},
  });

  /// The font.
  final PdfFont font;

  /// The size, in points.
  final double size;

  /// Extra space after each glyph, in points.
  final double characterSpacing;

  /// Extra space after each space, in points.
  final double wordSpacing;

  /// The baseline's shift up, in points.
  final double rise;

  /// The horizontal scaling, in percent.
  final double horizontalScaling;

  /// How the glyphs are painted.
  final TextRenderMode renderMode;

  /// Whether the font's kerning applies.
  final bool kerning;

  /// Whether the font's ligatures apply (embedded fonts).
  final bool ligatures;

  /// The OpenType features whose single substitutions apply (embedded
  /// fonts that have them: `onum` old-style numerals, `smcp` small
  /// capitals...).
  final Set<String> features;

  /// This style with the values given changed.
  PdfTextStyle copyWith({
    PdfFont? font,
    double? size,
    double? characterSpacing,
    double? wordSpacing,
    double? rise,
    double? horizontalScaling,
    TextRenderMode? renderMode,
    bool? kerning,
    bool? ligatures,
    Set<String>? features,
  }) => PdfTextStyle(
    font ?? this.font,
    size ?? this.size,
    characterSpacing: characterSpacing ?? this.characterSpacing,
    wordSpacing: wordSpacing ?? this.wordSpacing,
    rise: rise ?? this.rise,
    horizontalScaling: horizontalScaling ?? this.horizontalScaling,
    renderMode: renderMode ?? this.renderMode,
    kerning: kerning ?? this.kerning,
    ligatures: ligatures ?? this.ligatures,
    features: features ?? this.features,
  );

  @override
  bool operator ==(Object other) =>
      other is PdfTextStyle &&
      other.font == font &&
      other.size == size &&
      other.characterSpacing == characterSpacing &&
      other.wordSpacing == wordSpacing &&
      other.rise == rise &&
      other.horizontalScaling == horizontalScaling &&
      other.renderMode == renderMode &&
      other.kerning == kerning &&
      other.ligatures == ligatures &&
      other.features.length == features.length &&
      other.features.containsAll(features);

  @override
  int get hashCode => Object.hash(
    font,
    size,
    characterSpacing,
    wordSpacing,
    rise,
    horizontalScaling,
    renderMode,
    kerning,
    ligatures,
    Object.hashAllUnordered(features),
  );

  /// The width of [glyphs] set in this style, in points.
  double widthOf(List<ShapedGlyph> glyphs) {
    var width = 0.0;
    for (final (i, glyph) in glyphs.indexed) {
      width += glyph.advance * size / 1000 + characterSpacing;
      if (glyph.text == ' ') width += wordSpacing;
      if (i < glyphs.length - 1) width += glyph.kerning * size / 1000;
    }
    return width * horizontalScaling / 100;
  }

  /// The width of [text] set in this style, in points.
  double measure(String text) => widthOf(shape(text));

  /// [text] as glyphs of this style's font.
  List<ShapedGlyph> shape(String text) => font.shape(
    text,
    kerning: kerning,
    ligatures: ligatures,
    features: features,
  );
}

/// A transparency group (ISO 32000-2, 11.6.6): a form painted as one
/// object.
@immutable
final class TransparencyGroup {
  /// A group; [isolated] ones start from a transparent backdrop,
  /// [knockout] ones paint each object over the group's backdrop rather
  /// than over each other.
  const new({this.isolated = false, this.knockout = false});

  /// Whether the group is isolated.
  final bool isolated;

  /// Whether the group is a knockout group.
  final bool knockout;
}

/// A form XObject: content drawn once and painted wherever it is used
/// (ISO 32000-2, 8.10), also the content of soft masks.
final class PdfForm {
  /// A form whose content is in [bbox], drawn by [draw].
  new(
    this.bbox,
    void Function(PdfCanvas canvas) draw, {
    this.group,
    this.matrix,
  }) {
    draw(_canvas);
    if (_canvas._unbalanced case final problem?) throw StateError(problem);
  }

  /// The form's bounding box, in its own space.
  final PdfRect bbox;

  /// The transparency group the form is, if any.
  final TransparencyGroup? group;

  /// The transformation from form space to the space it is painted in.
  final PdfMatrix? matrix;

  final PdfCanvas _canvas = PdfCanvas._();
}

/// The canvas [form] is drawn on.
@internal
PdfCanvas formCanvas(PdfForm form) => form._canvas;

/// A new, empty canvas (for a page).
@internal
PdfCanvas newCanvas() => PdfCanvas._();

/// The resources [canvas]'s content uses, by category (`Font`,
/// `XObject`, `ExtGState`, `ColorSpace`, `Shading`) and name.
@internal
Map<String, Map<String, Resource>> canvasResources(PdfCanvas canvas) =>
    canvas._resources;

/// The content stream of [canvas].
@internal
Uint8List canvasContent(PdfCanvas canvas) => canvas._content.toBytes();

/// Whether [canvas]'s content uses transparency.
@internal
bool canvasUsesTransparency(PdfCanvas canvas) => canvas._usesTransparency;

/// What is left open at the end of [canvas]'s content (a save without its
/// restore, an unpainted path), or null.
@internal
String? canvasUnbalanced(PdfCanvas canvas) => canvas._unbalanced;

/// A resource content refers to by name.
@internal
sealed class Resource {
  const new();
}

/// A font.
@internal
final class FontResource extends Resource {
  /// The resource of [font].
  const new(this.font);

  /// The font.
  final PdfFont font;
}

/// An image.
@internal
final class ImageResource extends Resource {
  /// The resource of [image].
  const new(this.image);

  /// The image.
  final PdfImage image;
}

/// A form.
@internal
final class FormResource extends Resource {
  /// The resource of [form].
  const new(this.form);

  /// The form.
  final PdfForm form;
}

/// A page of another file.
@internal
final class ImportedPageResource extends Resource {
  /// The resource of [page].
  const new(this.page);

  /// The page.
  final ImportedPage page;
}

/// A spot color's Separation color space.
@internal
final class SeparationResource extends Resource {
  /// The color space of [name], approximated by [alternate].
  const new(this.name, this.alternate);

  /// The colorant.
  final String name;

  /// Its CMYK alternate.
  final CmykColor alternate;
}

/// A shading.
@internal
final class ShadingResource extends Resource {
  /// The resource of [shading].
  const new(this.shading);

  /// The shading.
  final PdfShading shading;
}

/// Graphics state parameters (an ExtGState dictionary).
@internal
final class GraphicsStateResource extends Resource {
  /// The parameters: opacity, blend mode, soft mask.
  const new({
    this.fillOpacity,
    this.strokeOpacity,
    this.blendMode,
    this.softMask,
    this.clearSoftMask = false,
  });

  /// The fill opacity (`ca`).
  final double? fillOpacity;

  /// The stroke opacity (`CA`).
  final double? strokeOpacity;

  /// The blend mode (`BM`).
  final BlendMode? blendMode;

  /// The soft mask (`SMask`): its form and kind.
  final (PdfForm, SoftMaskKind)? softMask;

  /// Whether the parameters remove the soft mask (`/SMask /None`).
  final bool clearSoftMask;
}

/// A page's or form's content: operators appended in order.
final class PdfCanvas {
  new _();

  final BytesBuilder _content = BytesBuilder();

  final Map<String, Map<String, Resource>> _resources = {};

  final Map<Object, String> _names = {};

  int _depth = 0;
  bool _path = false;

  bool _usesTransparency = false;

  String? get _unbalanced => _depth != 0
      ? '$_depth save() calls without restore()'
      : _path
      ? 'a path was left without painting it'
      : null;

  void _op(String operator, [List<num> operands = const []]) {
    final line = StringBuffer();
    for (final operand in operands) {
      line
        ..write(formatNumber(operand))
        ..write(' ');
    }
    line
      ..write(operator)
      ..write('\n');
    _content.add(latin1.encode(line.toString()));
  }

  void _named(String operator, String name, [List<num> operands = const []]) {
    final line = StringBuffer();
    for (final operand in operands) {
      line
        ..write(formatNumber(operand))
        ..write(' ');
    }
    _content
      ..add(latin1.encode(line.toString()))
      ..add(PdfName(name).toBytes())
      ..add(latin1.encode(' $operator\n'));
  }

  /// The name [resource] has in [category], given by its first use.
  String _use(String category, Object key, Resource resource, String prefix) {
    final name = _names[key] ??= '$prefix${_names.length + 1}';
    (_resources[category] ??= {})[name] = resource;
    return name;
  }

  void _noPath(String what) {
    if (_path) throw StateError('$what inside a path: paint it first');
  }

  // Graphics state.

  /// Saves the graphics state (`q`).
  void save() {
    _noPath('save()');
    _depth += 1;
    _op('q');
  }

  /// Restores the graphics state saved last (`Q`).
  void restore() {
    _noPath('restore()');
    if (_depth == 0) throw StateError('restore() without save()');
    _depth -= 1;
    _op('Q');
  }

  /// Runs [draw] between [save] and [restore].
  void saved(void Function() draw) {
    save();
    draw();
    restore();
  }

  /// Transforms the coordinate system by [matrix] (`cm`).
  void transform(PdfMatrix matrix) {
    _noPath('transform()');
    _op('cm', [matrix.a, matrix.b, matrix.c, matrix.d, matrix.e, matrix.f]);
  }

  /// Moves the origin to ([x], [y]).
  void translate(double x, double y) => transform(PdfMatrix.translation(x, y));

  /// Scales by [x] horizontally and [y] (default [x]) vertically.
  void scale(double x, [double? y]) => transform(PdfMatrix.scaling(x, y ?? x));

  /// Rotates counterclockwise by [degrees].
  void rotate(double degrees) =>
      transform(PdfMatrix.rotation(degrees * math.pi / 180));

  /// The width of stroked lines (`w`).
  void setLineWidth(double width) => _op('w', [width]);

  /// The shape of line ends (`J`).
  void setLineCap(LineCap cap) => _op('J', [cap.index]);

  /// The shape of corners (`j`).
  void setLineJoin(LineJoin join) => _op('j', [join.index]);

  /// The miter limit (`M`).
  void setMiterLimit(double limit) => _op('M', [limit]);

  /// The dash pattern (`d`): alternating dash and gap lengths starting at
  /// [phase]; empty for solid lines.
  void dash(List<double> pattern, [double phase = 0]) {
    final out = BytesBuilder();
    PdfArray.numbers(pattern).writeTo(out);
    _content
      ..add(out.takeBytes())
      ..add(latin1.encode(' ${formatNumber(phase)} d\n'));
  }

  /// The color of fills, text included.
  void setFillColor(PdfColor color) => _color(color, stroke: false);

  /// The color of strokes.
  void setStrokeColor(PdfColor color) => _color(color, stroke: true);

  void _color(PdfColor color, {required bool stroke}) {
    switch (color) {
      case GrayColor(:final level):
        _op(stroke ? 'G' : 'g', [level]);
      case RgbColor(:final red, :final green, :final blue):
        _op(stroke ? 'RG' : 'rg', [red, green, blue]);
      case CmykColor(:final cyan, :final magenta, :final yellow, :final black):
        _op(stroke ? 'K' : 'k', [cyan, magenta, yellow, black]);
      case SpotColor(:final name, :final alternate, :final tint):
        final space = _use(
          'ColorSpace',
          ('separation', name, alternate),
          SeparationResource(name, alternate),
          'CS',
        );
        _named(stroke ? 'CS' : 'cs', space);
        _op(stroke ? 'SCN' : 'scn', [tint]);
    }
  }

  void _graphicsState(Object key, GraphicsStateResource state) {
    _noPath('a graphics state change');
    _usesTransparency = true;
    _named('gs', _use('ExtGState', key, state, 'GS'));
  }

  /// The opacity of fills and of strokes (0 transparent, 1 opaque).
  void opacity({double? fill, double? stroke}) => _graphicsState((
    'opacity',
    fill,
    stroke,
  ), GraphicsStateResource(fillOpacity: fill, strokeOpacity: stroke));

  /// The blend mode.
  void setBlendMode(BlendMode mode) =>
      _graphicsState(('blend', mode), GraphicsStateResource(blendMode: mode));

  /// Masks what is painted next by [mask] (a form with a transparency
  /// group), until the state is restored or [clearSoftMask] is called.
  void softMask(PdfForm mask, {SoftMaskKind kind = SoftMaskKind.luminosity}) {
    if (mask.group == null) {
      throw ArgumentError.value(
        mask,
        'mask',
        'a soft mask must be a form with a transparency group',
      );
    }
    _graphicsState((
      'softMask',
      mask,
      kind,
    ), GraphicsStateResource(softMask: (mask, kind)));
  }

  /// Removes the soft mask.
  void clearSoftMask() => _graphicsState(
    'clearSoftMask',
    const GraphicsStateResource(clearSoftMask: true),
  );

  // Paths.

  /// Starts a subpath at ([x], [y]) (`m`).
  void moveTo(double x, double y) {
    _path = true;
    _op('m', [x, y]);
  }

  /// A line to ([x], [y]) (`l`).
  void lineTo(double x, double y) {
    _needPath('lineTo()');
    _op('l', [x, y]);
  }

  /// A cubic Bézier curve to ([x3], [y3]) with control points ([x1],
  /// [y1]) and ([x2], [y2]) (`c`).
  void curveTo(
    double x1,
    double y1,
    double x2,
    double y2,
    double x3,
    double y3,
  ) {
    _needPath('curveTo()');
    _op('c', [x1, y1, x2, y2, x3, y3]);
  }

  /// Closes the subpath (`h`).
  void closePath() {
    _needPath('closePath()');
    _op('h');
  }

  void _needPath(String what) {
    if (!_path) throw StateError('$what needs a current point: moveTo() first');
  }

  /// A rectangle (`re`).
  void rect(PdfRect rect) {
    _path = true;
    _op('re', [rect.left, rect.bottom, rect.width, rect.height]);
  }

  /// A rectangle with corners rounded to [radius].
  void roundedRect(PdfRect rect, double radius) {
    final r = math.min(radius, math.min(rect.width, rect.height) / 2);
    if (r <= 0) return this.rect(rect);
    final k = r * _kappa;
    final PdfRect(:left, :bottom, :right, :top) = rect;
    moveTo(left + r, bottom);
    lineTo(right - r, bottom);
    curveTo(right - r + k, bottom, right, bottom + r - k, right, bottom + r);
    lineTo(right, top - r);
    curveTo(right, top - r + k, right - r + k, top, right - r, top);
    lineTo(left + r, top);
    curveTo(left + r - k, top, left, top - r + k, left, top - r);
    lineTo(left, bottom + r);
    curveTo(left, bottom + r - k, left + r - k, bottom, left + r, bottom);
    closePath();
  }

  /// An ellipse centered on ([cx], [cy]) with radii [rx] and [ry], as four
  /// Bézier curves.
  void ellipse(double cx, double cy, double rx, double ry) {
    final kx = rx * _kappa;
    final ky = ry * _kappa;
    moveTo(cx + rx, cy);
    curveTo(cx + rx, cy + ky, cx + kx, cy + ry, cx, cy + ry);
    curveTo(cx - kx, cy + ry, cx - rx, cy + ky, cx - rx, cy);
    curveTo(cx - rx, cy - ky, cx - kx, cy - ry, cx, cy - ry);
    curveTo(cx + kx, cy - ry, cx + rx, cy - ky, cx + rx, cy);
    closePath();
  }

  /// A circle centered on ([cx], [cy]) of [radius].
  void circle(double cx, double cy, double radius) =>
      ellipse(cx, cy, radius, radius);

  /// The control point distance of a quarter circle of radius 1.
  static final double _kappa = 4 * (math.sqrt(2) - 1) / 3;

  void _paint(String operator) {
    _needPath('painting');
    _path = false;
    _op(operator);
  }

  /// Fills the path (`f`, or `f*` with the even-odd rule).
  void fill({bool evenOdd = false}) => _paint(evenOdd ? 'f*' : 'f');

  /// Strokes the path (`S`).
  void stroke() => _paint('S');

  /// Fills, then strokes the path (`B`, or `B*`).
  void fillAndStroke({bool evenOdd = false}) => _paint(evenOdd ? 'B*' : 'B');

  /// Intersects the clipping path with the path, without painting it
  /// (`W n`, or `W* n`).
  void clip({bool evenOdd = false}) {
    _needPath('clip()');
    _op(evenOdd ? 'W*' : 'W');
    _paint('n');
  }

  /// Ends the path without painting it (`n`).
  void endPath() => _paint('n');

  /// Paints [shading] over the clipping region (`sh`): clip to a path
  /// first to fill it with a gradient.
  void shade(PdfShading shading) {
    _noPath('shade()');
    _named('sh', _use('Shading', shading, ShadingResource(shading), 'Sh'));
  }

  // Images and forms.

  /// Paints [image] into [rect].
  void image(PdfImage image, PdfRect rect) {
    _noPath('image()');
    final name = _use('XObject', image, ImageResource(image), 'Im');
    _op('q');
    _op('cm', [rect.width, 0, 0, rect.height, rect.left, rect.bottom]);
    _named('Do', name);
    _op('Q');
  }

  /// Paints [page], a page of another file, into [rect].
  void page(ImportedPage page, PdfRect rect) {
    _noPath('page()');
    if (page.group != null) _usesTransparency = true;
    final name = _use('XObject', page, ImportedPageResource(page), 'Pg');
    final m = page.placement(rect);
    _op('q');
    _op('cm', [m.a, m.b, m.c, m.d, m.e, m.f]);
    _named('Do', name);
    _op('Q');
  }

  /// Paints [form] (`Do`).
  void form(PdfForm form) {
    _noPath('form()');
    if (form.group != null || form._canvas._usesTransparency) {
      _usesTransparency = true;
    }
    _named('Do', _use('XObject', form, FormResource(form), 'Fm'));
  }

  // Marked content.

  /// Begins a marked-content sequence tagged [tag] (ISO 32000-2, 14.6),
  /// to end with [endMarkedContent]. With [actualText], the sequence's
  /// content reads as that text when text is extracted, copied or read
  /// aloud (14.9.4): an empty one leaves decorative glyphs out.
  void beginMarkedContent(String tag, {String? actualText}) {
    _noPath('marked content');
    _content.add(PdfName(tag).toBytes());
    if (actualText != null) {
      _content
        ..add(latin1.encode(' '))
        ..add(PdfDict({'ActualText': PdfString.text(actualText)}).toBytes())
        ..add(latin1.encode(' BDC\n'));
    } else {
      _content.add(latin1.encode(' BMC\n'));
    }
  }

  /// Ends the marked-content sequence [beginMarkedContent] began.
  void endMarkedContent() => _op('EMC');

  // Text.

  /// Draws [text] in [style] with its baseline starting at ([x], [y]);
  /// returns its width.
  double text(String text, double x, double y, PdfTextStyle style) =>
      glyphs(style.shape(text), x, y, style);

  /// Draws shaped [glyphs] of [style]'s font with the baseline starting
  /// at ([x], [y]); returns their width.
  double glyphs(
    List<ShapedGlyph> glyphs,
    double x,
    double y,
    PdfTextStyle style,
  ) {
    _noPath('text');
    final font = style.font;
    final fontName = _use('Font', font, FontResource(font), 'F');
    _op('BT');
    _content
      ..add(PdfName(fontName).toBytes())
      ..add(latin1.encode(' ${formatNumber(style.size)} Tf\n'));
    if (style.characterSpacing != 0) _op('Tc', [style.characterSpacing]);
    if (style.rise != 0) _op('Ts', [style.rise]);
    if (style.horizontalScaling != 100) _op('Tz', [style.horizontalScaling]);
    if (style.renderMode != TextRenderMode.fill) {
      _op('Tr', [style.renderMode.index]);
    }
    _op('Td', [x, y]);
    _content.add(_showText(glyphs, style));
    _op('ET');
    return style.widthOf(glyphs);
  }

  /// The `TJ` operator showing [glyphs]: runs of glyph codes, with the
  /// kerning and the word spacing between them as adjustments.
  Uint8List _showText(List<ShapedGlyph> glyphs, PdfTextStyle style) {
    final font = style.font;
    final codes = font.encode(glyphs);
    final width = switch (font) {
      StandardFont() => 1,
      EmbeddedFont() => 2,
    };
    final hex = font is EmbeddedFont;
    final out = BytesBuilder()..addByte(0x5b); // [
    var start = 0;
    var end = 0;
    void flush() {
      if (end == start) return;
      PdfString(codes.sublist(start, end), hex: hex).writeTo(out);
      start = end;
    }

    for (var i = 0; i < glyphs.length; i++) {
      final glyph = glyphs[i];
      end = (i + 1) * width;
      var adjustment = 0.0;
      if (i < glyphs.length - 1) adjustment -= glyph.kerning;
      if (glyph.text == ' ' && style.wordSpacing != 0) {
        adjustment -= style.wordSpacing * 1000 / style.size;
      }
      if (adjustment != 0) {
        flush();
        out
          ..addByte(0x20)
          ..add(latin1.encode(formatNumber(adjustment, precision: 3)))
          ..addByte(0x20);
      }
    }
    flush();
    out.add(latin1.encode('] TJ\n'));
    return out.takeBytes();
  }
}

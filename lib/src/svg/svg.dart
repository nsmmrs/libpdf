/// SVG images drawn as PDF vector graphics through the drawing API:
/// shapes and paths, transforms, nested viewports, `use` and `symbol`,
/// fill and stroke, gradients, clip paths, group opacity, text in PDF
/// fonts, and raster or SVG images. What isn't supported (masks, filters,
/// markers, patterns...) is reported in [SvgImage.warnings].
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:libpdf/src/drawing/canvas.dart';
import 'package:libpdf/src/drawing/color.dart';
import 'package:libpdf/src/drawing/geometry.dart';
import 'package:libpdf/src/drawing/graphic.dart';
import 'package:libpdf/src/drawing/shading.dart';
import 'package:libpdf/src/fonts/fonts.dart';
import 'package:libpdf/src/images/images.dart';
import 'package:libpdf/src/svg/css.dart';
import 'package:libpdf/src/svg/css_color.dart';
import 'package:libpdf/src/svg/path.dart';
import 'package:xml/xml.dart';

/// The font for a font [family] as an SVG names it, in [bold] and
/// [italic] variants; null when there is none (the next family is
/// tried).
typedef SvgFontResolver = PdfFont? Function(
  String family, {
  required bool bold,
  required bool italic,
});

/// The bytes of the image an SVG refers to by [href] (anything but a
/// `data:` URI), or null when it can't be had.
typedef SvgImageResolver = Uint8List? Function(String href);

/// An SVG image.
final class SvgImage implements Graphic {
  new _(
    this._root,
    this._ids,
    this._rules,
    this.width,
    this.height,
    this._viewBox,
    this._aspect,
    this._fonts,
    this._images,
    this.pixelSize,
    Iterable<String> warnings,
  ) {
    _warnings.addAll(warnings);
  }

  /// The SVG document [text]. [fonts] chooses PDF fonts for text (the
  /// standard fonts by default); [images] reads referenced images;
  /// [pixelSize] is the size of a CSS pixel (a user unit) in points.
  factory parse(
    String text, {
    SvgFontResolver? fonts,
    SvgImageResolver? images,
    double pixelSize = 0.75,
  }) {
    final XmlDocument document;
    try {
      document = XmlDocument.parse(text);
    } on XmlException catch (error) {
      throw FormatException('not an SVG document: ${error.message}');
    }
    final root = document.rootElement;
    if (root.localName != 'svg') {
      throw const FormatException(
        'not an SVG document: the root element is not <svg>',
      );
    }
    final ids = <String, XmlElement>{};
    final rules = <CssRule>[];
    final warnings = <String>[];
    for (final element in [root, ...root.descendantElements]) {
      if (element.getAttribute('id') case final id?) {
        ids.putIfAbsent(id, () => element);
      }
      if (element.localName == 'style') {
        final (parsed, skipped) = parseStyleSheet(element.innerText);
        for (final rule in parsed) {
          rules.add(CssRule(rule.selector, rule.declarations, rules.length));
        }
        for (final selector in skipped) {
          warnings.add('CSS rule not supported: $selector');
        }
      }
    }
    final viewBox = _parseViewBox(root.getAttribute('viewBox'));
    double size(String name, double fallback) {
      final value = root.getAttribute(name);
      if (value == null || value.trim().endsWith('%')) return fallback;
      return _absoluteLength(value) ?? fallback;
    }

    final widthPx = size(
      'width',
      viewBox?.$3 ?? (viewBox == null ? 300 : viewBox.$3),
    );
    final heightPx = size(
      'height',
      viewBox?.$4 ?? (viewBox == null ? 150 : viewBox.$4),
    );
    return SvgImage._(
      root,
      ids,
      rules,
      widthPx * pixelSize,
      heightPx * pixelSize,
      viewBox ?? (0, 0, widthPx, heightPx),
      _AspectRatio.parse(root.getAttribute('preserveAspectRatio')),
      fonts ?? _standardFonts,
      images,
      pixelSize,
      warnings,
    );
  }

  final XmlElement _root;
  final Map<String, XmlElement> _ids;
  final List<CssRule> _rules;
  final (double, double, double, double) _viewBox;
  final _AspectRatio _aspect;
  final SvgFontResolver _fonts;
  final SvgImageResolver? _images;

  /// The intrinsic width, in points.
  final double width;

  /// The intrinsic height, in points.
  final double height;

  /// The size of a user unit (a CSS pixel), in points.
  final double pixelSize;

  final Set<String> _warnings = {};

  /// The value of the root `<svg>` element's attribute [name] as written
  /// (`width`, `height`, `viewBox`, say), for sizing the image another way.
  String? rootAttribute(String name) => _root.getAttribute(name);

  /// What the image uses that isn't drawn (or isn't drawn exactly), once
  /// each; drawing adds to them.
  List<String> get warnings => _warnings.toList();

  final Expando<Map<String, String>> _specified = Expando();

  /// Draws the image into [rect] (by its `preserveAspectRatio`).
  void draw(PdfCanvas canvas, PdfRect rect) =>
      _Renderer(this, canvas).render(rect);

  @override
  double get intrinsicWidth => width;

  @override
  double get intrinsicHeight => height;

  @override
  void paint(PdfCanvas canvas, PdfRect rect) => draw(canvas, rect);
}

/// The standard fonts for the generic families and common names.
PdfFont? _standardFonts(
  String family, {
  required bool bold,
  required bool italic,
}) {
  final base = switch (family.toLowerCase()) {
    'serif' || 'times' || 'times new roman' || 'times-roman' => 'Times',
    'sans-serif' ||
    'helvetica' ||
    'arial' ||
    'liberation sans' ||
    'dejavu sans' ||
    'verdana' => 'Helvetica',
    'monospace' || 'courier' || 'courier new' => 'Courier',
    _ => null,
  };
  if (base == null) return null;
  final name = switch ((base, bold, italic)) {
    ('Times', false, false) => 'Times-Roman',
    ('Times', true, false) => 'Times-Bold',
    ('Times', false, true) => 'Times-Italic',
    ('Times', true, true) => 'Times-BoldItalic',
    (_, false, false) => base,
    (_, true, false) => '$base-Bold',
    (_, false, true) => '$base-Oblique',
    (_, true, true) => '$base-BoldOblique',
  };
  return StandardFont.named(name);
}

(double, double, double, double)? _parseViewBox(String? text) {
  if (text == null) return null;
  final values = _numbers(text);
  if (values.length != 4 || values[2] <= 0 || values[3] <= 0) return null;
  return (values[0], values[1], values[2], values[3]);
}

List<double> _numbers(String text) => [
  for (final m in RegExp(
    r'[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?',
  ).allMatches(text))
    double.parse(m[0]!),
];

/// A length in user units, without percentages or font-relative units.
double? _absoluteLength(String text) {
  final m = RegExp(
    r'^\s*([+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)\s*(px|pt|pc|mm|cm|in)?\s*$',
  ).firstMatch(text);
  if (m == null) return null;
  final value = double.parse(m[1]!);
  return value *
      switch (m[2]) {
        'pt' => 4 / 3,
        'pc' => 16,
        'mm' => 96 / 25.4,
        'cm' => 96 / 2.54,
        'in' => 96,
        _ => 1,
      };
}

/// How a viewBox is fitted into a viewport.
final class _AspectRatio {
  const new(this.x, this.y, {required this.slice, required this.none});

  factory parse(String? text) {
    final parts = (text ?? '').trim().split(RegExp(r'\s+'));
    final align = parts.first;
    if (align == 'none') {
      return const _AspectRatio(0, 0, slice: false, none: true);
    }
    double axis(String name) => switch (name) {
      'Min' => 0,
      'Max' => 1,
      _ => 0.5,
    };
    final m = RegExp(r'^x(Min|Mid|Max)Y(Min|Mid|Max)$').firstMatch(align);
    return _AspectRatio(
      m == null ? 0.5 : axis(m[1]!),
      m == null ? 0.5 : axis(m[2]!),
      slice: parts.length > 1 && parts[1] == 'slice',
      none: false,
    );
  }

  /// The horizontal alignment: 0 (min), 0.5 (mid) or 1 (max).
  final double x;

  /// The vertical alignment.
  final double y;
  final bool slice;
  final bool none;

  /// The scale and offset fitting [box] into [width] by [height].
  (double, double, double, double) fit(
    (double, double, double, double) box,
    double width,
    double height,
  ) {
    final (_, _, w, h) = box;
    if (none) return (width / w, height / h, 0, 0);
    final scale = slice
        ? math.max(width / w, height / h)
        : math.min(width / w, height / h);
    return (scale, scale, (width - w * scale) * x, (height - h * scale) * y);
  }
}

/// The properties presentation attributes set.
const Set<String> _presentation = {
  'fill',
  'fill-opacity',
  'fill-rule',
  'stroke',
  'stroke-width',
  'stroke-opacity',
  'stroke-linecap',
  'stroke-linejoin',
  'stroke-miterlimit',
  'stroke-dasharray',
  'stroke-dashoffset',
  'opacity',
  'display',
  'visibility',
  'color',
  'font-family',
  'font-size',
  'font-weight',
  'font-style',
  'text-anchor',
  'dominant-baseline',
  'alignment-baseline',
  'letter-spacing',
  'word-spacing',
  'clip-path',
  'clip-rule',
  'mask',
  'filter',
  'stop-color',
  'stop-opacity',
  'text-decoration',
  'marker-start',
  'marker-mid',
  'marker-end',
};

/// The properties children inherit.
const Set<String> _inherited = {
  'fill',
  'fill-opacity',
  'fill-rule',
  'stroke',
  'stroke-width',
  'stroke-opacity',
  'stroke-linecap',
  'stroke-linejoin',
  'stroke-miterlimit',
  'stroke-dasharray',
  'stroke-dashoffset',
  'visibility',
  'color',
  'font-family',
  'font-size',
  'font-weight',
  'font-style',
  'text-anchor',
  'dominant-baseline',
  'letter-spacing',
  'word-spacing',
  'clip-rule',
  'marker-start',
  'marker-mid',
  'marker-end',
};

const Map<String, String> _initialStyle = {
  'fill': 'black',
  'stroke': 'none',
  'font-size': '16',
  'font-family': 'serif',
};

/// Elements that aren't drawn where they are.
const Set<String> _notRendered = {
  'defs',
  'style',
  'title',
  'desc',
  'metadata',
  'clipPath',
  'linearGradient',
  'radialGradient',
  'symbol',
  'marker',
  'mask',
  'pattern',
  'filter',
  'script',
  'font',
  'font-face',
  'cursor',
  'view',
};

/// A bounding box large enough for any group drawn as a form.
const PdfRect _anywhere = PdfRect(-100000, -100000, 200000, 200000);

final class _Renderer {
  new(this.svg, this.canvas, [List<XmlElement>? uses]) : _uses = uses ?? [];

  final SvgImage svg;
  final PdfCanvas canvas;

  /// The `use` elements being drawn (to stop cycles).
  final List<XmlElement> _uses;

  /// The viewport sizes, innermost last (for percentages).
  final List<(double, double)> _viewports = [];

  void _warn(String message) => svg._warnings.add(message);

  void render(PdfRect rect) {
    final box = svg._viewBox;
    final (sx, sy, tx, ty) = svg._aspect.fit(box, rect.width, rect.height);
    _viewports.add((box.$3, box.$4));
    canvas
      ..save()
      ..rect(rect)
      ..clip()
      ..transform(
        PdfMatrix(
          sx,
          0,
          0,
          -sy,
          rect.left + tx - sx * box.$1,
          rect.top - ty + sy * box.$2,
        ),
      );
    final style = _compute(svg._root, _initialStyle);
    _children(svg._root, style);
    canvas.restore();
  }

  // Styles.

  Map<String, String> _specified(XmlElement element) =>
      svg._specified[element] ??= () {
        final out = <String, String>{};
        for (final attribute in element.attributes) {
          final name = attribute.name.local;
          if (_presentation.contains(name)) out[name] = attribute.value.trim();
        }
        final matched =
            [
              for (final rule in svg._rules)
                if (rule.selector.matches(element)) rule,
            ]..sort((a, b) {
              final (ai, ac, at) = a.selector.specificity;
              final (bi, bc, bt) = b.selector.specificity;
              return ai != bi
                  ? ai - bi
                  : ac != bc
                  ? ac - bc
                  : at != bt
                  ? at - bt
                  : a.order - b.order;
            });
        for (final rule in matched) {
          for (final (name, value) in rule.declarations) {
            out[name] = value;
          }
        }
        if (element.getAttribute('style') case final style?) {
          for (final (name, value) in parseDeclarations(style)) {
            out[name] = value;
          }
        }
        return out;
      }();

  /// The computed style of [element] whose parent's is [parent].
  Map<String, String> _compute(XmlElement element, Map<String, String> parent) {
    final specified = _specified(element);
    final style = <String, String>{
      for (final MapEntry(:key, :value) in parent.entries)
        if (_inherited.contains(key)) key: value,
    };
    for (final MapEntry(:key, :value) in specified.entries) {
      if (value == 'inherit') {
        if (parent[key] case final inherited?) style[key] = inherited;
        continue;
      }
      if (key == 'font-size') {
        final parentSize = double.tryParse(parent['font-size'] ?? '') ?? 16;
        style[key] = '${_length(value, ref: parentSize, fontSize: parentSize)}';
        continue;
      }
      style[key] = value;
    }
    return style;
  }

  double _fontSize(Map<String, String> style) =>
      double.tryParse(style['font-size'] ?? '') ?? 16;

  /// [text] as a length in user units; percentages of [ref].
  double _length(
    String? text, {
    double ref = 0,
    double fontSize = 16,
    double fallback = 0,
  }) {
    if (text == null) return fallback;
    final m = RegExp(
      r'^\s*([+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)\s*(%|em|ex|px|pt|pc|mm|cm|in)?\s*$',
    ).firstMatch(text);
    if (m == null) return fallback;
    final value = double.parse(m[1]!);
    return switch (m[2]) {
      '%' => value / 100 * ref,
      'em' => value * fontSize,
      'ex' => value * fontSize / 2,
      _ => _absoluteLength('${m[1]}${m[2] ?? ''}') ?? fallback,
    };
  }

  double get _viewportWidth => _viewports.last.$1;
  double get _viewportHeight => _viewports.last.$2;
  double get _viewportDiagonal => math.sqrt(
    (_viewportWidth * _viewportWidth + _viewportHeight * _viewportHeight) / 2,
  );

  double _x(XmlElement e, String name, Map<String, String> style) => _length(
    e.getAttribute(name),
    ref: _viewportWidth,
    fontSize: _fontSize(style),
  );

  double _y(XmlElement e, String name, Map<String, String> style) => _length(
    e.getAttribute(name),
    ref: _viewportHeight,
    fontSize: _fontSize(style),
  );

  double? _optional(
    XmlElement e,
    String name,
    Map<String, String> style, {
    required double ref,
  }) {
    final value = e.getAttribute(name);
    if (value == null || value == 'auto') return null;
    return _length(value, ref: ref, fontSize: _fontSize(style));
  }

  // Elements.

  void _children(XmlElement parent, Map<String, String> style) {
    for (final child in parent.childElements) {
      _element(child, style);
    }
  }

  void _element(XmlElement element, Map<String, String> parentStyle) {
    final name = element.localName;
    if (_notRendered.contains(name)) return;
    final style = _compute(element, parentStyle);
    if (style['display'] == 'none') return;
    for (final marker in ['marker-start', 'marker-mid', 'marker-end']) {
      if (style[marker] case final value? when value != 'none') {
        _warn('markers are not drawn');
      }
    }
    if (style['mask'] case final mask? when mask != 'none') {
      _warn('masks are not supported; the element is drawn unmasked');
    }
    if (style['filter'] case final filter? when filter != 'none') {
      _warn('filters are not supported; the element is drawn unfiltered');
    }
    switch (name) {
      case 'g' || 'a':
        _withState(element, style, null, container: true, () {
          _children(element, style);
        });
      case 'switch':
        _withState(element, style, null, container: true, () {
          final first = element.childElements.firstOrNull;
          if (first != null) _element(first, style);
        });
      case 'svg':
        _nested(element, style);
      case 'use':
        _use(element, style);
      case 'rect' ||
          'circle' ||
          'ellipse' ||
          'line' ||
          'polyline' ||
          'polygon' ||
          'path':
        final path = _geometry(element, style);
        if (path == null || path.isEmpty) return;
        _withState(element, style, path, container: false, () {
          _paint(element, style, path);
        });
      case 'text':
        _withState(element, style, null, container: false, () {
          _text(element, style);
        });
      case 'image':
        _withState(element, style, null, container: false, () {
          _image(element, style);
        });
      default:
        _warn('<$name> is not supported');
    }
  }

  /// Runs [draw] with [element]'s transform, clip path and opacity.
  void _withState(
    XmlElement element,
    Map<String, String> style,
    SvgPath? path,
    void Function() draw, {
    required bool container,
  }) {
    canvas.save();
    if (element.getAttribute('transform') case final transform?) {
      canvas.transform(_parseTransform(transform));
    }
    if (style['clip-path'] case final clip? when clip != 'none') {
      _clip(clip, path);
    }
    final opacity = _opacity(style['opacity']);
    if (opacity < 1 && container) {
      // Group opacity: the children drawn as one transparency group.
      final form = PdfForm(_anywhere, (formCanvas) {
        final inner = _Renderer(svg, formCanvas, _uses)
          .._viewports.addAll(_viewports);
        // The state above is applied to the form as it is painted.
        switch (element.localName) {
          case 'switch':
            final first = element.childElements.firstOrNull;
            if (first != null) inner._element(first, style);
          default:
            inner._children(element, style);
        }
      }, group: const TransparencyGroup());
      canvas
        ..opacity(fill: opacity, stroke: opacity)
        ..form(form);
    } else if (opacity > 0) {
      draw();
    }
    canvas.restore();
  }

  double _opacity(String? value) {
    if (value == null) return 1;
    final text = value.trim();
    final number = text.endsWith('%')
        ? (double.tryParse(text.substring(0, text.length - 1)) ?? 100) / 100
        : double.tryParse(text) ?? 1;
    return number.clamp(0, 1).toDouble();
  }

  void _nested(XmlElement element, Map<String, String> style) {
    final x = _x(element, 'x', style);
    final y = _y(element, 'y', style);
    final width =
        _optional(element, 'width', style, ref: _viewportWidth) ??
        _viewportWidth;
    final height =
        _optional(element, 'height', style, ref: _viewportHeight) ??
        _viewportHeight;
    if (width <= 0 || height <= 0) return;
    _viewport(
      element,
      style,
      x,
      y,
      width,
      height,
      _parseViewBox(element.getAttribute('viewBox')),
      () => _children(element, style),
    );
  }

  /// A new viewport at ([x], [y]), [width] by [height], with [viewBox].
  void _viewport(
    XmlElement element,
    Map<String, String> style,
    double x,
    double y,
    double width,
    double height,
    (double, double, double, double)? viewBox,
    void Function() draw,
  ) {
    _withState(element, style, null, container: true, () {
      canvas
        ..rect(PdfRect(x, y, width, height))
        ..clip();
      final box = viewBox ?? (0, 0, width, height);
      final (sx, sy, tx, ty) = _AspectRatio.parse(
        element.getAttribute('preserveAspectRatio'),
      ).fit(box, width, height);
      canvas.transform(
        PdfMatrix(sx, 0, 0, sy, x + tx - sx * box.$1, y + ty - sy * box.$2),
      );
      _viewports.add((box.$3, box.$4));
      draw();
      _viewports.removeLast();
    });
  }

  XmlElement? _referenced(XmlElement element) {
    final href =
        element.getAttribute('href') ??
        element.getAttribute('xlink:href') ??
        element.getAttribute(
          'href',
          namespaceUri: 'http://www.w3.org/1999/xlink',
        );
    if (href == null || !href.startsWith('#')) return null;
    return svg._ids[href.substring(1)];
  }

  void _use(XmlElement element, Map<String, String> style) {
    final target = _referenced(element);
    if (target == null) {
      _warn('<use> refers to nothing in the document');
      return;
    }
    if (_uses.contains(element)) {
      _warn('<use> refers to itself');
      return;
    }
    _uses.add(element);
    final x = _x(element, 'x', style);
    final y = _y(element, 'y', style);
    canvas.save();
    if (element.getAttribute('transform') case final transform?) {
      canvas.transform(_parseTransform(transform));
    }
    canvas.translate(x, y);
    // The referenced content inherits from the <use>, which is otherwise
    // like a <g> (without its transform, applied above).
    final opacity = _opacity(style['opacity']);
    final clip = style['clip-path'];
    final groupStyle = {...style}
      ..remove('opacity')
      ..remove('clip-path');
    if (clip != null && clip != 'none') _clip(clip, null);
    if (opacity < 1) {
      final form = PdfForm(_anywhere, (formCanvas) {
        (_Renderer(svg, formCanvas, _uses).._viewports.addAll(_viewports))
            ._useContent(element, target, style, groupStyle);
      }, group: const TransparencyGroup());
      canvas
        ..opacity(fill: opacity, stroke: opacity)
        ..form(form);
    } else if (opacity > 0) {
      _useContent(element, target, style, groupStyle);
    }
    canvas.restore();
    _uses.removeLast();
  }

  /// What a `use` element [use] shows of [target]: a symbol in a new
  /// viewport, or the element itself.
  void _useContent(
    XmlElement use,
    XmlElement target,
    Map<String, String> style,
    Map<String, String> groupStyle,
  ) {
    if (target.localName != 'symbol') {
      _element(target, groupStyle);
      return;
    }
    final width =
        _optional(use, 'width', style, ref: _viewportWidth) ?? _viewportWidth;
    final height =
        _optional(use, 'height', style, ref: _viewportHeight) ??
        _viewportHeight;
    final symbolStyle = _compute(target, groupStyle);
    _viewport(
      target,
      symbolStyle,
      0,
      0,
      width,
      height,
      _parseViewBox(target.getAttribute('viewBox')),
      () => _children(target, symbolStyle),
    );
  }

  /// The shape of a basic shape or path element, in its own coordinates.
  SvgPath? _geometry(XmlElement element, Map<String, String> style) {
    switch (element.localName) {
      case 'rect':
        final w = _length(
          element.getAttribute('width'),
          ref: _viewportWidth,
          fontSize: _fontSize(style),
        );
        final h = _length(
          element.getAttribute('height'),
          ref: _viewportHeight,
          fontSize: _fontSize(style),
        );
        if (w <= 0 || h <= 0) return null;
        var rx = _optional(element, 'rx', style, ref: _viewportWidth);
        var ry = _optional(element, 'ry', style, ref: _viewportHeight);
        rx ??= ry ?? 0;
        ry ??= rx;
        return SvgPath.rect(
          _x(element, 'x', style),
          _y(element, 'y', style),
          w,
          h,
          math.min(rx, w / 2),
          math.min(ry, h / 2),
        );
      case 'circle':
        final r = _length(
          element.getAttribute('r'),
          ref: _viewportDiagonal,
          fontSize: _fontSize(style),
        );
        if (r <= 0) return null;
        return SvgPath.ellipse(
          _x(element, 'cx', style),
          _y(element, 'cy', style),
          r,
          r,
        );
      case 'ellipse':
        var rx = _optional(element, 'rx', style, ref: _viewportWidth);
        var ry = _optional(element, 'ry', style, ref: _viewportHeight);
        rx ??= ry;
        ry ??= rx;
        if (rx == null || ry == null || rx <= 0 || ry <= 0) return null;
        return SvgPath.ellipse(
          _x(element, 'cx', style),
          _y(element, 'cy', style),
          rx,
          ry,
        );
      case 'line':
        return SvgPath([
          MoveSegment(_x(element, 'x1', style), _y(element, 'y1', style)),
          LineSegment(_x(element, 'x2', style), _y(element, 'y2', style)),
        ]);
      case 'polyline' || 'polygon':
        final points = _numbers(element.getAttribute('points') ?? '');
        return SvgPath.polyline(points, closed: element.localName == 'polygon');
      case 'path':
        return SvgPath.parse(element.getAttribute('d') ?? '');
    }
    return null;
  }

  // Painting.

  void _paint(XmlElement element, Map<String, String> style, SvgPath path) {
    final opacity = _opacity(style['opacity']);
    if (style['visibility'] case 'hidden' || 'collapse') return;
    if (element.localName != 'line') {
      _fill(
        path,
        style,
        style['fill'] ?? 'black',
        _opacity(style['fill-opacity']) * opacity,
        evenOdd: style['fill-rule'] == 'evenodd',
      );
    }
    _stroke(
      path,
      style,
      style['stroke'] ?? 'none',
      _opacity(style['stroke-opacity']) * opacity,
    );
  }

  /// The paint [value]: a color with its alpha, a gradient, or nothing.
  _Paint? _paintOf(String value, Map<String, String> style) {
    final text = value.trim();
    if (text == 'none' || text.isEmpty) return null;
    final url = RegExp(r'''^url\(\s*['"]?#([^'")]+)['"]?\s*\)\s*(.*)$''')
        .firstMatch(text);
    if (url != null) {
      final target = svg._ids[url[1]!];
      if (target != null &&
          (target.localName == 'linearGradient' ||
              target.localName == 'radialGradient')) {
        return _GradientPaint(target);
      }
      if (target?.localName == 'pattern') {
        _warn('pattern fills are not supported');
      } else {
        _warn('paint server #${url[1]} not found');
      }
      final fallback = url[2]!.trim();
      return fallback.isEmpty ? null : _paintOf(fallback, style);
    }
    if (text == 'currentColor' || text == 'currentcolor') {
      return _paintOf(style['color'] ?? 'black', {});
    }
    final color = parseCssColor(text);
    if (color == null) {
      _warn('color not understood: $text');
      return null;
    }
    return _ColorPaint(color);
  }

  void _fill(
    SvgPath path,
    Map<String, String> style,
    String value,
    double opacity, {
    required bool evenOdd,
  }) {
    final paint = _paintOf(value, style);
    switch (paint) {
      case null:
        return;
      case _ColorPaint(:final color):
        final alpha = opacity * color.alpha;
        if (alpha <= 0) return;
        canvas.save();
        if (alpha < 1) canvas.opacity(fill: alpha);
        canvas.setFillColor(_rgb(color));
        path.addTo(canvas);
        canvas
          ..fill(evenOdd: evenOdd)
          ..restore();
      case _GradientPaint(:final element):
        _gradientFill(path, element, opacity, evenOdd: evenOdd);
    }
  }

  void _stroke(
    SvgPath path,
    Map<String, String> style,
    String value,
    double opacity,
  ) {
    final paint = _paintOf(value, style);
    if (paint == null) return;
    final width = _length(
      style['stroke-width'] ?? '1',
      ref: _viewportDiagonal,
      fontSize: _fontSize(style),
      fallback: 1,
    );
    if (width <= 0) return;
    final color = switch (paint) {
      _ColorPaint(:final color) => color,
      _GradientPaint(:final element) => () {
        _warn("gradient strokes are drawn in the gradient's first color");
        final stops = _stops(element);
        return stops.isEmpty
            ? null
            : (
                red: stops.first.$2.red,
                green: stops.first.$2.green,
                blue: stops.first.$2.blue,
                alpha: stops.first.$3,
              );
      }(),
    };
    if (color == null) return;
    final alpha = opacity * color.alpha;
    if (alpha <= 0) return;
    canvas.save();
    if (alpha < 1) canvas.opacity(stroke: alpha);
    canvas
      ..setStrokeColor(_rgb(color))
      ..setLineWidth(width)
      ..setLineCap(switch (style['stroke-linecap']) {
        'round' => LineCap.round,
        'square' => LineCap.projectingSquare,
        _ => LineCap.butt,
      })
      ..setLineJoin(switch (style['stroke-linejoin']) {
        'round' => LineJoin.round,
        'bevel' => LineJoin.bevel,
        _ => LineJoin.miter,
      })
      ..setMiterLimit(double.tryParse(style['stroke-miterlimit'] ?? '') ?? 4);
    final dashes = style['stroke-dasharray'];
    if (dashes != null && dashes != 'none') {
      var pattern = [
        for (final part in dashes.split(RegExp(r'[\s,]+')))
          if (part.isNotEmpty)
            _length(part, ref: _viewportDiagonal, fontSize: _fontSize(style)),
      ];
      if (pattern.length.isOdd) pattern = [...pattern, ...pattern];
      if (pattern.isNotEmpty &&
          pattern.every((d) => d >= 0) &&
          pattern.any((d) => d > 0)) {
        canvas.dash(
          pattern,
          _length(style['stroke-dashoffset'], fontSize: _fontSize(style)),
        );
      }
    }
    path.addTo(canvas);
    canvas
      ..stroke()
      ..restore();
  }

  static RgbColor _rgb(CssColor color) =>
      RgbColor(color.red, color.green, color.blue);

  // Gradients.

  /// The gradient's attribute [name], from it or the gradients it refers
  /// to.
  String? _gradientAttribute(XmlElement gradient, String name) {
    final seen = <XmlElement>{};
    XmlElement? at = gradient;
    while (at != null && seen.add(at)) {
      if (at.getAttribute(name) case final value?) return value;
      at = _referenced(at);
    }
    return null;
  }

  /// The gradient's stops: offset, color, opacity.
  List<(double, CssColor, double)> _stops(XmlElement gradient) {
    final seen = <XmlElement>{};
    XmlElement? at = gradient;
    while (at != null && seen.add(at)) {
      final stops = at.childElements.where((e) => e.localName == 'stop');
      if (stops.isNotEmpty) {
        var last = 0.0;
        return [
          for (final stop in stops)
            () {
              final style = _compute(stop, const {});
              final offsetText = stop.getAttribute('offset') ?? '0';
              var offset = offsetText.endsWith('%')
                  ? (double.tryParse(offsetText.replaceAll('%', '')) ?? 0) / 100
                  : double.tryParse(offsetText) ?? 0;
              offset = offset.clamp(last, 1).toDouble();
              last = offset;
              final colorText = style['stop-color'] ?? 'black';
              final color = colorText == 'currentColor'
                  ? parseCssColor(style['color'] ?? 'black')
                  : parseCssColor(colorText);
              final c = color ?? (red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0);
              return (offset, c, _opacity(style['stop-opacity']) * c.alpha);
            }(),
        ];
      }
      at = _referenced(at);
    }
    return const [];
  }

  void _gradientFill(
    SvgPath path,
    XmlElement gradient,
    double opacity, {
    required bool evenOdd,
  }) {
    final stops = _stops(gradient);
    if (stops.isEmpty) return;
    if (stops.length == 1) {
      final (_, color, alpha) = stops.single;
      final a = opacity * alpha;
      if (a <= 0) return;
      canvas.save();
      if (a < 1) canvas.opacity(fill: a);
      canvas.setFillColor(_rgb(color));
      path.addTo(canvas);
      canvas
        ..fill(evenOdd: evenOdd)
        ..restore();
      return;
    }
    final userSpace =
        _gradientAttribute(gradient, 'gradientUnits') == 'userSpaceOnUse';
    final bounds = path.bounds;
    if (!userSpace &&
        (bounds == null || bounds.width == 0 || bounds.height == 0)) {
      return;
    }
    final spread = _gradientAttribute(gradient, 'spreadMethod');
    if (spread == 'reflect' || spread == 'repeat') {
      _warn('gradient spreadMethod="$spread" is drawn as "pad"');
    }
    double coordinate(String name, String fallback, {required bool vertical}) {
      final text = _gradientAttribute(gradient, name) ?? fallback;
      if (!userSpace) {
        return text.endsWith('%')
            ? (double.tryParse(text.replaceAll('%', '')) ?? 0) / 100
            : double.tryParse(text) ?? 0;
      }
      return _length(
        text,
        ref: name == 'r' || name == 'fr'
            ? _viewportDiagonal
            : vertical
            ? _viewportHeight
            : _viewportWidth,
      );
    }

    PdfShading shading(PdfColor Function((double, CssColor, double)) color) {
      final gradientStops = [
        for (final stop in stops) GradientStop(stop.$1, color(stop)),
      ];
      if (gradient.localName == 'linearGradient') {
        return AxialShading(
          coordinate('x1', '0%', vertical: false),
          coordinate('y1', '0%', vertical: true),
          coordinate('x2', '100%', vertical: false),
          coordinate('y2', '0%', vertical: true),
          gradientStops,
        );
      }
      final cx = coordinate('cx', '50%', vertical: false);
      final cy = coordinate('cy', '50%', vertical: true);
      return RadialShading(
        _gradientAttribute(gradient, 'fx') == null
            ? cx
            : coordinate('fx', '50%', vertical: false),
        _gradientAttribute(gradient, 'fy') == null
            ? cy
            : coordinate('fy', '50%', vertical: true),
        coordinate('fr', '0%', vertical: false),
        cx,
        cy,
        coordinate('r', '50%', vertical: false),
        gradientStops,
      );
    }

    void space(PdfCanvas c) {
      if (!userSpace) {
        c.transform(
          PdfMatrix(
            bounds!.width,
            0,
            0,
            bounds.height,
            bounds.left,
            bounds.bottom,
          ),
        );
      }
      if (_gradientAttribute(gradient, 'gradientTransform')
          case final transform?) {
        c.transform(_parseTransform(transform));
      }
    }

    canvas.save();
    path.addTo(canvas);
    canvas.clip(evenOdd: evenOdd);
    if (opacity < 1) canvas.opacity(fill: opacity);
    if (stops.any((s) => s.$3 < 1)) {
      // Stop opacity: a soft mask of the opacities, shaded alike.
      final mask = PdfForm(_anywhere, (c) {
        space(c);
        c.shade(shading((s) => GrayColor(s.$3)));
      }, group: const TransparencyGroup());
      canvas.softMask(mask);
    }
    space(canvas);
    canvas
      ..shade(shading((s) => _rgb(s.$2)))
      ..restore();
  }

  // Clipping.

  void _clip(String value, SvgPath? targetPath) {
    final m = RegExp(r'''^url\(\s*['"]?#([^'")]+)['"]?\s*\)$''')
        .firstMatch(value.trim());
    final clip = m == null ? null : svg._ids[m[1]!];
    if (clip == null || clip.localName != 'clipPath') {
      _warn('clip-path $value not found');
      return;
    }
    final clipStyle = _compute(clip, _initialStyle);
    // A clip path's own clip path intersects it.
    if (clipStyle['clip-path'] case final nested? when nested != 'none') {
      _clip(nested, targetPath);
    }
    final segments = <PathSegment>[];
    var evenOdd = false;
    for (final child in clip.childElements) {
      var shape = child;
      var transform = const PdfMatrix.identity();
      if (child.localName == 'use') {
        final target = _referenced(child);
        if (target == null) continue;
        transform = PdfMatrix.translation(
          _x(child, 'x', clipStyle),
          _y(child, 'y', clipStyle),
        );
        if (child.getAttribute('transform') case final t?) {
          transform = transform.then(_parseTransform(t));
        }
        shape = target;
      }
      if (shape.localName == 'text') {
        _warn('text in clip paths is not supported');
        continue;
      }
      final style = _compute(shape, clipStyle);
      if (style['display'] == 'none') continue;
      final path = _geometry(shape, style);
      if (path == null) continue;
      if (shape.getAttribute('transform') case final t?) {
        transform = _parseTransform(t).then(transform);
      }
      evenOdd = style['clip-rule'] == 'evenodd';
      segments.addAll(path.transform(transform).segments);
    }
    var union = SvgPath(segments);
    if (clip.getAttribute('transform') case final t?) {
      union = union.transform(_parseTransform(t));
    }
    if (clip.getAttribute('clipPathUnits') == 'objectBoundingBox') {
      final bounds = targetPath?.bounds;
      if (bounds == null) {
        _warn('clipPathUnits="objectBoundingBox" on a group is not supported');
        return;
      }
      union = union.transform(
        PdfMatrix(
          bounds.width,
          0,
          0,
          bounds.height,
          bounds.left,
          bounds.bottom,
        ),
      );
    }
    if (union.isEmpty) {
      canvas.rect(const PdfRect(0, 0, 0, 0));
    } else {
      union.addTo(canvas);
    }
    canvas.clip(evenOdd: evenOdd);
  }

  // Text.

  void _text(XmlElement element, Map<String, String> style) {
    final pieces = <_TextPiece>[];
    var first = true;
    // The position the next text takes: set by the elements it is in,
    // whether or not their own text comes first.
    (double?, double?) pendingAbsolute = (null, null);
    var pendingRelative = (0.0, 0.0);
    void walk(XmlElement node, Map<String, String> nodeStyle) {
      final x = node.getAttribute('x') == null
          ? null
          : _numbersOf(node, 'x', nodeStyle, vertical: false).firstOrNull;
      final y = node.getAttribute('y') == null
          ? null
          : _numbersOf(node, 'y', nodeStyle, vertical: true).firstOrNull;
      pendingAbsolute = (x ?? pendingAbsolute.$1, y ?? pendingAbsolute.$2);
      pendingRelative = (
        pendingRelative.$1 +
            (_numbersOf(node, 'dx', nodeStyle, vertical: false).firstOrNull ??
                0),
        pendingRelative.$2 +
            (_numbersOf(node, 'dy', nodeStyle, vertical: true).firstOrNull ??
                0),
      );
      for (final child in node.children) {
        switch (child) {
          case XmlText(:final value) || XmlCDATA(:final value):
            var text = value
                .replaceAll(RegExp(r'[\n\r]'), '')
                .replaceAll('\t', ' ');
            text = text.replaceAll(RegExp(' +'), ' ');
            if (text.isEmpty) continue;
            if (first) text = text.trimLeft();
            if (text.isEmpty) continue;
            first = false;
            pieces.add(
              _TextPiece(text, nodeStyle, pendingAbsolute, pendingRelative),
            );
            pendingAbsolute = (null, null);
            pendingRelative = (0, 0);
          case XmlElement(localName: 'tspan'):
            final childStyle = _compute(child, nodeStyle);
            if (childStyle['display'] == 'none') continue;
            walk(child, childStyle);
          case XmlElement(localName: 'textPath'):
            _warn('<textPath> is not supported');
          case XmlElement(:final localName)
              when localName != 'title' && localName != 'desc':
            _warn('<$localName> in text is not supported');
          default:
            break;
        }
      }
    }

    walk(element, style);
    if (pieces.isEmpty) return;
    pieces.last.text = pieces.last.text.trimRight();
    if (style['visibility'] case 'hidden' || 'collapse') return;

    // Chunks start at each absolute position; each is anchored.
    var x = 0.0;
    var y = 0.0;
    final chunks = <List<_TextPiece>>[];
    for (final piece in pieces) {
      if (piece.absolute.$1 != null ||
          piece.absolute.$2 != null ||
          chunks.isEmpty) {
        chunks.add([]);
      }
      chunks.last.add(piece);
    }
    for (final chunk in chunks) {
      final anchor = chunk.first.style['text-anchor'] ?? 'start';
      final styles = [for (final p in chunk) _pdfStyle(p.style)];
      var width = 0.0;
      for (final (i, piece) in chunk.indexed) {
        width += styles[i].measure(piece.text) + piece.relative.$1;
      }
      final head = chunk.first;
      x = head.absolute.$1 ?? x;
      y = head.absolute.$2 ?? y;
      x -= switch (anchor) {
        'middle' => width / 2,
        'end' => width,
        _ => 0,
      };
      for (final (i, piece) in chunk.indexed) {
        x += piece.relative.$1;
        y += piece.relative.$2;
        final textStyle = styles[i];
        final advance = textStyle.measure(piece.text);
        _drawText(piece, textStyle, x, y);
        x += advance;
      }
    }
  }

  List<double> _numbersOf(
    XmlElement element,
    String name,
    Map<String, String> style, {
    required bool vertical,
  }) {
    final value = element.getAttribute(name);
    if (value == null) return const [];
    final parts = value.trim().split(RegExp(r'[\s,]+'));
    if (parts.length > 1) {
      _warn('per-character text positions are not supported');
    }
    return [
      for (final part in parts)
        if (part.isNotEmpty)
          _length(
            part,
            ref: vertical ? _viewportHeight : _viewportWidth,
            fontSize: _fontSize(style),
          ),
    ];
  }

  PdfTextStyle _pdfStyle(Map<String, String> style) {
    final size = _fontSize(style);
    final weight = style['font-weight'] ?? 'normal';
    final bold =
        weight == 'bold' ||
        weight == 'bolder' ||
        (int.tryParse(weight) ?? 400) >= 600;
    final fontStyle = style['font-style'] ?? 'normal';
    final italic = fontStyle == 'italic' || fontStyle == 'oblique';
    PdfFont? font;
    final families = (style['font-family'] ?? 'serif')
        .split(',')
        .map((f) => f.trim().replaceAll(RegExp(r'''^['"]|['"]$'''), ''));
    for (final family in families) {
      font = svg._fonts(family, bold: bold, italic: italic);
      if (font != null) break;
    }
    if (font == null) {
      _warn('no font for ${style['font-family']}; using Helvetica');
      font = _standardFonts('sans-serif', bold: bold, italic: italic)!;
    }
    double spacing(String? value) =>
        value == null || value == 'normal' ? 0 : _length(value, fontSize: size);
    return PdfTextStyle(
      font,
      size,
      characterSpacing: spacing(style['letter-spacing']),
      wordSpacing: spacing(style['word-spacing']),
    );
  }

  void _drawText(_TextPiece piece, PdfTextStyle textStyle, double x, double y) {
    final style = piece.style;
    final fill = _paintOf(style['fill'] ?? 'black', style);
    final stroke = _paintOf(style['stroke'] ?? 'none', style);
    final opacity = _opacity(style['opacity']);
    CssColor? colorOf(_Paint? paint) => switch (paint) {
      _ColorPaint(:final color) => color,
      _GradientPaint(:final element) => () {
        _warn("gradient text is drawn in the gradient's first color");
        final stops = _stops(element);
        return stops.isEmpty ? null : stops.first.$2;
      }(),
      null => null,
    };
    final fillColor = colorOf(fill);
    final strokeColor = colorOf(stroke);
    if (fillColor == null && strokeColor == null) return;
    final font = textStyle.font;
    final size = textStyle.size;
    final baseline = style['dominant-baseline'] ?? style['alignment-baseline'];
    final shift = switch (baseline) {
      'middle' ||
      'central' => (font.ascender + font.descender) / 2 * size / 1000,
      'hanging' || 'text-before-edge' => font.ascender * size / 1000,
      'text-after-edge' || 'ideographic' => font.descender * size / 1000,
      'mathematical' => font.xHeight / 2 * size / 1000,
      _ => 0.0,
    };
    canvas.save();
    final fillAlpha =
        (fillColor?.alpha ?? 1) * _opacity(style['fill-opacity']) * opacity;
    final strokeAlpha =
        (strokeColor?.alpha ?? 1) * _opacity(style['stroke-opacity']) * opacity;
    if (fillAlpha < 1 || strokeAlpha < 1) {
      canvas.opacity(fill: fillAlpha, stroke: strokeAlpha);
    }
    if (fillColor != null) canvas.setFillColor(_rgb(fillColor));
    if (strokeColor != null) {
      canvas
        ..setStrokeColor(_rgb(strokeColor))
        ..setLineWidth(_length(style['stroke-width'] ?? '1', fallback: 1));
    }
    final mode = fillColor != null && strokeColor != null
        ? TextRenderMode.fillStroke
        : strokeColor != null
        ? TextRenderMode.stroke
        : TextRenderMode.fill;
    canvas
      // SVG text is upright in a y-down space.
      ..transform(PdfMatrix(1, 0, 0, -1, x, y + shift))
      ..text(piece.text, 0, 0, textStyle.copyWith(renderMode: mode));
    final decoration = style['text-decoration'] ?? '';
    if (decoration.contains('underline') ||
        decoration.contains('line-through')) {
      final width = textStyle.measure(piece.text);
      final thickness = font.underlineThickness * size / 1000;
      final at = decoration.contains('underline')
          ? font.underlinePosition * size / 1000
          : font.xHeight * size / 2000;
      if (fillColor != null) canvas.setFillColor(_rgb(fillColor));
      canvas
        ..rect(PdfRect(0, at - thickness / 2, width, thickness))
        ..fill();
    }
    canvas.restore();
  }

  // Images.

  void _image(XmlElement element, Map<String, String> style) {
    final href =
        element.getAttribute('href') ??
        element.getAttribute('xlink:href') ??
        element.getAttribute(
          'href',
          namespaceUri: 'http://www.w3.org/1999/xlink',
        );
    if (href == null) return;
    Uint8List? bytes;
    String? svgText;
    final data = RegExp(
      r'^data:([^;,]*)((?:;[^;,]*)*),(.*)$',
      dotAll: true,
    ).firstMatch(href.trim());
    if (data != null) {
      final base64Encoded = data[2]!.contains(';base64');
      final payload = data[3]!;
      final decoded = base64Encoded
          ? base64.decode(payload.replaceAll(RegExp(r'\s'), ''))
          : utf8.encode(Uri.decodeComponent(payload));
      if (data[1] == 'image/svg+xml') {
        svgText = utf8.decode(decoded);
      } else {
        bytes = Uint8List.fromList(decoded);
      }
    } else {
      bytes = svg._images?.call(href);
      if (bytes == null) {
        _warn('image $href could not be read');
        return;
      }
      if (href.toLowerCase().endsWith('.svg')) {
        svgText = utf8.decode(bytes, allowMalformed: true);
        bytes = null;
      }
    }
    final x = _x(element, 'x', style);
    final y = _y(element, 'y', style);
    try {
      final double intrinsicWidth;
      final double intrinsicHeight;
      PdfImage? raster;
      SvgImage? vector;
      if (svgText != null) {
        vector = SvgImage.parse(
          svgText,
          fonts: svg._fonts,
          images: svg._images,
          pixelSize: svg.pixelSize,
        );
        intrinsicWidth = vector.width / svg.pixelSize;
        intrinsicHeight = vector.height / svg.pixelSize;
      } else {
        raster = PdfImage.parse(bytes!);
        intrinsicWidth = raster.width.toDouble();
        intrinsicHeight = raster.height.toDouble();
      }
      final width =
          _optional(element, 'width', style, ref: _viewportWidth) ??
          intrinsicWidth;
      final height =
          _optional(element, 'height', style, ref: _viewportHeight) ??
          intrinsicHeight;
      if (width <= 0 || height <= 0) return;
      final (sx, sy, tx, ty) = _AspectRatio.parse(
        element.getAttribute('preserveAspectRatio'),
      ).fit((0, 0, intrinsicWidth, intrinsicHeight), width, height);
      final drawWidth = intrinsicWidth * sx;
      final drawHeight = intrinsicHeight * sy;
      canvas
        ..save()
        ..rect(PdfRect(x, y, width, height))
        ..clip()
        // Images are upright: flip back into a y-up space.
        ..transform(PdfMatrix(1, 0, 0, -1, x + tx, y + ty + drawHeight));
      if (raster != null) {
        canvas.image(raster, PdfRect(0, 0, drawWidth, drawHeight));
      } else {
        vector!.draw(canvas, PdfRect(0, 0, drawWidth, drawHeight));
        svg._warnings.addAll(vector.warnings);
      }
      canvas.restore();
    } on FormatException catch (error) {
      _warn('image $href could not be read: ${error.message}');
    } on ImageFormatException catch (error) {
      _warn('image $href could not be read: ${error.message}');
    }
  }
}

sealed class _Paint {
  const new();
}

final class _ColorPaint extends _Paint {
  const new(this.color);

  final CssColor color;
}

final class _GradientPaint extends _Paint {
  const new(this.element);

  final XmlElement element;
}

final class _TextPiece {
  new(this.text, this.style, this.absolute, this.relative);

  String text;
  final Map<String, String> style;
  final (double?, double?) absolute;
  final (double, double) relative;
}

/// The transformation of an SVG `transform` attribute.
PdfMatrix _parseTransform(String text) {
  var matrix = const PdfMatrix.identity();
  for (final m in RegExp(
    r'(matrix|translate|scale|rotate|skewX|skewY)\s*\(([^)]*)\)',
  ).allMatches(text)) {
    final v = _numbers(m[2]!);
    double at(int i, [double fallback = 0]) => i < v.length ? v[i] : fallback;
    final next = switch (m[1]) {
      'matrix' when v.length >= 6 => PdfMatrix(
        v[0],
        v[1],
        v[2],
        v[3],
        v[4],
        v[5],
      ),
      'translate' => PdfMatrix.translation(at(0), at(1)),
      'scale' => PdfMatrix.scaling(at(0, 1), at(1, at(0, 1))),
      'rotate' => () {
        final r = PdfMatrix.rotation(at(0) * math.pi / 180);
        if (v.length < 3) return r;
        return PdfMatrix.translation(
          -at(1),
          -at(2),
        ).then(r).then(PdfMatrix.translation(at(1), at(2)));
      }(),
      'skewX' => PdfMatrix(1, 0, math.tan(at(0) * math.pi / 180), 1, 0, 0),
      'skewY' => PdfMatrix(1, math.tan(at(0) * math.pi / 180), 0, 1, 0, 0),
      _ => const PdfMatrix.identity(),
    };
    // Transforms apply right to left: the last listed applies first.
    matrix = next.then(matrix);
  }
  return matrix;
}

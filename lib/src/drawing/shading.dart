/// Smooth shadings (ISO 32000-2, 8.7.4.5): axial and radial gradients
/// between color stops.
library;

import 'package:libpdf/src/drawing/color.dart';
import 'package:libpdf/src/objects.dart';
import 'package:meta/meta.dart';

/// A color at a position (0 to 1) of a gradient.
@immutable
final class GradientStop {
  /// [color] at [offset].
  const new(this.offset, this.color);

  /// The position, from 0 to 1.
  final double offset;

  /// The color: gray, RGB or CMYK (all of a gradient's stops alike).
  final PdfColor color;
}

/// A gradient filling the clipping region.
@immutable
sealed class PdfShading {
  const new _(this.stops, {required this.extendStart, required this.extendEnd});

  /// The color stops, by offset.
  final List<GradientStop> stops;

  /// Whether the first color continues before the start.
  final bool extendStart;

  /// Whether the last color continues after the end.
  final bool extendEnd;

  /// The shading dictionary.
  @internal
  PdfDict toDict() {
    final first = stops.first.color;
    final space = switch (first) {
      GrayColor() => 'DeviceGray',
      RgbColor() => 'DeviceRGB',
      CmykColor() => 'DeviceCMYK',
      SpotColor() => throw ArgumentError('spot colors cannot be shaded'),
    };
    for (final stop in stops) {
      if (stop.color.runtimeType != first.runtimeType) {
        throw ArgumentError("a gradient's stops must be of one color space");
      }
    }
    return PdfDict({
      'ShadingType': PdfInt(_type),
      'ColorSpace': PdfName(space),
      'Coords': PdfArray.numbers(_coords),
      'Function': _function(),
      'Extend': PdfArray([PdfBool(extendStart), PdfBool(extendEnd)]),
    });
  }

  int get _type;
  List<double> get _coords;

  /// The function from the parameter (0 to 1) to the stops' colors: one
  /// exponential interpolation, or several stitched together.
  PdfDict _function() {
    final sorted = [...stops]..sort((a, b) => a.offset.compareTo(b.offset));
    final points = [
      if (sorted.first.offset > 0) GradientStop(0, sorted.first.color),
      for (final stop in sorted)
        GradientStop(stop.offset.clamp(0, 1).toDouble(), stop.color),
      if (sorted.last.offset < 1) GradientStop(1, sorted.last.color),
    ];
    PdfDict between(PdfColor a, PdfColor b) => PdfDict({
      'FunctionType': const PdfInt(2),
      'Domain': PdfArray.numbers([0, 1]),
      'C0': PdfArray.numbers(a.components),
      'C1': PdfArray.numbers(b.components),
      'N': const PdfInt(1),
    });
    if (points.length == 2) return between(points[0].color, points[1].color);
    return PdfDict({
      'FunctionType': const PdfInt(3),
      'Domain': PdfArray.numbers([0, 1]),
      'Functions': PdfArray([
        for (var i = 0; i < points.length - 1; i++)
          between(points[i].color, points[i + 1].color),
      ]),
      'Bounds': PdfArray.numbers([
        for (var i = 1; i < points.length - 1; i++) points[i].offset,
      ]),
      'Encode': PdfArray.numbers([
        for (var i = 0; i < points.length - 1; i++) ...[0, 1],
      ]),
    });
  }
}

/// A gradient along the line from ([x0], [y0]) to ([x1], [y1]).
final class AxialShading extends PdfShading {
  /// A linear gradient of [stops].
  const new(
    this.x0,
    this.y0,
    this.x1,
    this.y1,
    super.stops, {
    super.extendStart = true,
    super.extendEnd = true,
  }) : super._();

  /// The start.
  final double x0;

  /// The start.
  final double y0;

  /// The end.
  final double x1;

  /// The end.
  final double y1;

  @override
  int get _type => 2;

  @override
  List<double> get _coords => [x0, y0, x1, y1];
}

/// A gradient between two circles: from the focal circle ([fx], [fy],
/// [fr]) to the circle ([cx], [cy], [r]).
final class RadialShading extends PdfShading {
  /// A radial gradient of [stops].
  const new(
    this.fx,
    this.fy,
    this.fr,
    this.cx,
    this.cy,
    this.r,
    super.stops, {
    super.extendStart = true,
    super.extendEnd = true,
  }) : super._();

  /// The focal circle's center.
  final double fx;

  /// The focal circle's center.
  final double fy;

  /// The focal circle's radius.
  final double fr;

  /// The end circle's center.
  final double cx;

  /// The end circle's center.
  final double cy;

  /// The end circle's radius.
  final double r;

  @override
  int get _type => 3;

  @override
  List<double> get _coords => [fx, fy, fr, cx, cy, r];
}

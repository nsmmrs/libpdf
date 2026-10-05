/// SVG path geometry: the path data grammar (SVG 2, 9.3), shapes as
/// paths, elliptical arcs as Bézier curves (SVG 2, appendix B.2), and
/// paths transformed and drawn on a canvas.
library;

import 'dart:math' as math;

import 'package:libpdf/src/drawing/canvas.dart';
import 'package:libpdf/src/drawing/geometry.dart';

/// A segment of a path, in absolute coordinates.
sealed class PathSegment {
  const new();
}

/// The start of a subpath.
final class MoveSegment extends PathSegment {
  /// A move to ([x], [y]).
  const new(this.x, this.y);

  /// The point.
  final double x;

  /// The point.
  final double y;
}

/// A straight line.
final class LineSegment extends PathSegment {
  /// A line to ([x], [y]).
  const new(this.x, this.y);

  /// The end.
  final double x;

  /// The end.
  final double y;
}

/// A cubic Bézier curve.
final class CubicSegment extends PathSegment {
  /// A curve to ([x], [y]) with control points ([x1], [y1]) and ([x2],
  /// [y2]).
  const new(this.x1, this.y1, this.x2, this.y2, this.x, this.y);

  /// The first control point.
  final double x1;

  /// The first control point.
  final double y1;

  /// The second control point.
  final double x2;

  /// The second control point.
  final double y2;

  /// The end.
  final double x;

  /// The end.
  final double y;
}

/// The end of a subpath, back to its start.
final class CloseSegment extends PathSegment {
  /// A close.
  const new();
}

/// A path: segments in absolute coordinates.
final class SvgPath {
  /// A path of [segments].
  const new(this.segments);

  /// A rectangle, with corners rounded to [rx] by [ry].
  factory rect(
    double x,
    double y,
    double w,
    double h, [
    double rx = 0,
    double ry = 0,
  ]) {
    if (rx <= 0 || ry <= 0) {
      return SvgPath([
        MoveSegment(x, y),
        LineSegment(x + w, y),
        LineSegment(x + w, y + h),
        LineSegment(x, y + h),
        const CloseSegment(),
      ]);
    }
    final kx = rx * _kappa;
    final ky = ry * _kappa;
    return SvgPath([
      MoveSegment(x + rx, y),
      LineSegment(x + w - rx, y),
      CubicSegment(x + w - rx + kx, y, x + w, y + ry - ky, x + w, y + ry),
      LineSegment(x + w, y + h - ry),
      CubicSegment(
        x + w,
        y + h - ry + ky,
        x + w - rx + kx,
        y + h,
        x + w - rx,
        y + h,
      ),
      LineSegment(x + rx, y + h),
      CubicSegment(x + rx - kx, y + h, x, y + h - ry + ky, x, y + h - ry),
      LineSegment(x, y + ry),
      CubicSegment(x, y + ry - ky, x + rx - kx, y, x + rx, y),
      const CloseSegment(),
    ]);
  }

  /// An ellipse centered on ([cx], [cy]) with radii [rx] and [ry].
  factory ellipse(double cx, double cy, double rx, double ry) {
    final kx = rx * _kappa;
    final ky = ry * _kappa;
    return SvgPath([
      MoveSegment(cx + rx, cy),
      CubicSegment(cx + rx, cy + ky, cx + kx, cy + ry, cx, cy + ry),
      CubicSegment(cx - kx, cy + ry, cx - rx, cy + ky, cx - rx, cy),
      CubicSegment(cx - rx, cy - ky, cx - kx, cy - ry, cx, cy - ry),
      CubicSegment(cx + kx, cy - ry, cx + rx, cy - ky, cx + rx, cy),
      const CloseSegment(),
    ]);
  }

  /// A polyline (or, [closed], a polygon) through [points].
  factory polyline(List<double> points, {required bool closed}) => SvgPath([
    for (var i = 0; i + 1 < points.length; i += 2)
      if (i == 0)
        MoveSegment(points[i], points[i + 1])
      else
        LineSegment(points[i], points[i + 1]),
    if (closed && points.length >= 4) const CloseSegment(),
  ]);

  /// The path of SVG path data [data]; parsing stops at the first error,
  /// keeping what came before (as SVG requires).
  factory parse(String data) => _PathParser(data).parse();

  /// The segments.
  final List<PathSegment> segments;

  /// Whether the path draws nothing.
  bool get isEmpty => !segments.any((s) => s is! MoveSegment);

  /// The path transformed by [matrix].
  SvgPath transform(PdfMatrix matrix) => SvgPath([
    for (final segment in segments)
      switch (segment) {
        MoveSegment(:final x, :final y) => () {
          final (tx, ty) = matrix.apply(x, y);
          return MoveSegment(tx, ty);
        }(),
        LineSegment(:final x, :final y) => () {
          final (tx, ty) = matrix.apply(x, y);
          return LineSegment(tx, ty);
        }(),
        CubicSegment(
          :final x1,
          :final y1,
          :final x2,
          :final y2,
          :final x,
          :final y,
        ) =>
          () {
            final (a, b) = matrix.apply(x1, y1);
            final (c, d) = matrix.apply(x2, y2);
            final (e, f) = matrix.apply(x, y);
            return CubicSegment(a, b, c, d, e, f);
          }(),
        CloseSegment() => segment,
      },
  ]);

  /// The bounding box of the path's points and control points.
  PdfRect? get bounds {
    var minX = double.infinity;
    var minY = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;
    void add(double x, double y) {
      minX = math.min(minX, x);
      minY = math.min(minY, y);
      maxX = math.max(maxX, x);
      maxY = math.max(maxY, y);
    }

    for (final segment in segments) {
      switch (segment) {
        case MoveSegment(:final x, :final y) || LineSegment(:final x, :final y):
          add(x, y);
        case CubicSegment(
          :final x1,
          :final y1,
          :final x2,
          :final y2,
          :final x,
          :final y,
        ):
          add(x1, y1);
          add(x2, y2);
          add(x, y);
        case CloseSegment():
          break;
      }
    }
    if (minX > maxX) return null;
    return PdfRect(minX, minY, maxX - minX, maxY - minY);
  }

  /// Adds the path to [canvas]'s current path.
  void addTo(PdfCanvas canvas) {
    var open = false;
    for (final segment in segments) {
      switch (segment) {
        case MoveSegment(:final x, :final y):
          canvas.moveTo(x, y);
          open = true;
        case LineSegment(:final x, :final y):
          if (!open) canvas.moveTo(x, y);
          canvas.lineTo(x, y);
          open = true;
        case CubicSegment(
          :final x1,
          :final y1,
          :final x2,
          :final y2,
          :final x,
          :final y,
        ):
          canvas.curveTo(x1, y1, x2, y2, x, y);
        case CloseSegment():
          if (open) canvas.closePath();
      }
    }
  }
}

/// The control point distance of a quarter circle of radius 1.
final double _kappa = 4 * (math.sqrt(2) - 1) / 3;

final class _PathParser {
  new(this.data);

  final String data;
  int _at = 0;

  void _skipSeparators() {
    while (_at < data.length) {
      final c = data.codeUnitAt(_at);
      if (c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d || c == 0x2c) {
        _at++;
      } else {
        break;
      }
    }
  }

  static final RegExp _number = RegExp(
    r'[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?',
  );

  double? _numberOrNull() {
    _skipSeparators();
    final match = _number.matchAsPrefix(data, _at);
    if (match == null) return null;
    _at = match.end;
    return double.parse(match[0]!);
  }

  bool? _flag() {
    _skipSeparators();
    if (_at >= data.length) return null;
    final c = data[_at];
    if (c != '0' && c != '1') return null;
    _at++;
    return c == '1';
  }

  bool _startsNumber() {
    _skipSeparators();
    if (_at >= data.length) return false;
    final c = data[_at];
    return '0123456789+-.'.contains(c);
  }

  SvgPath parse() {
    final segments = <PathSegment>[];
    var x = 0.0;
    var y = 0.0;
    var startX = 0.0;
    var startY = 0.0;
    // The last control point, for smooth curves.
    double? cx;
    double? cy;
    String? previous;
    String? command;
    while (true) {
      _skipSeparators();
      if (_at >= data.length) break;
      final c = data[_at];
      if (RegExp('[MmLlHhVvCcSsQqTtAaZz]').hasMatch(c)) {
        command = c;
        _at++;
      } else if (command == null || !_startsNumber()) {
        break;
      } else if (command == 'M') {
        command = 'L'; // numbers after a move are lines
      } else if (command == 'm') {
        command = 'l';
      }
      final relative = command.toLowerCase() == command;
      final ox = relative ? x : 0.0;
      final oy = relative ? y : 0.0;
      List<double>? numbers(int count) {
        final values = <double>[];
        for (var i = 0; i < count; i++) {
          final v = _numberOrNull();
          if (v == null) return null;
          values.add(v);
        }
        return values;
      }

      var smooth = false;
      switch (command.toUpperCase()) {
        case 'Z':
          segments.add(const CloseSegment());
          x = startX;
          y = startY;
        case 'M':
          final v = numbers(2);
          if (v == null) return SvgPath(segments);
          x = ox + v[0];
          y = oy + v[1];
          startX = x;
          startY = y;
          segments.add(MoveSegment(x, y));
        case 'L':
          final v = numbers(2);
          if (v == null) return SvgPath(segments);
          x = ox + v[0];
          y = oy + v[1];
          segments.add(LineSegment(x, y));
        case 'H':
          final v = numbers(1);
          if (v == null) return SvgPath(segments);
          x = ox + v[0];
          segments.add(LineSegment(x, y));
        case 'V':
          final v = numbers(1);
          if (v == null) return SvgPath(segments);
          y = oy + v[0];
          segments.add(LineSegment(x, y));
        case 'C':
          final v = numbers(6);
          if (v == null) return SvgPath(segments);
          segments.add(
            CubicSegment(
              ox + v[0],
              oy + v[1],
              ox + v[2],
              oy + v[3],
              ox + v[4],
              oy + v[5],
            ),
          );
          cx = ox + v[2];
          cy = oy + v[3];
          x = ox + v[4];
          y = oy + v[5];
          smooth = true;
        case 'S':
          final v = numbers(4);
          if (v == null) return SvgPath(segments);
          final reflect = previous != null && 'CcSs'.contains(previous);
          final x1 = reflect ? 2 * x - cx! : x;
          final y1 = reflect ? 2 * y - cy! : y;
          segments.add(
            CubicSegment(x1, y1, ox + v[0], oy + v[1], ox + v[2], oy + v[3]),
          );
          cx = ox + v[0];
          cy = oy + v[1];
          x = ox + v[2];
          y = oy + v[3];
          smooth = true;
        case 'Q':
          final v = numbers(4);
          if (v == null) return SvgPath(segments);
          final qx = ox + v[0];
          final qy = oy + v[1];
          segments.add(_quadratic(x, y, qx, qy, ox + v[2], oy + v[3]));
          cx = qx;
          cy = qy;
          x = ox + v[2];
          y = oy + v[3];
          smooth = true;
        case 'T':
          final v = numbers(2);
          if (v == null) return SvgPath(segments);
          final reflect = previous != null && 'QqTt'.contains(previous);
          final qx = reflect ? 2 * x - cx! : x;
          final qy = reflect ? 2 * y - cy! : y;
          segments.add(_quadratic(x, y, qx, qy, ox + v[0], oy + v[1]));
          cx = qx;
          cy = qy;
          x = ox + v[0];
          y = oy + v[1];
          smooth = true;
        case 'A':
          final radii = numbers(3);
          final large = _flag();
          final sweep = _flag();
          final end = numbers(2);
          if (radii == null || large == null || sweep == null || end == null) {
            return SvgPath(segments);
          }
          final ex = ox + end[0];
          final ey = oy + end[1];
          segments.addAll(
            arcToCubics(
              x,
              y,
              radii[0],
              radii[1],
              radii[2],
              ex,
              ey,
              largeArc: large,
              sweep: sweep,
            ),
          );
          x = ex;
          y = ey;
      }
      if (!smooth) {
        cx = null;
        cy = null;
      }
      previous = command;
    }
    return SvgPath(segments);
  }

  static CubicSegment _quadratic(
    double x0,
    double y0,
    double qx,
    double qy,
    double x,
    double y,
  ) => CubicSegment(
    x0 + 2 / 3 * (qx - x0),
    y0 + 2 / 3 * (qy - y0),
    x + 2 / 3 * (qx - x),
    y + 2 / 3 * (qy - y),
    x,
    y,
  );
}

/// The elliptical arc from ([x1], [y1]) to ([x2], [y2]) with radii [rx]
/// and [ry] rotated by [angle] degrees, as cubic Bézier curves (each at
/// most a quarter turn).
List<PathSegment> arcToCubics(
  double x1,
  double y1,
  double rx,
  double ry,
  double angle,
  double x2,
  double y2, {
  required bool largeArc,
  required bool sweep,
}) {
  if (x1 == x2 && y1 == y2) return const [];
  var a = rx.abs();
  var b = ry.abs();
  if (a == 0 || b == 0) return [LineSegment(x2, y2)];
  final phi = angle * math.pi / 180;
  final cosPhi = math.cos(phi);
  final sinPhi = math.sin(phi);
  // F.6.5.1
  final dx = (x1 - x2) / 2;
  final dy = (y1 - y2) / 2;
  final x1p = cosPhi * dx + sinPhi * dy;
  final y1p = -sinPhi * dx + cosPhi * dy;
  // F.6.6: scale up radii that are too small.
  final lambda = x1p * x1p / (a * a) + y1p * y1p / (b * b);
  if (lambda > 1) {
    final s = math.sqrt(lambda);
    a *= s;
    b *= s;
  }
  // F.6.5.2
  final numerator = a * a * b * b - a * a * y1p * y1p - b * b * x1p * x1p;
  final denominator = a * a * y1p * y1p + b * b * x1p * x1p;
  var coefficient = math.sqrt(math.max(0, numerator / denominator));
  if (largeArc == sweep) coefficient = -coefficient;
  final cxp = coefficient * a * y1p / b;
  final cyp = -coefficient * b * x1p / a;
  // F.6.5.3
  final cx = cosPhi * cxp - sinPhi * cyp + (x1 + x2) / 2;
  final cy = sinPhi * cxp + cosPhi * cyp + (y1 + y2) / 2;
  // F.6.5.5, F.6.5.6
  double angleBetween(double ux, double uy, double vx, double vy) {
    final dot = ux * vx + uy * vy;
    final length = math.sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy));
    var value = math.acos((dot / length).clamp(-1, 1).toDouble());
    if (ux * vy - uy * vx < 0) value = -value;
    return value;
  }

  final theta1 = angleBetween(1, 0, (x1p - cxp) / a, (y1p - cyp) / b);
  var delta = angleBetween(
    (x1p - cxp) / a,
    (y1p - cyp) / b,
    (-x1p - cxp) / a,
    (-y1p - cyp) / b,
  );
  if (!sweep && delta > 0) delta -= 2 * math.pi;
  if (sweep && delta < 0) delta += 2 * math.pi;

  final pieces = (delta.abs() / (math.pi / 2)).ceil().clamp(1, 4);
  final step = delta / pieces;
  final t = 4 / 3 * math.tan(step / 4);
  final segments = <PathSegment>[];
  (double, double) point(double theta) {
    final px = a * math.cos(theta);
    final py = b * math.sin(theta);
    return (cosPhi * px - sinPhi * py + cx, sinPhi * px + cosPhi * py + cy);
  }

  (double, double) derivative(double theta) {
    final px = -a * math.sin(theta);
    final py = b * math.cos(theta);
    return (cosPhi * px - sinPhi * py, sinPhi * px + cosPhi * py);
  }

  var theta = theta1;
  for (var i = 0; i < pieces; i++) {
    final next = theta + step;
    final (sx, sy) = point(theta);
    final (ex, ey) = i == pieces - 1 ? (x2, y2) : point(next);
    final (dsx, dsy) = derivative(theta);
    final (dex, dey) = derivative(next);
    segments.add(
      CubicSegment(
        sx + t * dsx,
        sy + t * dsy,
        ex - t * dex,
        ey - t * dey,
        ex,
        ey,
      ),
    );
    theta = next;
  }
  return segments;
}

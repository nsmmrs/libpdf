/// Colors (ISO 32000-2, 8.6): device gray, RGB and CMYK, and spot colors
/// (Separation color spaces with a CMYK alternate).
library;

import 'package:meta/meta.dart';

/// A color to fill or stroke with.
@immutable
sealed class PdfColor {
  const new _();

  /// Gray: 0 is black, 1 is white.
  const factory gray(double level) = GrayColor;

  /// Red, green and blue components from 0 to 1.
  const factory rgb(double red, double green, double blue) = RgbColor;

  /// Cyan, magenta, yellow and black components from 0 to 1.
  const factory cmyk(double cyan, double magenta, double yellow, double black) =
      CmykColor;

  /// The RGB color of a hex triplet such as `ff8000` or `#FF8000` (or
  /// the three-digit `f80`).
  factory hex(String hex) {
    var digits = hex.startsWith('#') ? hex.substring(1) : hex;
    if (digits.length == 3) {
      digits = [for (final c in digits.split('')) '$c$c'].join();
    }
    final value = digits.length == 6 ? int.tryParse(digits, radix: 16) : null;
    if (value == null) {
      throw FormatException('not a hex color', hex);
    }
    return RgbColor(
      (value >> 16) / 255,
      ((value >> 8) & 0xff) / 255,
      (value & 0xff) / 255,
    );
  }

  /// The components, as the color operators take them.
  List<double> get components;
}

/// A device gray color.
final class GrayColor extends PdfColor {
  /// Gray at [level] (0 black, 1 white).
  const new(this.level) : super._();

  /// The gray level.
  final double level;

  @override
  List<double> get components => [level];

  @override
  bool operator ==(Object other) => other is GrayColor && other.level == level;

  @override
  int get hashCode => level.hashCode;
}

/// A device RGB color.
final class RgbColor extends PdfColor {
  /// The color of [red], [green] and [blue] (0 to 1).
  const new(this.red, this.green, this.blue) : super._();

  /// The red component.
  final double red;

  /// The green component.
  final double green;

  /// The blue component.
  final double blue;

  @override
  List<double> get components => [red, green, blue];

  @override
  bool operator ==(Object other) =>
      other is RgbColor &&
      other.red == red &&
      other.green == green &&
      other.blue == blue;

  @override
  int get hashCode => Object.hash(red, green, blue);
}

/// A device CMYK color.
final class CmykColor extends PdfColor {
  /// The color of [cyan], [magenta], [yellow] and [black] (0 to 1).
  const new(this.cyan, this.magenta, this.yellow, this.black) : super._();

  /// The cyan component.
  final double cyan;

  /// The magenta component.
  final double magenta;

  /// The yellow component.
  final double yellow;

  /// The black component.
  final double black;

  @override
  List<double> get components => [cyan, magenta, yellow, black];

  @override
  bool operator ==(Object other) =>
      other is CmykColor &&
      other.cyan == cyan &&
      other.magenta == magenta &&
      other.yellow == yellow &&
      other.black == black;

  @override
  int get hashCode => Object.hash(cyan, magenta, yellow, black);
}

/// A spot color: a named colorant at a [tint], shown on screen (and by
/// printers without the colorant) as its CMYK [alternate] scaled by the
/// tint.
final class SpotColor extends PdfColor {
  /// The colorant [name] at [tint] (0 to 1), approximated by
  /// [alternate].
  const new(this.name, this.alternate, [this.tint = 1]) : super._();

  /// The colorant's name, such as `PANTONE 185 C`.
  final String name;

  /// The colorant at full tint, in CMYK.
  final CmykColor alternate;

  /// The tint.
  final double tint;

  @override
  List<double> get components => [tint];

  @override
  bool operator ==(Object other) =>
      other is SpotColor &&
      other.name == name &&
      other.alternate == alternate &&
      other.tint == tint;

  @override
  int get hashCode => Object.hash(name, alternate, tint);
}

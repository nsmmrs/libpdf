/// CSS colors as SVG uses them (CSS Color Module Level 4: hex, `rgb()`,
/// `rgba()`, `hsl()`, `hsla()`, the named colors, `transparent`).
library;

/// A parsed color: red, green, blue (0 to 1) and alpha (0 to 1).
typedef CssColor = ({double red, double green, double blue, double alpha});

/// The color [text] names, or null when it isn't a color (`none`,
/// `currentColor` and paint server references are the caller's).
CssColor? parseCssColor(String text) {
  final value = text.trim().toLowerCase();
  if (value.startsWith('#')) return _hex(value.substring(1));
  final function = RegExp(r'^(rgba?|hsla?)\((.*)\)$').firstMatch(value);
  if (function != null) {
    final args = function[2]!
        .split(RegExp(r'[\s,/]+'))
        .where((s) => s.isNotEmpty)
        .toList();
    if (args.length < 3) return null;
    final alpha = args.length > 3 ? _unit(args[3]) : 1.0;
    if (alpha == null) return null;
    if (function[1]!.startsWith('rgb')) {
      final [r, g, b] = [for (final a in args.take(3)) _channel(a)];
      if (r == null || g == null || b == null) return null;
      return (red: r, green: g, blue: b, alpha: alpha);
    }
    final hue = double.tryParse(args[0].replaceAll('deg', ''));
    final saturation = _percent(args[1]);
    final lightness = _percent(args[2]);
    if (hue == null || saturation == null || lightness == null) return null;
    final (r, g, b) = _hsl(hue, saturation, lightness);
    return (red: r, green: g, blue: b, alpha: alpha);
  }
  if (value == 'transparent') return (red: 0, green: 0, blue: 0, alpha: 0);
  final named = _named[value];
  if (named == null) return null;
  return (
    red: (named >> 16) / 255,
    green: ((named >> 8) & 0xff) / 255,
    blue: (named & 0xff) / 255,
    alpha: 1,
  );
}

CssColor? _hex(String digits) {
  final expanded = switch (digits.length) {
    3 || 4 => [for (final c in digits.split('')) '$c$c'].join(),
    6 || 8 => digits,
    _ => null,
  };
  if (expanded == null) return null;
  final value = int.tryParse(expanded, radix: 16);
  if (value == null) return null;
  final hasAlpha = expanded.length == 8;
  final rgb = hasAlpha ? value >> 8 : value;
  return (
    red: (rgb >> 16) / 255,
    green: ((rgb >> 8) & 0xff) / 255,
    blue: (rgb & 0xff) / 255,
    alpha: hasAlpha ? (value & 0xff) / 255 : 1,
  );
}

double? _channel(String text) => text.endsWith('%')
    ? _percent(text)
    : switch (double.tryParse(text)) {
        final v? => (v / 255).clamp(0, 1).toDouble(),
        null => null,
      };

double? _percent(String text) =>
    switch (double.tryParse(text.replaceAll('%', ''))) {
      final v? => (v / 100).clamp(0, 1).toDouble(),
      null => null,
    };

double? _unit(String text) => text.endsWith('%')
    ? _percent(text)
    : switch (double.tryParse(text)) {
        final v? => v.clamp(0, 1).toDouble(),
        null => null,
      };

(double, double, double) _hsl(double hue, double s, double l) {
  final h = (hue % 360 + 360) % 360 / 360;
  if (s == 0) return (l, l, l);
  final q = l < 0.5 ? l * (1 + s) : l + s - l * s;
  final p = 2 * l - q;
  double channel(double t) {
    final x = (t % 1 + 1) % 1;
    if (x < 1 / 6) return p + (q - p) * 6 * x;
    if (x < 1 / 2) return q;
    if (x < 2 / 3) return p + (q - p) * (2 / 3 - x) * 6;
    return p;
  }

  return (channel(h + 1 / 3), channel(h), channel(h - 1 / 3));
}

/// The CSS named colors.
const Map<String, int> _named = {
  'aliceblue': 0xf0f8ff,
  'antiquewhite': 0xfaebd7,
  'aqua': 0x00ffff,
  'aquamarine': 0x7fffd4,
  'azure': 0xf0ffff,
  'beige': 0xf5f5dc,
  'bisque': 0xffe4c4,
  'black': 0x000000,
  'blanchedalmond': 0xffebcd,
  'blue': 0x0000ff,
  'blueviolet': 0x8a2be2,
  'brown': 0xa52a2a,
  'burlywood': 0xdeb887,
  'cadetblue': 0x5f9ea0,
  'chartreuse': 0x7fff00,
  'chocolate': 0xd2691e,
  'coral': 0xff7f50,
  'cornflowerblue': 0x6495ed,
  'cornsilk': 0xfff8dc,
  'crimson': 0xdc143c,
  'cyan': 0x00ffff,
  'darkblue': 0x00008b,
  'darkcyan': 0x008b8b,
  'darkgoldenrod': 0xb8860b,
  'darkgray': 0xa9a9a9,
  'darkgreen': 0x006400,
  'darkgrey': 0xa9a9a9,
  'darkkhaki': 0xbdb76b,
  'darkmagenta': 0x8b008b,
  'darkolivegreen': 0x556b2f,
  'darkorange': 0xff8c00,
  'darkorchid': 0x9932cc,
  'darkred': 0x8b0000,
  'darksalmon': 0xe9967a,
  'darkseagreen': 0x8fbc8f,
  'darkslateblue': 0x483d8b,
  'darkslategray': 0x2f4f4f,
  'darkslategrey': 0x2f4f4f,
  'darkturquoise': 0x00ced1,
  'darkviolet': 0x9400d3,
  'deeppink': 0xff1493,
  'deepskyblue': 0x00bfff,
  'dimgray': 0x696969,
  'dimgrey': 0x696969,
  'dodgerblue': 0x1e90ff,
  'firebrick': 0xb22222,
  'floralwhite': 0xfffaf0,
  'forestgreen': 0x228b22,
  'fuchsia': 0xff00ff,
  'gainsboro': 0xdcdcdc,
  'ghostwhite': 0xf8f8ff,
  'gold': 0xffd700,
  'goldenrod': 0xdaa520,
  'gray': 0x808080,
  'green': 0x008000,
  'greenyellow': 0xadff2f,
  'grey': 0x808080,
  'honeydew': 0xf0fff0,
  'hotpink': 0xff69b4,
  'indianred': 0xcd5c5c,
  'indigo': 0x4b0082,
  'ivory': 0xfffff0,
  'khaki': 0xf0e68c,
  'lavender': 0xe6e6fa,
  'lavenderblush': 0xfff0f5,
  'lawngreen': 0x7cfc00,
  'lemonchiffon': 0xfffacd,
  'lightblue': 0xadd8e6,
  'lightcoral': 0xf08080,
  'lightcyan': 0xe0ffff,
  'lightgoldenrodyellow': 0xfafad2,
  'lightgray': 0xd3d3d3,
  'lightgreen': 0x90ee90,
  'lightgrey': 0xd3d3d3,
  'lightpink': 0xffb6c1,
  'lightsalmon': 0xffa07a,
  'lightseagreen': 0x20b2aa,
  'lightskyblue': 0x87cefa,
  'lightslategray': 0x778899,
  'lightslategrey': 0x778899,
  'lightsteelblue': 0xb0c4de,
  'lightyellow': 0xffffe0,
  'lime': 0x00ff00,
  'limegreen': 0x32cd32,
  'linen': 0xfaf0e6,
  'magenta': 0xff00ff,
  'maroon': 0x800000,
  'mediumaquamarine': 0x66cdaa,
  'mediumblue': 0x0000cd,
  'mediumorchid': 0xba55d3,
  'mediumpurple': 0x9370db,
  'mediumseagreen': 0x3cb371,
  'mediumslateblue': 0x7b68ee,
  'mediumspringgreen': 0x00fa9a,
  'mediumturquoise': 0x48d1cc,
  'mediumvioletred': 0xc71585,
  'midnightblue': 0x191970,
  'mintcream': 0xf5fffa,
  'mistyrose': 0xffe4e1,
  'moccasin': 0xffe4b5,
  'navajowhite': 0xffdead,
  'navy': 0x000080,
  'oldlace': 0xfdf5e6,
  'olive': 0x808000,
  'olivedrab': 0x6b8e23,
  'orange': 0xffa500,
  'orangered': 0xff4500,
  'orchid': 0xda70d6,
  'palegoldenrod': 0xeee8aa,
  'palegreen': 0x98fb98,
  'paleturquoise': 0xafeeee,
  'palevioletred': 0xdb7093,
  'papayawhip': 0xffefd5,
  'peachpuff': 0xffdab9,
  'peru': 0xcd853f,
  'pink': 0xffc0cb,
  'plum': 0xdda0dd,
  'powderblue': 0xb0e0e6,
  'purple': 0x800080,
  'rebeccapurple': 0x663399,
  'red': 0xff0000,
  'rosybrown': 0xbc8f8f,
  'royalblue': 0x4169e1,
  'saddlebrown': 0x8b4513,
  'salmon': 0xfa8072,
  'sandybrown': 0xf4a460,
  'seagreen': 0x2e8b57,
  'seashell': 0xfff5ee,
  'sienna': 0xa0522d,
  'silver': 0xc0c0c0,
  'skyblue': 0x87ceeb,
  'slateblue': 0x6a5acd,
  'slategray': 0x708090,
  'slategrey': 0x708090,
  'snow': 0xfffafa,
  'springgreen': 0x00ff7f,
  'steelblue': 0x4682b4,
  'tan': 0xd2b48c,
  'teal': 0x008080,
  'thistle': 0xd8bfd8,
  'tomato': 0xff6347,
  'turquoise': 0x40e0d0,
  'violet': 0xee82ee,
  'wheat': 0xf5deb3,
  'white': 0xffffff,
  'whitesmoke': 0xf5f5f5,
  'yellow': 0xffff00,
  'yellowgreen': 0x9acd32,
};

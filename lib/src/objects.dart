/// The PDF object model (ISO 32000-2, 7.3): the eight basic object types
/// and indirect references, as sealed Dart types that serialize
/// themselves.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

/// A PDF object.
sealed class PdfObject {
  const new();

  /// Writes the object's syntax to [out].
  void writeTo(BytesBuilder out);

  /// The object's syntax.
  Uint8List toBytes() {
    final out = BytesBuilder();
    writeTo(out);
    return out.takeBytes();
  }

  @override
  String toString() => latin1.decode(toBytes(), allowInvalid: true);
}

/// The null object.
final class PdfNull extends PdfObject {
  /// The null object.
  const new();

  @override
  void writeTo(BytesBuilder out) => out.add(_null);

  static final List<int> _null = ascii.encode('null');
}

/// A boolean.
@immutable
final class PdfBool extends PdfObject {
  /// A boolean of [value].
  // A boolean object is its value; a name would add nothing.
  // ignore: avoid_positional_boolean_parameters
  const new(this.value);

  /// The value.
  final bool value;

  @override
  void writeTo(BytesBuilder out) => out.add(ascii.encode('$value'));

  @override
  bool operator ==(Object other) => other is PdfBool && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

/// An integer.
@immutable
final class PdfInt extends PdfObject {
  /// An integer of [value].
  const new(this.value);

  /// The value.
  final int value;

  @override
  void writeTo(BytesBuilder out) => out.add(ascii.encode('$value'));

  @override
  bool operator ==(Object other) => other is PdfInt && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

/// A real number, written in decimal with at most [precision] digits
/// after the point (PDF has no exponent notation).
@immutable
final class PdfReal extends PdfObject {
  /// A real of [value].
  const new(this.value, {this.precision = 5});

  /// The value.
  final double value;

  /// The digits written after the decimal point, at most.
  final int precision;

  @override
  void writeTo(BytesBuilder out) =>
      out.add(ascii.encode(formatNumber(value, precision: precision)));

  @override
  bool operator ==(Object other) =>
      other is PdfReal && other.value == value && other.precision == precision;

  @override
  int get hashCode => Object.hash(value, precision);
}

/// [value] as PDF number syntax: an integer when it has no fraction, else
/// a decimal with at most [precision] digits after the point and no
/// trailing zeros.
String formatNumber(num value, {int precision = 5}) {
  if (value is int) return '$value';
  final v = value.toDouble();
  if (v.isNaN || v.isInfinite) {
    throw ArgumentError.value(value, 'value', 'is not a finite number');
  }
  if (v.abs() >= 1e15) {
    throw ArgumentError.value(value, 'value', 'is too large for a PDF number');
  }
  if (v == v.truncateToDouble()) {
    final whole = v.toInt();
    return whole == 0 ? '0' : '$whole';
  }
  final text = v.toStringAsFixed(precision);
  // Trailing zeros (and the point) dropped.
  var end = text.length;
  while (end > 0 && text.codeUnitAt(end - 1) == 0x30) {
    end--;
  }
  if (end > 0 && text.codeUnitAt(end - 1) == 0x2e) end--;
  final trimmed = text.substring(0, end);
  return trimmed == '-0' || trimmed.isEmpty ? '0' : trimmed;
}

/// A string: bytes, written as a literal string (`(...)`) or as
/// hexadecimal (`<...>`).
@immutable
final class PdfString extends PdfObject {
  /// A string of [bytes].
  new(List<int> bytes, {this.hex = false}) : bytes = Uint8List.fromList(bytes);

  /// A text string (ISO 32000-2, 7.9.2.2): PDFDocEncoding when [text]
  /// fits it, else UTF-16BE with a byte order mark.
  factory text(String text) {
    final encoded = pdfDocEncode(text);
    if (encoded != null) return PdfString(encoded);
    final units = <int>[0xfe, 0xff];
    for (final unit in text.codeUnits) {
      units
        ..add(unit >> 8)
        ..add(unit & 0xff);
    }
    return PdfString(units);
  }

  /// The bytes of the string.
  final Uint8List bytes;

  /// Whether the string is written in hexadecimal.
  final bool hex;

  @override
  void writeTo(BytesBuilder out) {
    if (hex) {
      out.addByte(0x3c);
      for (final b in bytes) {
        out
          ..addByte(_hexDigits[b >> 4])
          ..addByte(_hexDigits[b & 0xf]);
      }
      out.addByte(0x3e);
      return;
    }
    out.addByte(0x28);
    for (final b in bytes) {
      switch (b) {
        case 0x28 || 0x29 || 0x5c: // ( ) \
          out
            ..addByte(0x5c)
            ..addByte(b);
        case 0x0d: // \r would be read as an end of line
          out
            ..addByte(0x5c)
            ..addByte(0x72);
        default:
          out.addByte(b);
      }
    }
    out.addByte(0x29);
  }

  @override
  bool operator ==(Object other) =>
      other is PdfString && other.hex == hex && _sameBytes(other.bytes, bytes);

  @override
  int get hashCode => Object.hashAll(bytes);
}

final List<int> _hexDigits = ascii.encode('0123456789ABCDEF');

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// [text] in PDFDocEncoding, or `null` when it has a character outside it.
List<int>? pdfDocEncode(String text) {
  final out = <int>[];
  for (final rune in text.runes) {
    if (rune < 0x80 && rune != 0x7f) {
      out.add(rune);
    } else if (rune >= 0xa1 && rune <= 0xff && rune != 0xad) {
      out.add(rune);
    } else {
      final code = _pdfDocExtras[rune];
      if (code == null) return null;
      out.add(code);
    }
  }
  return out;
}

/// The PDFDocEncoding codes for characters outside Latin-1's shared range
/// (ISO 32000-2, Annex D.2).
const Map<int, int> _pdfDocExtras = {
  0x02d8: 0x18, 0x02c7: 0x19, 0x02c6: 0x1a, 0x02d9: 0x1b, 0x02dd: 0x1c, //
  0x02db: 0x1d, 0x02da: 0x1e, 0x02dc: 0x1f, 0x2022: 0x80, 0x2020: 0x81,
  0x2021: 0x82, 0x2026: 0x83, 0x2014: 0x84, 0x2013: 0x85, 0x0192: 0x86,
  0x2044: 0x87, 0x2039: 0x88, 0x203a: 0x89, 0x2212: 0x8a, 0x2030: 0x8b,
  0x201e: 0x8c, 0x201c: 0x8d, 0x201d: 0x8e, 0x2018: 0x8f, 0x2019: 0x90,
  0x201a: 0x91, 0x2122: 0x92, 0xfb01: 0x93, 0xfb02: 0x94, 0x0141: 0x95,
  0x0152: 0x96, 0x0160: 0x97, 0x0178: 0x98, 0x017d: 0x99, 0x0131: 0x9a,
  0x0142: 0x9b, 0x0153: 0x9c, 0x0161: 0x9d, 0x017e: 0x9e, 0x20ac: 0xa0,
};

/// A name (`/Type`): written with `#xx` for bytes that aren't regular
/// characters.
@immutable
final class PdfName extends PdfObject {
  /// The name [value] (without the slash).
  const new(this.value);

  /// The name, without the slash.
  final String value;

  @override
  void writeTo(BytesBuilder out) {
    out.addByte(0x2f);
    for (final b in utf8.encode(value)) {
      if (b < 0x21 || b > 0x7e || _delimiters.contains(b) || b == 0x23) {
        out
          ..addByte(0x23)
          ..addByte(_hexDigits[b >> 4])
          ..addByte(_hexDigits[b & 0xf]);
      } else {
        out.addByte(b);
      }
    }
  }

  @override
  bool operator ==(Object other) => other is PdfName && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

/// The delimiter characters (ISO 32000-2, 7.2.3).
const Set<int> _delimiters = {
  0x28, 0x29, 0x3c, 0x3e, 0x5b, 0x5d, 0x7b, 0x7d, 0x2f, 0x25, //
};

/// An array.
final class PdfArray extends PdfObject {
  /// An array of [items].
  new([List<PdfObject>? items]) : items = items ?? [];

  /// An array of numbers ([PdfInt] for ints, [PdfReal] otherwise).
  factory numbers(Iterable<num> values) => PdfArray([
    for (final v in values)
      if (v is int) PdfInt(v) else PdfReal(v.toDouble()),
  ]);

  /// The items.
  final List<PdfObject> items;

  @override
  void writeTo(BytesBuilder out) {
    out.addByte(0x5b);
    for (var i = 0; i < items.length; i++) {
      if (i > 0) out.addByte(0x20);
      items[i].writeTo(out);
    }
    out.addByte(0x5d);
  }
}

/// A dictionary: names to objects, in insertion order.
final class PdfDict extends PdfObject {
  /// A dictionary of [entries] (keys without the slash).
  new([Map<String, PdfObject>? entries]) : entries = {...?entries};

  /// The entries, by name (without the slash).
  final Map<String, PdfObject> entries;

  /// The value for [key], or `null`.
  PdfObject? operator [](String key) => entries[key];

  /// Sets [key] to [value].
  void operator []=(String key, PdfObject value) => entries[key] = value;

  @override
  void writeTo(BytesBuilder out) {
    out.add(_open);
    for (final MapEntry(:key, :value) in entries.entries) {
      out.addByte(0x20);
      PdfName(key).writeTo(out);
      out.addByte(0x20);
      value.writeTo(out);
    }
    out.add(_close);
  }

  static final List<int> _open = ascii.encode('<<');
  static final List<int> _close = ascii.encode(' >>');
}

/// A stream: a dictionary and bytes. The writer sets `/Length`, and
/// compresses the data (`/FlateDecode`) unless the stream has a filter
/// already or asks not to be compressed.
final class PdfStream extends PdfObject {
  /// A stream of [data] with [dict].
  new(List<int> data, {PdfDict? dict, this.compress = true})
    : data = data is Uint8List ? data : Uint8List.fromList(data),
      dict = dict ?? PdfDict();

  /// The stream dictionary (without `/Length`).
  final PdfDict dict;

  /// The stream's bytes, as they are written (already encoded when the
  /// dictionary has a `/Filter`).
  final Uint8List data;

  /// Whether the writer may compress the data.
  final bool compress;

  /// Streams are written by the writer, which knows the final data.
  @override
  void writeTo(BytesBuilder out) {
    PdfDict({...dict.entries, 'Length': PdfInt(data.length)}).writeTo(out);
    out
      ..add(_streamStart)
      ..add(data)
      ..add(_streamEnd);
  }

  static final List<int> _streamStart = ascii.encode('\nstream\n');
  static final List<int> _streamEnd = ascii.encode('\nendstream');
}

/// A reference to the indirect object [number] of [generation].
@immutable
final class PdfRef extends PdfObject {
  /// A reference to object [number], [generation].
  const new(this.number, [this.generation = 0]);

  /// The object number.
  final int number;

  /// The generation number.
  final int generation;

  @override
  void writeTo(BytesBuilder out) =>
      out.add(ascii.encode('$number $generation R'));

  @override
  bool operator ==(Object other) =>
      other is PdfRef &&
      other.number == number &&
      other.generation == generation;

  @override
  int get hashCode => Object.hash(number, generation);
}

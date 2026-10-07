/// Stream filters (ISO 32000-2, 7.4) for reading: decoding the data of
/// streams read from a file.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:compression/compression.dart';
import 'package:libpdf/src/objects.dart';
import 'package:libpdf/src/reader/reader.dart';

/// The decoded data of [stream], whose filter and parameters are
/// resolved by [resolve].
Uint8List decodeStream(
  PdfStream stream,
  PdfObject? Function(PdfObject? object) resolve,
) {
  final filters = switch (resolve(stream.dict['Filter'])) {
    final PdfName name => [name],
    PdfArray(:final items) => [
      for (final item in items)
        if (resolve(item) case final PdfName name) name,
    ],
    _ => const <PdfName>[],
  };
  final parameters = switch (resolve(stream.dict['DecodeParms'])) {
    final PdfDict dict => [dict],
    PdfArray(:final items) => [
      for (final item in items)
        if (resolve(item) case final PdfDict dict) dict else null,
    ],
    _ => const <PdfDict?>[],
  };
  var data = stream.data;
  try {
    data = _decode(data, filters, parameters, resolve);
  } on FormatException catch (error) {
    throw PdfFormatException('a stream could not be decoded: ${error.message}');
  }
  return data;
}

Uint8List _decode(
  Uint8List input,
  List<PdfName> filters,
  List<PdfDict?> parameters,
  PdfObject? Function(PdfObject?) resolve,
) {
  var data = input;
  for (final (i, filter) in filters.indexed) {
    final params = i < parameters.length ? parameters[i] : null;
    data = switch (filter.value) {
      'FlateDecode' || 'Fl' => _predict(zlibDecode(data), params, resolve),
      'LZWDecode' || 'LZW' => _predict(
        _lzw(data, early: _int(params?['EarlyChange'], resolve) ?? 1),
        params,
        resolve,
      ),
      'ASCIIHexDecode' || 'AHx' => _asciiHex(data),
      'ASCII85Decode' || 'A85' => _ascii85(data),
      'RunLengthDecode' || 'RL' => _runLength(data),
      final name => throw PdfFormatException(
        'streams encoded with $name are not supported',
      ),
    };
  }
  return data;
}

int? _int(PdfObject? object, PdfObject? Function(PdfObject?) resolve) =>
    switch (resolve(object)) {
      PdfInt(:final value) => value,
      PdfReal(:final value) => value.toInt(),
      _ => null,
    };

/// [data] with the PNG predictors of [params] undone.
Uint8List _predict(
  Uint8List data,
  PdfDict? params,
  PdfObject? Function(PdfObject?) resolve,
) {
  final predictor = _int(params?['Predictor'], resolve) ?? 1;
  if (predictor < 10) {
    if (predictor == 1) return data;
    throw const PdfFormatException('TIFF predictors are not supported');
  }
  final colors = _int(params?['Colors'], resolve) ?? 1;
  final bits = _int(params?['BitsPerComponent'], resolve) ?? 8;
  final columns = _int(params?['Columns'], resolve) ?? 1;
  final pixel = ((colors * bits) / 8).ceil().clamp(1, 32);
  final row = (colors * bits * columns / 8).ceil();
  final out = BytesBuilder(copy: false);
  var previous = Uint8List(row);
  for (var at = 0; at < data.length; at += row + 1) {
    final type = data[at];
    final end = (at + 1 + row).clamp(0, data.length);
    final current = Uint8List(row)..setRange(0, end - at - 1, data, at + 1);
    for (var i = 0; i < row; i++) {
      final left = i >= pixel ? current[i - pixel] : 0;
      final up = previous[i];
      final upLeft = i >= pixel ? previous[i - pixel] : 0;
      current[i] = switch (type) {
        1 => current[i] + left,
        2 => current[i] + up,
        3 => current[i] + ((left + up) >> 1),
        4 => current[i] + _paeth(left, up, upLeft),
        _ => current[i],
      };
    }
    out.add(current);
    previous = current;
  }
  return out.takeBytes();
}

int _paeth(int a, int b, int c) {
  final p = a + b - c;
  final pa = (p - a).abs();
  final pb = (p - b).abs();
  final pc = (p - c).abs();
  if (pa <= pb && pa <= pc) return a;
  return pb <= pc ? b : c;
}

Uint8List _lzw(Uint8List data, {required int early}) {
  final out = BytesBuilder(copy: false);
  var table = <List<int>>[];
  void reset() => table = [
    for (var i = 0; i < 256; i++) [i],
    const [],
    const [],
  ];
  reset();
  var width = 9;
  var buffer = 0;
  var count = 0;
  List<int>? previous;
  for (final byte in data) {
    buffer = (buffer << 8) | byte;
    count += 8;
    while (count >= width) {
      count -= width;
      final code = (buffer >> count) & ((1 << width) - 1);
      if (code == 256) {
        reset();
        width = 9;
        previous = null;
        continue;
      }
      if (code == 257) return out.takeBytes();
      final List<int> entry;
      if (code < table.length) {
        entry = table[code];
        if (previous != null) table.add([...previous, entry.first]);
      } else if (previous != null) {
        entry = [...previous, previous.first];
        table.add(entry);
      } else {
        throw const PdfFormatException('invalid LZW data');
      }
      out.add(entry);
      previous = entry;
      if (table.length + early >= (1 << width) && width < 12) width++;
    }
  }
  return out.takeBytes();
}

Uint8List _asciiHex(Uint8List data) {
  final digits = <int>[];
  for (final byte in data) {
    if (byte == 0x3e) break;
    final value = _hexValue(byte);
    if (value != null) digits.add(value);
  }
  if (digits.length.isOdd) digits.add(0);
  return Uint8List.fromList([
    for (var i = 0; i < digits.length; i += 2) digits[i] << 4 | digits[i + 1],
  ]);
}

/// The value of the hexadecimal digit [byte], or null.
int? _hexValue(int byte) => switch (byte) {
  >= 0x30 && <= 0x39 => byte - 0x30,
  >= 0x41 && <= 0x46 => byte - 0x37,
  >= 0x61 && <= 0x66 => byte - 0x57,
  _ => null,
};

Uint8List _ascii85(Uint8List data) {
  final out = BytesBuilder(copy: false);
  final group = <int>[];
  var text = latin1.decode(data);
  if (text.startsWith('<~')) text = text.substring(2);
  for (final unit in text.codeUnits) {
    if (unit == 0x7e) break;
    if (unit == 0x7a && group.isEmpty) {
      out.add(const [0, 0, 0, 0]);
      continue;
    }
    if (unit < 0x21 || unit > 0x75) continue;
    group.add(unit - 0x21);
    if (group.length == 5) {
      out.add(_base85(group, 4));
      group.clear();
    }
  }
  if (group.length > 1) {
    final length = group.length - 1;
    while (group.length < 5) {
      group.add(84);
    }
    out.add(_base85(group, length));
  }
  return out.takeBytes();
}

List<int> _base85(List<int> digits, int length) {
  var value = 0;
  for (final digit in digits) {
    value = value * 85 + digit;
  }
  return [for (var i = 0; i < length; i++) (value >> (24 - 8 * i)) & 0xff];
}

Uint8List _runLength(Uint8List data) {
  final out = BytesBuilder(copy: false);
  var at = 0;
  while (at < data.length) {
    final length = data[at++];
    if (length == 128) break;
    if (length < 128) {
      final end = (at + length + 1).clamp(0, data.length);
      out.add(Uint8List.sublistView(data, at, end));
      at = end;
    } else if (at < data.length) {
      out.add(List.filled(257 - length, data[at++]));
    }
  }
  return out.takeBytes();
}

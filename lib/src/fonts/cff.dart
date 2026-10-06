/// Subsetting CFF font programs (Compact Font Format, Adobe TN 5176;
/// Type 2 charstrings, Adobe TN 5177): the glyphs a document uses keep
/// their charstrings and their glyph ids, the others become empty glyphs,
/// and the subroutines no kept glyph calls become empty too. Name-keyed
/// and CID-keyed fonts alike.
library;

import 'dart:typed_data';

/// The CFF table [cff] with only the charstrings of [glyphs] (glyph ids
/// kept; all of them when null) and the subroutines they call, and an
/// identity charset for a CID font; null when it can't be rewritten
/// (CFF2, `seac` accents, a damaged table), so the font is embedded whole.
Uint8List? subsetCff(Uint8List cff, Set<int>? glyphs) {
  try {
    return _Cff(cff).subset(glyphs);
  } on _Unsupported {
    return null;
    // A damaged table reads out of bounds: embed the font as it is.
    // ignore: avoid_catching_errors
  } on RangeError {
    return null;
  }
}

final class _Unsupported implements Exception {
  const new();
}

/// An INDEX: its items, as views of the CFF data.
typedef _Index = List<Uint8List>;

/// A DICT: operands by operator (two-byte operators as 1200 + the second
/// byte).
typedef _Dict = Map<int, List<num>>;

final class _Cff {
  new(this._data);

  final Uint8List _data;

  Uint8List subset(Set<int>? glyphs) {
    if (_data.isEmpty || _data[0] != 1) throw const _Unsupported();
    final hdrSize = _data[2];
    var at = hdrSize;
    final (names, afterNames) = _index(at);
    at = afterNames;
    final (topDicts, afterTop) = _index(at);
    at = afterTop;
    final (strings, afterStrings) = _index(at);
    at = afterStrings;
    final (globalSubrs, _) = _index(at);
    if (topDicts.length != 1) throw const _Unsupported();
    final top = _dict(topDicts.single);
    if (_int(top, 1206, 2) != 2) throw const _Unsupported();
    final (charStrings, _) = _index(_int(top, 17));
    final keep = glyphs ?? {for (var g = 0; g < charStrings.length; g++) g};
    final cid = top.containsKey(1230);

    // The private DICTs (one per font DICT for a CID font) and their local
    // subroutines, and which private DICT each glyph uses.
    final privates = <(_Dict, _Index)>[];
    final List<_Dict> fontDicts;
    Uint8List? fdSelect;
    int Function(int glyph) fdOf;
    if (cid) {
      final (fdArray, _) = _index(_int(top, 1236));
      fontDicts = [for (final item in fdArray) _dict(item)];
      for (final fd in fontDicts) {
        privates.add(_private(fd));
      }
      final (select, selectEnd) = _fdSelect(
        _int(top, 1237),
        charStrings.length,
      );
      fdSelect = Uint8List.sublistView(_data, _int(top, 1237), selectEnd);
      fdOf = (glyph) => select[glyph];
    } else {
      fontDicts = const [];
      privates.add(_private(top));
      fdOf = (_) => 0;
    }

    // The subroutines the kept glyphs call.
    final usedGlobal = <int>{};
    final usedLocal = [for (final _ in privates) <int>{}];
    for (final glyph in {0, ...keep}) {
      if (glyph < 0 || glyph >= charStrings.length) continue;
      final fd = fdOf(glyph);
      _Charstring(
        globalSubrs,
        privates[fd].$2,
        usedGlobal,
        usedLocal[fd],
      ).run(charStrings[glyph]);
    }

    final emptyGlyph = Uint8List.fromList([0x0e]); // endchar
    final emptySubr = Uint8List.fromList([0x0b]); // return
    final newCharStrings = [
      for (var g = 0; g < charStrings.length; g++)
        if (g == 0 || keep.contains(g)) charStrings[g] else emptyGlyph,
    ];
    final newGlobal = [
      for (var i = 0; i < globalSubrs.length; i++)
        if (usedGlobal.contains(i)) globalSubrs[i] else emptySubr,
    ];
    final newLocals = [
      for (final (fd, (_, subrs)) in privates.indexed)
        [
          for (var i = 0; i < subrs.length; i++)
            if (usedLocal[fd].contains(i)) subrs[i] else emptySubr,
        ],
    ];

    // The layout: header, Name, Top DICT, String and Global Subr INDEXes,
    // then the charset, encoding, FDSelect, CharStrings, FDArray and the
    // private DICTs with their subroutines. Integers in DICTs are written
    // in 5 bytes, so a DICT's size doesn't depend on the offsets in it.
    // A CID font gets an identity charset: CID n is glyph n, as PDF text
    // addresses it.
    final charset = cid
        ? _identityCharset(charStrings.length)
        : _optionalTable(top, 15, charStrings.length);
    final encoding = cid ? null : _optionalTable(top, 16, charStrings.length);
    final privates2 = [
      for (final (fd, (private, _)) in privates.indexed)
        (private, newLocals[fd]),
    ];

    // The parts after the INDEXes, given their offsets: charset, encoding,
    // FDSelect, CharStrings, FDArray, then each private DICT.
    List<Uint8List> parts(List<int> offsets) => [
      charset ?? Uint8List(0),
      encoding ?? Uint8List(0),
      fdSelect ?? Uint8List(0),
      _writeIndex(newCharStrings),
      if (cid)
        _writeIndex([
          for (final (i, fd) in fontDicts.indexed)
            _writeDict({
              ...fd,
              18: [_privateSize(privates2[i]), offsets[5 + i]],
            }),
        ])
      else
        Uint8List(0),
      for (final private in privates2) _writePrivate(private),
    ];

    Uint8List head(List<int> offsets) {
      final newTop = {...top}
        ..[17] = [offsets[3]]
        ..remove(18)
        ..remove(1236)
        ..remove(1237);
      if (charset != null) newTop[15] = [offsets[0]];
      if (encoding != null) newTop[16] = [offsets[1]];
      if (cid) {
        newTop[1236] = [offsets[4]];
        newTop[1237] = [offsets[2]];
      } else {
        newTop[18] = [_privateSize(privates2[0]), offsets[5]];
      }
      return (BytesBuilder(copy: false)
            ..add(Uint8List.sublistView(_data, 0, hdrSize))
            ..add(_writeIndex(names))
            ..add(_writeIndex([_writeDict(newTop)]))
            ..add(_writeIndex(strings))
            ..add(_writeIndex(newGlobal)))
          .takeBytes();
    }

    // Sizes don't depend on offsets: measure with zeros, then place.
    final zeros = List.filled(5 + privates2.length, 0);
    var at2 = head(zeros).length;
    final offsets = <int>[];
    for (final part in parts(zeros)) {
      offsets.add(at2);
      at2 += part.length;
    }
    final out = BytesBuilder(copy: false)..add(head(offsets));
    parts(offsets).forEach(out.add);
    return out.takeBytes();
  }

  /// A charset that gives glyph n the CID n (format 2, one range).
  static Uint8List _identityCharset(int glyphs) {
    if (glyphs < 2) return Uint8List.fromList([0]);
    final left = glyphs - 2;
    return Uint8List.fromList([2, 0, 1, left >> 8, left & 0xff]);
  }

  /// A private DICT and its local subroutines, from the `Private` entry
  /// of [dict].
  (_Dict, _Index) _private(_Dict dict) {
    final entry = dict[18];
    if (entry == null || entry.length != 2) return (<int, List<num>>{}, []);
    final size = entry[0].toInt();
    final offset = entry[1].toInt();
    final private = _dict(Uint8List.sublistView(_data, offset, offset + size));
    final subrs = private.containsKey(19)
        ? _index(offset + _int(private, 19)).$1
        : <Uint8List>[];
    return (private, subrs);
  }

  /// The size of the private DICT of [private] as written.
  static int _privateSize((_Dict, List<Uint8List>) private) =>
      _writeDict(_withSubrs(private.$1, private.$2)).length;

  /// A private DICT (its local subroutines right after it).
  static Uint8List _writePrivate((_Dict, List<Uint8List>) private) {
    final dict = _writeDict(_withSubrs(private.$1, private.$2));
    return (BytesBuilder(copy: false)
          ..add(dict)
          ..add(private.$2.isEmpty ? Uint8List(0) : _writeIndex(private.$2)))
        .takeBytes();
  }

  /// [dict] pointing at its subroutines right after it (or without
  /// them).
  static _Dict _withSubrs(_Dict dict, List<Uint8List> subrs) {
    final copy = {...dict}..remove(19);
    if (subrs.isEmpty) return copy;
    // The offset is the DICT's own size, which includes the offset's 5
    // bytes.
    final size = _writeDict({
      ...copy,
      19: [0],
    }).length;
    return copy..[19] = [size];
  }

  /// The charset or encoding table at the offset of [key] in [top], when
  /// it isn't a predefined one (offsets 0–2), copied as it is.
  Uint8List? _optionalTable(_Dict top, int key, int glyphs) {
    final offset = top[key]?.firstOrNull?.toInt();
    if (offset == null || offset <= 2) return null;
    final end = key == 15 ? _charsetEnd(offset, glyphs) : _encodingEnd(offset);
    return Uint8List.sublistView(_data, offset, end);
  }

  int _charsetEnd(int offset, int glyphs) {
    final format = _data[offset];
    var at = offset + 1;
    switch (format) {
      case 0:
        return at + 2 * (glyphs - 1);
      case 1 || 2:
        var covered = 1;
        while (covered < glyphs) {
          final left = format == 1
              ? _data[at + 2]
              : _data[at + 2] << 8 | _data[at + 3];
          at += format == 1 ? 3 : 4;
          covered += left + 1;
        }
        return at;
      default:
        throw const _Unsupported();
    }
  }

  int _encodingEnd(int offset) {
    final format = _data[offset];
    var at = offset + 1;
    switch (format & 0x7f) {
      case 0:
        at += 1 + _data[at];
      case 1:
        at += 1 + 2 * _data[at];
      default:
        throw const _Unsupported();
    }
    if (format & 0x80 != 0) at += 1 + 3 * _data[at];
    return at;
  }

  /// The font DICT of each glyph, and where the FDSelect ends.
  (List<int>, int) _fdSelect(int offset, int glyphs) {
    final format = _data[offset];
    switch (format) {
      case 0:
        return (
          [for (var g = 0; g < glyphs; g++) _data[offset + 1 + g]],
          offset + 1 + glyphs,
        );
      case 3:
        final ranges = _data[offset + 1] << 8 | _data[offset + 2];
        final select = List.filled(glyphs, 0);
        var at = offset + 3;
        for (var r = 0; r < ranges; r++) {
          final first = _data[at] << 8 | _data[at + 1];
          final fd = _data[at + 2];
          final next = _data[at + 3] << 8 | _data[at + 4];
          for (var g = first; g < next && g < glyphs; g++) {
            select[g] = fd;
          }
          at += 3;
        }
        return (select, at + 2);
      default:
        throw const _Unsupported();
    }
  }

  /// The INDEX at [at] and where it ends.
  (_Index, int) _index(int at) {
    final count = _data[at] << 8 | _data[at + 1];
    if (count == 0) return (<Uint8List>[], at + 2);
    final offSize = _data[at + 2];
    int offset(int i) {
      var value = 0;
      for (var k = 0; k < offSize; k++) {
        value = value << 8 | _data[at + 3 + i * offSize + k];
      }
      return value;
    }

    final base = at + 3 + (count + 1) * offSize - 1;
    return (
      [
        for (var i = 0; i < count; i++)
          Uint8List.sublistView(_data, base + offset(i), base + offset(i + 1)),
      ],
      base + offset(count),
    );
  }

  static int _int(_Dict dict, int key, [int? fallback]) {
    final value = dict[key]?.firstOrNull;
    if (value == null) {
      if (fallback != null) return fallback;
      throw const _Unsupported();
    }
    return value.toInt();
  }

  /// The DICT in [bytes].
  static _Dict _dict(Uint8List bytes) {
    final dict = <int, List<num>>{};
    var operands = <num>[];
    var at = 0;
    while (at < bytes.length) {
      final b0 = bytes[at];
      if (b0 <= 21) {
        var key = b0;
        at++;
        if (b0 == 12) key = 1200 + bytes[at++];
        dict[key] = operands;
        operands = <num>[];
      } else if (b0 == 28) {
        operands.add(_signed16(bytes[at + 1] << 8 | bytes[at + 2]));
        at += 3;
      } else if (b0 == 29) {
        operands.add(ByteData.sublistView(bytes, at + 1, at + 5).getInt32(0));
        at += 5;
      } else if (b0 == 30) {
        final (value, end) = _real(bytes, at + 1);
        operands.add(value);
        at = end;
      } else if (b0 >= 32 && b0 <= 246) {
        operands.add(b0 - 139);
        at++;
      } else if (b0 >= 247 && b0 <= 250) {
        operands.add((b0 - 247) * 256 + bytes[at + 1] + 108);
        at += 2;
      } else if (b0 >= 251 && b0 <= 254) {
        operands.add(-(b0 - 251) * 256 - bytes[at + 1] - 108);
        at += 2;
      } else {
        throw const _Unsupported();
      }
    }
    return dict;
  }

  static (num, int) _real(Uint8List bytes, int start) {
    final text = StringBuffer();
    var at = start;
    outer:
    while (true) {
      final byte = bytes[at++];
      for (final nibble in [byte >> 4, byte & 0xf]) {
        switch (nibble) {
          case <= 9:
            text.write(nibble);
          case 0xa:
            text.write('.');
          case 0xb:
            text.write('E');
          case 0xc:
            text.write('E-');
          case 0xe:
            text.write('-');
          case 0xf:
            break outer;
        }
      }
    }
    return (num.tryParse(text.toString()) ?? 0, at);
  }

  static int _signed16(int value) => value >= 0x8000 ? value - 0x10000 : value;

  /// [dict] as DICT data: integers that are offsets (and every other
  /// integer) in the 5-byte form, reals as reals.
  static Uint8List _writeDict(_Dict dict) {
    final out = BytesBuilder(copy: false);
    final keys = dict.keys.toList()
      // ROS must come first in a CID font's Top DICT; SyntheticBase too.
      ..sort((a, b) => a == 1230 ? -1 : (b == 1230 ? 1 : 0));
    for (final key in keys) {
      for (final operand in dict[key]!) {
        if (operand is int ||
            (operand is double && operand == operand.roundToDouble())) {
          final value = operand.toInt();
          out
            ..addByte(29)
            ..add((ByteData(4)..setInt32(0, value)).buffer.asUint8List());
        } else {
          out
            ..addByte(30)
            ..add(_encodeReal(operand.toDouble()));
        }
      }
      if (key >= 1200) {
        out
          ..addByte(12)
          ..addByte(key - 1200);
      } else {
        out.addByte(key);
      }
    }
    return out.takeBytes();
  }

  static List<int> _encodeReal(double value) {
    final text = value.toString().replaceAll('e', 'E');
    final nibbles = <int>[];
    for (var i = 0; i < text.length; i++) {
      final char = text[i];
      if (char == 'E' && i + 1 < text.length && text[i + 1] == '-') {
        nibbles.add(0xc);
        i++;
      } else if (char == 'E') {
        nibbles.add(0xb);
      } else if (char == '.') {
        nibbles.add(0xa);
      } else if (char == '-') {
        nibbles.add(0xe);
      } else if (char == '+') {
        continue;
      } else {
        nibbles.add(int.parse(char));
      }
    }
    nibbles.add(0xf);
    if (nibbles.length.isOdd) nibbles.add(0xf);
    return [
      for (var i = 0; i < nibbles.length; i += 2)
        nibbles[i] << 4 | nibbles[i + 1],
    ];
  }

  static Uint8List _writeIndex(List<Uint8List> items) {
    if (items.isEmpty) return Uint8List.fromList([0, 0]);
    final total = items.fold<int>(0, (sum, item) => sum + item.length) + 1;
    final offSize = total <= 0xff
        ? 1
        : total <= 0xffff
        ? 2
        : total <= 0xffffff
        ? 3
        : 4;
    final out = BytesBuilder(copy: false)
      ..addByte(items.length >> 8)
      ..addByte(items.length & 0xff)
      ..addByte(offSize);
    var offset = 1;
    void writeOffset(int value) {
      for (var k = offSize - 1; k >= 0; k--) {
        out.addByte((value >> (8 * k)) & 0xff);
      }
    }

    writeOffset(offset);
    for (final item in items) {
      offset += item.length;
      writeOffset(offset);
    }
    items.forEach(out.add);
    return out.takeBytes();
  }
}

/// Runs a Type 2 charstring far enough to find the subroutines it calls
/// (their operands, the stems before a hint mask).
final class _Charstring {
  new(this._global, this._local, this._usedGlobal, this._usedLocal);

  final List<Uint8List> _global;
  final List<Uint8List> _local;
  final Set<int> _usedGlobal;
  final Set<int> _usedLocal;

  final List<num> _stack = [];
  int _stems = 0;
  bool _hintsDone = false;
  int _depth = 0;

  static int _bias(int count) => count < 1240
      ? 107
      : count < 33900
      ? 1131
      : 32768;

  void run(Uint8List code) {
    if (++_depth > 10) throw const _Unsupported();
    var at = 0;
    while (at < code.length) {
      final b0 = code[at];
      if (b0 >= 32 || b0 == 28) {
        if (b0 == 28) {
          _stack.add(_Cff._signed16(code[at + 1] << 8 | code[at + 2]));
          at += 3;
        } else if (b0 <= 246) {
          _stack.add(b0 - 139);
          at++;
        } else if (b0 <= 250) {
          _stack.add((b0 - 247) * 256 + code[at + 1] + 108);
          at += 2;
        } else if (b0 <= 254) {
          _stack.add(-(b0 - 251) * 256 - code[at + 1] - 108);
          at += 2;
        } else {
          // 16.16 fixed.
          _stack.add(
            ByteData.sublistView(code, at + 1, at + 5).getInt32(0) / 65536,
          );
          at += 5;
        }
        continue;
      }
      at++;
      switch (b0) {
        case 1 || 3 || 18 || 23: // hstem, vstem, hstemhm, vstemhm
          _stems += _stack.length ~/ 2;
          _stack.clear();
        case 19 || 20: // hintmask, cntrmask
          if (!_hintsDone) {
            // Implicit vstem before the first mask.
            _stems += _stack.length ~/ 2;
            _hintsDone = true;
          }
          _stack.clear();
          at += (_stems + 7) ~/ 8;
        case 10: // callsubr
          final index = _stack.removeLast().toInt() + _bias(_local.length);
          if (index < 0 || index >= _local.length) throw const _Unsupported();
          _usedLocal.add(index);
          run(_local[index]);
        case 29: // callgsubr
          final index = _stack.removeLast().toInt() + _bias(_global.length);
          if (index < 0 || index >= _global.length) throw const _Unsupported();
          _usedGlobal.add(index);
          run(_global[index]);
        case 11: // return
          _depth--;
          return;
        case 14: // endchar
          // With four or more arguments it's a `seac` accent, which refers
          // to other glyphs by standard encoding.
          if (_stack.length >= 4) throw const _Unsupported();
          _depth--;
          return;
        case 12:
          at++;
          _stack.clear();
        default:
          _stack.clear();
      }
    }
    _depth--;
  }
}

/// Reading PDF files (ISO 32000-2, 7.5): the objects of a file by
/// reference, through its cross-reference tables or streams (or, when
/// those are broken, by scanning the file), and its pages, which can be
/// imported into another document as form XObjects.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:libpdf/src/drawing/canvas.dart';
import 'package:libpdf/src/drawing/geometry.dart';
import 'package:libpdf/src/drawing/graphic.dart';
import 'package:libpdf/src/objects.dart';
import 'package:libpdf/src/reader/filters.dart';
import 'package:libpdf/src/writer.dart';
import 'package:meta/meta.dart';

/// A file that isn't a PDF file libpdf can read.
final class PdfFormatException implements Exception {
  /// An exception reporting [message].
  const new(this.message);

  /// What is wrong.
  final String message;

  @override
  String toString() => 'PdfFormatException: $message';
}

/// A PDF file, read: its objects and its pages.
final class PdfFile {
  new _(this._bytes);

  /// The PDF file in [bytes].
  ///
  /// Throws a [PdfFormatException] when it isn't a PDF file, or is
  /// encrypted.
  factory parse(Uint8List bytes) {
    final file = PdfFile._(bytes);
    if (_indexOf(bytes, _pdfHeader, 0, 1024) < 0) {
      throw const PdfFormatException('not a PDF file');
    }
    try {
      file._readCrossReferences();
    } on PdfFormatException {
      file._scan();
    }
    if (file._trailer['Root'] == null) file._scan();
    if (file._trailer['Encrypt'] != null) {
      throw const PdfFormatException('encrypted PDF files are not supported');
    }
    file._pages = file._readPages();
    return file;
  }

  final Uint8List _bytes;
  final Map<int, _Entry> _entries = {};
  PdfDict _trailer = PdfDict();
  final Map<int, PdfObject> _objects = {};
  final Set<int> _resolving = {};
  late final List<ImportedPage> _pages;

  /// The trailer dictionary (of the last cross-reference section).
  PdfDict get trailer => _trailer;

  /// The pages, in order.
  List<ImportedPage> get pages => List.unmodifiable(_pages);

  /// The indirect object [number], or [PdfNull] when there is none.
  PdfObject object(int number) {
    if (_objects[number] case final object?) return object;
    if (!_resolving.add(number)) return const PdfNull();
    try {
      final object = switch (_entries[number]) {
        _InFile(:final offset) => _readIndirect(offset, number),
        _InStream(:final stream, :final index) => _readCompressed(
          stream,
          index,
          number,
        ),
        null => const PdfNull(),
      };
      return _objects[number] = object;
    } on PdfFormatException {
      return _objects[number] = const PdfNull();
    } finally {
      _resolving.remove(number);
    }
  }

  /// [object], with a reference followed to the object it refers to.
  PdfObject? resolve(PdfObject? object) =>
      object is PdfRef ? this.object(object.number) : object;

  /// The decoded data of [stream].
  Uint8List decode(PdfStream stream) => decodeStream(stream, resolve);

  // Cross-reference sections.

  void _readCrossReferences() {
    final at = _lastIndexOf(_bytes, _startxref);
    if (at < 0) throw const PdfFormatException('no startxref');
    final lexer = _Lexer(_bytes, at + _startxref.length);
    var offset = lexer.integer();
    final seen = <int>{};
    var first = true;
    while (offset != null && seen.add(offset)) {
      final trailer = _readSection(offset);
      if (first) {
        _trailer = trailer;
        first = false;
      }
      if (_int(trailer['XRefStm']) case final stream?) _readSection(stream);
      offset = _int(trailer['Prev']);
    }
  }

  /// Reads the cross-reference section at [offset] (entries already read,
  /// from later sections, win); returns its trailer.
  PdfDict _readSection(int offset) {
    final lexer = _Lexer(_bytes, offset);
    if (lexer.keyword('xref')) {
      while (true) {
        final start = lexer.integer();
        if (start == null) break;
        final count = lexer.integer() ?? 0;
        for (var i = 0; i < count; i++) {
          final position = lexer.integer();
          if (position == null) {
            throw const PdfFormatException('bad cross-reference entry');
          }
          lexer.integer();
          final kind = lexer.word();
          if (kind == 'n' && position > 0) {
            _entries.putIfAbsent(start + i, () => _InFile(position));
          } else if (kind != 'n' && kind != 'f') {
            throw const PdfFormatException('bad cross-reference entry');
          }
        }
      }
      if (!lexer.keyword('trailer')) {
        throw const PdfFormatException('no trailer');
      }
      return switch (lexer.object()) {
        final PdfDict dict => dict,
        _ => throw const PdfFormatException('bad trailer'),
      };
    }
    // A cross-reference stream.
    lexer
      ..integer()
      ..integer();
    if (!lexer.keyword('obj')) {
      throw const PdfFormatException('no cross-reference section');
    }
    final stream = switch (lexer.object(this)) {
      final PdfStream stream => stream,
      _ => throw const PdfFormatException('bad cross-reference stream'),
    };
    final dict = stream.dict;
    final widths = switch (resolve(dict['W'])) {
      PdfArray(:final items) when items.length == 3 => [
        for (final item in items) _int(item) ?? 0,
      ],
      _ => throw const PdfFormatException('bad cross-reference stream'),
    };
    final size = _int(dict['Size']) ?? 0;
    final index = switch (resolve(dict['Index'])) {
      PdfArray(:final items) => [for (final item in items) _int(item) ?? 0],
      _ => [0, size],
    };
    final data = decode(stream);
    final rowLength = widths.fold<int>(0, (sum, w) => sum + w);
    var at = 0;
    int field(int i) {
      var value = 0;
      for (var k = 0; k < widths[i]; k++) {
        value = value << 8 | data[at++];
      }
      return value;
    }

    for (var s = 0; s + 1 < index.length; s += 2) {
      for (var i = 0; i < index[s + 1]; i++) {
        if (at + rowLength > data.length) break;
        final type = widths[0] == 0 ? 1 : field(0);
        final second = field(1);
        final third = field(2);
        final number = index[s] + i;
        switch (type) {
          case 1 when second > 0:
            _entries.putIfAbsent(number, () => _InFile(second));
          case 2:
            _entries.putIfAbsent(number, () => _InStream(second, third));
        }
      }
    }
    return PdfDict({...dict.entries}..remove('Length'));
  }

  /// Rebuilds the cross-reference entries by finding each `N G obj` in
  /// the file, and the trailer from its trailers (or the catalog).
  void _scan() {
    _entries.clear();
    _objects.clear();
    final pattern = RegExp(
      r'(?<![0-9])(\d+)[ \t\r\n\f\x00]+\d+[ \t\r\n\f\x00]+obj\b',
    );
    final text = latin1.decode(_bytes);
    for (final match in pattern.allMatches(text)) {
      _entries[int.parse(match[1]!)] = _InFile(match.start);
    }
    final trailer = PdfDict();
    for (final match in RegExp(r'trailer\s*<<').allMatches(text)) {
      if (_Lexer(_bytes, match.start + 7).object() case final PdfDict dict) {
        trailer.entries.addAll(dict.entries);
      }
    }
    _trailer = trailer;
    if (trailer['Root'] != null) return;
    // Object streams and cross-reference streams: read their entries.
    for (final number in [..._entries.keys]) {
      if (object(number) case PdfStream(:final dict)) {
        if (dict['Type'] case PdfName(value: 'XRef')) {
          trailer.entries.addAll({...dict.entries}..remove('Length'));
        }
      }
    }
    if (trailer['Root'] != null) return;
    for (final number in _entries.keys) {
      if (object(number) case PdfDict(
        entries: {'Type': PdfName(value: 'Catalog')},
      )) {
        trailer['Root'] = PdfRef(number);
        return;
      }
    }
    throw const PdfFormatException('no document catalog');
  }

  PdfObject _readIndirect(int offset, int number) {
    final lexer = _Lexer(_bytes, offset);
    final found = lexer.integer();
    lexer.integer();
    if (found != number || !lexer.keyword('obj')) {
      throw PdfFormatException('object $number not found');
    }
    return lexer.object(this);
  }

  PdfObject _readCompressed(int streamNumber, int index, int number) {
    final stream = switch (object(streamNumber)) {
      final PdfStream stream => stream,
      _ => throw PdfFormatException('object stream $streamNumber not found'),
    };
    final data = decode(stream);
    final count = _int(stream.dict['N']) ?? 0;
    final first = _int(stream.dict['First']) ?? 0;
    final header = _Lexer(data, 0);
    for (var i = 0; i < count; i++) {
      final found = header.integer();
      final offset = header.integer();
      if (found == null || offset == null) break;
      if (found == number) {
        return _Lexer(data, first + offset).object(this);
      }
    }
    throw PdfFormatException('object $number not found');
  }

  int? _int(PdfObject? object) => switch (resolve(object)) {
    PdfInt(:final value) => value,
    PdfReal(:final value) => value.toInt(),
    _ => null,
  };

  // Pages.

  List<ImportedPage> _readPages() {
    final pages = <ImportedPage>[];
    final visited = <PdfObject>{};
    void walk(PdfObject? node, Map<String, PdfObject> inherited) {
      final dict = resolve(node);
      if (dict is! PdfDict || !visited.add(dict)) return;
      final attributes = {
        ...inherited,
        for (final key in const ['Resources', 'MediaBox', 'CropBox', 'Rotate'])
          key: ?dict[key],
      };
      if (resolve(dict['Kids']) case PdfArray(:final items)) {
        for (final kid in items) {
          walk(kid, attributes);
        }
      } else {
        pages.add(ImportedPage._(this, dict, attributes));
      }
    }

    final catalog = resolve(_trailer['Root']);
    if (catalog is! PdfDict) {
      throw const PdfFormatException('no document catalog');
    }
    walk(catalog['Pages'], const {});
    return pages;
  }

  static final List<int> _pdfHeader = ascii.encode('%PDF-');
  static final List<int> _startxref = ascii.encode('startxref');
}

sealed class _Entry {
  const new();
}

final class _InFile extends _Entry {
  const new(this.offset);
  final int offset;
}

final class _InStream extends _Entry {
  const new(this.stream, this.index);
  final int stream;
  final int index;
}

/// A page of a [PdfFile], to paint into another document (as a form
/// XObject of its content and resources).
final class ImportedPage implements Graphic {
  new _(this.file, this._dict, Map<String, PdfObject> attributes)
    : _resources = attributes['Resources'],
      box = _box(file, attributes),
      rotation = switch (file.resolve(attributes['Rotate'])) {
        PdfInt(:final value) => (value % 360 + 360) % 360 ~/ 90 * 90,
        _ => 0,
      };

  /// The file the page is in.
  final PdfFile file;

  final PdfDict _dict;
  final PdfObject? _resources;

  /// The visible region of the page: its crop box (within its media box).
  final PdfRect box;

  /// The page's rotation when displayed, clockwise: 0, 90, 180 or 270.
  final int rotation;

  static PdfRect _box(PdfFile file, Map<String, PdfObject> attributes) {
    PdfRect? rect(PdfObject? object) {
      if (file.resolve(object) case PdfArray(:final items)
          when items.length == 4) {
        final values = [
          for (final item in items)
            switch (file.resolve(item)) {
              PdfInt(:final value) => value.toDouble(),
              PdfReal(:final value) => value,
              _ => 0.0,
            },
        ];
        final left = values[0] < values[2] ? values[0] : values[2];
        final right = values[0] < values[2] ? values[2] : values[0];
        final bottom = values[1] < values[3] ? values[1] : values[3];
        final top = values[1] < values[3] ? values[3] : values[1];
        return PdfRect(left, bottom, right - left, top - bottom);
      }
      return null;
    }

    final media = rect(attributes['MediaBox']) ?? const PdfRect(0, 0, 612, 792);
    final crop = rect(attributes['CropBox']);
    if (crop == null) return media;
    final left = crop.left > media.left ? crop.left : media.left;
    final bottom = crop.bottom > media.bottom ? crop.bottom : media.bottom;
    final right = crop.right < media.right ? crop.right : media.right;
    final top = crop.top < media.top ? crop.top : media.top;
    if (right <= left || top <= bottom) return media;
    return PdfRect(left, bottom, right - left, top - bottom);
  }

  /// The width as displayed, in points.
  @override
  double get intrinsicWidth => rotation % 180 == 0 ? box.width : box.height;

  /// The height as displayed, in points.
  @override
  double get intrinsicHeight => rotation % 180 == 0 ? box.height : box.width;

  @override
  void paint(PdfCanvas canvas, PdfRect rect) => canvas.page(this, rect);

  /// The transformation from the page's space to [rect], where the page
  /// is displayed.
  @internal
  PdfMatrix placement(PdfRect rect) {
    final b = box;
    // Page space to displayed space (the box's lower left at the origin).
    final (a, bb, c, d, e, f) = switch (rotation) {
      90 => (0.0, -1.0, 1.0, 0.0, -b.bottom, b.right),
      180 => (-1.0, 0.0, 0.0, -1.0, b.right, b.top),
      270 => (0.0, 1.0, -1.0, 0.0, b.top, -b.left),
      _ => (1.0, 0.0, 0.0, 1.0, -b.left, -b.bottom),
    };
    final sx = rect.width / intrinsicWidth;
    final sy = rect.height / intrinsicHeight;
    return PdfMatrix(
      a * sx,
      bb * sy,
      c * sx,
      d * sy,
      e * sx + rect.left,
      f * sy + rect.bottom,
    );
  }

  /// The page's content, decoded and joined.
  @internal
  Uint8List get content {
    final out = BytesBuilder(copy: false);
    final contents = switch (file.resolve(_dict['Contents'])) {
      final PdfStream stream => [stream],
      PdfArray(:final items) => [
        for (final item in items)
          if (file.resolve(item) case final PdfStream stream) stream,
      ],
      _ => const <PdfStream>[],
    };
    for (final stream in contents) {
      out
        ..add(file.decode(stream))
        ..addByte(0x0a);
    }
    return out.takeBytes();
  }

  /// The page's resources dictionary (possibly a reference), if any.
  @internal
  PdfObject? get resources => _resources;

  /// The page's transparency group, if any.
  @internal
  PdfObject? get group => _dict['Group'];
}

/// Copies objects of [PdfFile]s into a [PdfWriter]: each object once,
/// under a new number, with the references among them renumbered.
@internal
final class ObjectCopier {
  /// A copier into [writer].
  new(this.writer);

  /// The writer the objects are written to.
  final PdfWriter writer;

  final Map<(PdfFile, int), PdfRef> _refs = {};
  final List<(PdfFile, int, PdfRef)> _queue = [];

  /// [object] of [file], with the objects it refers to queued to copy.
  PdfObject copy(PdfFile file, PdfObject? object) => switch (object) {
    null => const PdfNull(),
    PdfRef(:final number) => _ref(file, number),
    PdfDict(:final entries) => PdfDict({
      for (final MapEntry(:key, :value) in entries.entries)
        key: copy(file, value),
    }),
    PdfArray(:final items) => PdfArray([
      for (final item in items) copy(file, item),
    ]),
    PdfStream(:final dict, :final data) => PdfStream(
      data,
      dict: PdfDict({
        for (final MapEntry(:key, :value) in dict.entries.entries)
          if (key != 'Length') key: copy(file, value),
      }),
    ),
    _ => object,
  };

  PdfObject _ref(PdfFile file, int number) {
    if (_refs[(file, number)] case final ref?) return ref;
    // Pages and the page tree aren't copied: a resource that refers to
    // them refers to nothing.
    if (file.object(number) case PdfDict(
      entries: {'Type': PdfName(value: 'Page' || 'Pages' || 'Catalog')},
    )) {
      return const PdfNull();
    }
    final ref = _refs[(file, number)] = writer.reserve();
    _queue.add((file, number, ref));
    return ref;
  }

  /// Writes the objects queued to copy.
  void flush() {
    while (_queue.isNotEmpty) {
      final (file, number, ref) = _queue.removeAt(0);
      writer.write(copy(file, file.object(number)), ref);
    }
  }
}

/// The index of [pattern] in [bytes] from [start], within [limit] bytes,
/// or -1.
int _indexOf(Uint8List bytes, List<int> pattern, int start, [int? limit]) {
  final end = limit == null
      ? bytes.length - pattern.length
      : (start + limit).clamp(0, bytes.length - pattern.length);
  outer:
  for (var i = start; i <= end; i++) {
    for (var k = 0; k < pattern.length; k++) {
      if (bytes[i + k] != pattern[k]) continue outer;
    }
    return i;
  }
  return -1;
}

/// The index of the last [pattern] in [bytes], or -1.
int _lastIndexOf(Uint8List bytes, List<int> pattern) {
  outer:
  for (var i = bytes.length - pattern.length; i >= 0; i--) {
    for (var k = 0; k < pattern.length; k++) {
      if (bytes[i + k] != pattern[k]) continue outer;
    }
    return i;
  }
  return -1;
}

bool _isSpace(int byte) =>
    byte == 0x20 ||
    byte == 0x0a ||
    byte == 0x0d ||
    byte == 0x09 ||
    byte == 0x0c ||
    byte == 0x00;

bool _isDelimiter(int byte) =>
    byte == 0x28 ||
    byte == 0x29 ||
    byte == 0x3c ||
    byte == 0x3e ||
    byte == 0x5b ||
    byte == 0x5d ||
    byte == 0x7b ||
    byte == 0x7d ||
    byte == 0x2f ||
    byte == 0x25;

bool _isRegular(int byte) => !_isSpace(byte) && !_isDelimiter(byte);

/// Reads PDF syntax (ISO 32000-2, 7.2–7.3) from [_bytes].
final class _Lexer {
  new(this._bytes, this._at);

  final Uint8List _bytes;
  int _at;

  bool get _done => _at >= _bytes.length;

  int get _byte => _bytes[_at];

  void _skipSpace() {
    while (!_done) {
      if (_isSpace(_byte)) {
        _at++;
      } else if (_byte == 0x25) {
        while (!_done && _byte != 0x0a && _byte != 0x0d) {
          _at++;
        }
      } else {
        return;
      }
    }
  }

  /// The next word (regular characters), consumed.
  String word() {
    _skipSpace();
    // A damaged file may have taken the position past its end.
    if (_at > _bytes.length) _at = _bytes.length;
    final start = _at;
    while (!_done && _isRegular(_byte)) {
      _at++;
    }
    return latin1.decode(Uint8List.sublistView(_bytes, start, _at));
  }

  /// Consumes the keyword [word] if it's next; returns whether it was.
  bool keyword(String word) {
    final at = _at;
    if (this.word() == word) return true;
    _at = at;
    return false;
  }

  /// The next integer, consumed, or null (consuming nothing).
  int? integer() {
    final at = _at;
    final value = int.tryParse(word());
    if (value == null) _at = at;
    return value;
  }

  /// The next object; a stream's `/Length` is resolved through [file].
  PdfObject object([PdfFile? file]) {
    _skipSpace();
    if (_done) throw const PdfFormatException('unexpected end of file');
    switch (_byte) {
      case 0x2f:
        _at++;
        return PdfName(_name());
      case 0x28:
        _at++;
        return PdfString(_literal());
      case 0x3c when _at + 1 < _bytes.length && _bytes[_at + 1] == 0x3c:
        _at += 2;
        final dict = PdfDict();
        while (true) {
          _skipSpace();
          if (_done) throw const PdfFormatException('unterminated dictionary');
          if (_byte == 0x3e) {
            _at += 2;
            break;
          }
          final key = object();
          if (key is! PdfName) {
            throw const PdfFormatException('dictionary key is not a name');
          }
          final value = object(file);
          if (value is! PdfNull) dict[key.value] = value;
        }
        return _streamAfter(dict, file) ?? dict;
      case 0x3c:
        _at++;
        return PdfString(_hex(), hex: true);
      case 0x5b:
        _at++;
        final items = <PdfObject>[];
        while (true) {
          _skipSpace();
          if (_done) throw const PdfFormatException('unterminated array');
          if (_byte == 0x5d) {
            _at++;
            break;
          }
          items.add(object(file));
        }
        return PdfArray(items);
    }
    final start = _at;
    final token = word();
    if (token.isEmpty) {
      _at++;
      throw PdfFormatException('unexpected character at byte $start');
    }
    switch (token) {
      case 'true':
        return const PdfBool(true);
      case 'false':
        return const PdfBool(false);
      case 'null':
        return const PdfNull();
    }
    if (int.tryParse(token) case final number?) {
      // `N G R`: a reference.
      final after = _at;
      final generation = integer();
      if (generation != null && keyword('R')) {
        return PdfRef(number, generation);
      }
      _at = after;
      return PdfInt(number);
    }
    if (double.tryParse(token) case final value?) return PdfReal(value);
    if (RegExp(r'^[+-]?\.?$').hasMatch(token)) return const PdfInt(0);
    throw PdfFormatException('unexpected "$token" at byte $start');
  }

  /// The stream whose dictionary is [dict], if `stream` follows.
  PdfStream? _streamAfter(PdfDict dict, PdfFile? file) {
    final at = _at;
    if (!keyword('stream')) {
      _at = at;
      return null;
    }
    if (!_done && _byte == 0x0d) _at++;
    if (!_done && _byte == 0x0a) _at++;
    final start = _at;
    final length = switch (file?.resolve(dict['Length']) ?? dict['Length']) {
      PdfInt(:final value) => value,
      _ => null,
    };
    int end;
    if (length != null &&
        start + length <= _bytes.length &&
        _endstreamAt(start + length)) {
      end = start + length;
    } else {
      end = _indexOf(_bytes, _endstream, start);
      if (end < 0) throw const PdfFormatException('unterminated stream');
      // The end of line before `endstream` isn't data.
      if (end > start && _bytes[end - 1] == 0x0a) end--;
      if (end > start && _bytes[end - 1] == 0x0d) end--;
    }
    final data = Uint8List.fromList(Uint8List.sublistView(_bytes, start, end));
    _at = end;
    keyword('endstream');
    return PdfStream(data, dict: PdfDict({...dict.entries}..remove('Length')));
  }

  bool _endstreamAt(int at) {
    var i = at;
    while (i < _bytes.length && _isSpace(_bytes[i])) {
      i++;
    }
    return _indexOf(_bytes, _endstream, i, 0) == i;
  }

  String _name() {
    final bytes = <int>[];
    while (!_done && _isRegular(_byte)) {
      if (_byte == 0x23 && _at + 2 < _bytes.length) {
        final high = _hexDigit(_bytes[_at + 1]);
        final low = _hexDigit(_bytes[_at + 2]);
        if (high != null && low != null) {
          bytes.add(high << 4 | low);
          _at += 3;
          continue;
        }
      }
      bytes.add(_byte);
      _at++;
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  List<int> _literal() {
    final bytes = <int>[];
    var depth = 1;
    while (!_done) {
      final byte = _bytes[_at++];
      switch (byte) {
        case 0x28:
          depth++;
          bytes.add(byte);
        case 0x29:
          if (--depth == 0) return bytes;
          bytes.add(byte);
        case 0x0d:
          // An end of line is a line feed.
          if (!_done && _byte == 0x0a) _at++;
          bytes.add(0x0a);
        case 0x5c when !_done:
          final escaped = _bytes[_at++];
          switch (escaped) {
            case 0x6e:
              bytes.add(0x0a);
            case 0x72:
              bytes.add(0x0d);
            case 0x74:
              bytes.add(0x09);
            case 0x62:
              bytes.add(0x08);
            case 0x66:
              bytes.add(0x0c);
            case 0x0d:
              if (!_done && _byte == 0x0a) _at++;
            case 0x0a:
              break;
            case >= 0x30 && <= 0x37:
              var value = escaped - 0x30;
              for (var k = 0; k < 2 && !_done; k++) {
                if (_byte < 0x30 || _byte > 0x37) break;
                value = value * 8 + _bytes[_at++] - 0x30;
              }
              bytes.add(value & 0xff);
            default:
              bytes.add(escaped);
          }
        default:
          bytes.add(byte);
      }
    }
    throw const PdfFormatException('unterminated string');
  }

  List<int> _hex() {
    final digits = <int>[];
    while (!_done && _byte != 0x3e) {
      if (_hexDigit(_byte) case final value?) digits.add(value);
      _at++;
    }
    _at++;
    if (digits.length.isOdd) digits.add(0);
    return [
      for (var i = 0; i < digits.length; i += 2) digits[i] << 4 | digits[i + 1],
    ];
  }

  static int? _hexDigit(int byte) => switch (byte) {
    >= 0x30 && <= 0x39 => byte - 0x30,
    >= 0x41 && <= 0x46 => byte - 0x37,
    >= 0x61 && <= 0x66 => byte - 0x57,
    _ => null,
  };

  static final List<int> _endstream = ascii.encode('endstream');
}

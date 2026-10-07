// Brotli streams and WOFF/WOFF2 fonts, checked against what the reference
// tools make of them: fixtures (made as test/fonts/README.md says), and,
// where brotli and woff2_compress/woff2_decompress are installed, round
// trips of every test font and of random data through them.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:libpdf/libpdf.dart';
import 'package:test/test.dart';

bool _has(String tool) =>
    Process.runSync('which', [tool]).exitCode == 0 ||
    Process.runSync('where', [tool], runInShell: true).exitCode == 0;

/// The tables of the font [bytes], by tag.
Map<String, Uint8List> _tables(Uint8List bytes) {
  final view = ByteData.sublistView(bytes);
  return {
    for (var i = 0; i < view.getUint16(4); i++)
      latin1.decode(
        bytes.sublist(12 + 16 * i, 16 + 16 * i),
      ): Uint8List.sublistView(
        bytes,
        view.getUint32(20 + 16 * i),
        view.getUint32(20 + 16 * i) + view.getUint32(24 + 16 * i),
      ),
  };
}

/// [head] without its checksum adjustment, which depends on the layout of
/// the whole file, and the flag a WOFF2 encoder sets (bit 11: the font was
/// transformed losslessly).
List<int> _head(Uint8List head) => [...head]
  ..fillRange(8, 12, 0)
  ..[16] &= ~0x08;

String _hex(List<int> bytes) =>
    [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')].join();

/// Expects the font [got] to have [want]'s tables, but for those named in
/// [except], and the head table's checksum adjustment.
void _expectTables(
  Uint8List got,
  Uint8List want, {
  Set<String> except = const {},
}) {
  final a = _tables(got);
  final b = _tables(want);
  expect(a.keys.toSet(), b.keys.toSet());
  for (final tag in b.keys) {
    if (except.contains(tag)) continue;
    expect(
      tag == 'head' ? _head(a[tag]!) : a[tag],
      tag == 'head' ? _head(b[tag]!) : b[tag],
      reason: tag,
    );
  }
}

/// Expects the sum of [font]'s words to be the one OpenType requires.
void _expectChecksum(Uint8List font) {
  final view = ByteData.sublistView(font);
  var sum = 0;
  for (var i = 0; i < font.length; i += 4) {
    sum = (sum + view.getUint32(i)) & 0xffffffff;
  }
  expect(sum, 0xb1b0afba);
}

Uint8List _read(String path) => File(path).readAsBytesSync();

void main() {
  group('Brotli', () {
    final words = _read('test/brotli/words.txt');
    test('static dictionary words and their transforms', () {
      expect(brotliDecode(_read('test/brotli/words.txt.br')), words);
    });

    test('a small window, and a fast quality', () {
      final repeated = [for (var i = 0; i < 40; i++) ...words];
      expect(brotliDecode(_read('test/brotli/words-x40-w10.br')), repeated);
      expect(brotliDecode(_read('test/brotli/words-x40-q1.br')), repeated);
    });

    test('empty and one-byte streams', () {
      expect(brotliDecode([0x3f]), isEmpty);
      expect(brotliDecode([0x0f, 0x00, 0x80, 0x78, 0x03]), [0x78]);
    });

    test('malformed streams throw FormatExceptions', () {
      final stream = _read('test/brotli/words.txt.br');
      expect(
        () => brotliDecode(stream.sublist(0, stream.length ~/ 2)),
        throwsFormatException,
      );
      final random = Random(1);
      for (var i = 0; i < 300; i++) {
        final bytes = [...stream];
        bytes[random.nextInt(bytes.length)] ^= 1 << random.nextInt(8);
        try {
          brotliDecode(bytes);
        } on FormatException {
          // Expected (unless the flip still makes a stream).
        }
      }
    });

    test(
      'decodes what the brotli tool makes, at every quality',
      () {
        final tmp = Directory.systemTemp.createTempSync('brotli_test.');
        addTearDown(() => tmp.deleteSync(recursive: true));
        final random = Random(2);
        final inputs = {
          'words': utf8.encode(
            [
              for (var i = 0; i < 3000; i++)
                const ['the', 'The', 'time', 'world', 'Hello', '"', '.'][random
                    .nextInt(7)],
            ].join(' '),
          ),
          'random': [for (var i = 0; i < 70000; i++) random.nextInt(256)],
          'font': _read('test/fonts/notoserif-regular-latin.ttf'),
        };
        for (final MapEntry(key: name, value: data) in inputs.entries) {
          final input = File('${tmp.path}/$name')..writeAsBytesSync(data);
          for (final (quality, window) in [
            (0, 16),
            (2, 10),
            (5, 18),
            (9, 22),
            (11, 24),
          ]) {
            final output = '${input.path}.$quality.br';
            final run = Process.runSync('brotli', [
              '-f',
              '-q',
              '$quality',
              '-w',
              '$window',
              '-o',
              output,
              input.path,
            ]);
            expect(run.exitCode, 0, reason: '${run.stderr}');
            expect(
              brotliDecode(_read(output)),
              data,
              reason: '$name at quality $quality',
            );
          }
        }
      },
      skip: _has('brotli') ? false : 'brotli is not installed',
      tags: ['pdf-tools'],
    );
  });

  group('WOFF', () {
    final original = _read('test/fonts/notoserif-features.ttf');

    test('recognizes web fonts', () {
      expect(isWebFont(_read('test/fonts/notoserif-features.woff')), isTrue);
      expect(isWebFont(_read('test/fonts/notoserif-features.woff2')), isTrue);
      expect(isWebFont(original), isFalse);
      expect(isWebFont([0x77]), isFalse);
    });

    test('WOFF: the font, table for table', () {
      final font = decodeWebFont(_read('test/fonts/notoserif-features.woff'));
      _expectTables(font, original);
      _expectChecksum(font);
    });

    test('WOFF2: the tables, glyf and loca as the reference rebuilds them', () {
      for (final name in [
        'notoserif-features.woff2',
        // With the hmtx table transformed too (by fontTools).
        'notoserif-features-hmtx.woff2',
      ]) {
        final font = decodeWebFont(_read('test/fonts/$name'));
        _expectTables(font, original, except: {'glyf', 'loca'});
        final tables = _tables(font);
        // What woff2_decompress makes of them.
        expect(_hex(md5(tables['glyf']!)), '50826e51c81f3e990040338be187aa78');
        expect(_hex(md5(tables['loca']!)), '3cb8921037db03f76bfb7e836b96653c');
        _expectChecksum(font);
      }
    });

    test('WOFF2 with CFF outlines', () {
      final font = decodeWebFont(_read('test/fonts/libertinus-smcp.woff2'));
      _expectTables(font, _read('test/fonts/libertinus-smcp.otf'));
      _expectChecksum(font);
    });

    test('OpenTypeFont and EmbeddedFont read web fonts', () {
      final woff2 = OpenTypeFont.parse(
        _read('test/fonts/notoserif-features.woff2'),
      );
      final ttf = OpenTypeFont.parse(original);
      expect(woff2.familyName, ttf.familyName);
      expect(woff2.numGlyphs, ttf.numGlyphs);
      expect(woff2.unitsPerEm, ttf.unitsPerEm);
      expect(
        EmbeddedFont.parse(_read('test/fonts/notoserif-features.woff')).name,
        EmbeddedFont.parse(original).name,
      );
    });

    test('malformed web fonts throw FontFormatExceptions', () {
      final woff2 = _read('test/fonts/notoserif-features.woff2');
      for (final bytes in [
        woff2.sublist(0, 30),
        woff2.sublist(0, woff2.length - 200),
        [...woff2]..fillRange(48, 60, 0xff),
        _read('test/fonts/notoserif-features.woff').sublist(0, 400),
      ]) {
        expect(() => decodeWebFont(bytes), throwsA(isA<FontFormatException>()));
      }
      expect(
        () => decodeWebFont(original),
        throwsA(isA<FontFormatException>()),
      );
    });

    test(
      'decodes what woff2_compress makes of each test font',
      () {
        final tmp = Directory.systemTemp.createTempSync('woff_test.');
        addTearDown(() => tmp.deleteSync(recursive: true));
        for (final file in Directory('test/fonts').listSync()) {
          if (!RegExp(r'\.(ttf|otf)$').hasMatch(file.path)) continue;
          final name = file.uri.pathSegments.last;
          final base = name.substring(0, name.length - 4);
          File(file.path).copySync('${tmp.path}/$name');
          final compress = Process.runSync('woff2_compress', [
            '${tmp.path}/$name',
          ]);
          expect(compress.exitCode, 0, reason: '${compress.stderr}');
          final woff2 = File('${tmp.path}/$base.woff2');
          final reference = woff2.copySync('${tmp.path}/ref-$base.woff2');
          final decompress = Process.runSync('woff2_decompress', [
            reference.path,
          ]);
          expect(decompress.exitCode, 0, reason: '${decompress.stderr}');
          final font = decodeWebFont(woff2.readAsBytesSync());
          _expectTables(font, _read('${tmp.path}/ref-$base.ttf'));
          _expectChecksum(font);
        }
      },
      skip: _has('woff2_compress') && _has('woff2_decompress')
          ? false
          : 'woff2_compress and woff2_decompress are not installed',
      tags: ['pdf-tools'],
    );
  });
}

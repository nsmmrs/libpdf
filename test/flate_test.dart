import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:libpdf/libpdf.dart';
import 'package:libpdf/src/flate.dart' show huffmanLengths;
import 'package:test/test.dart';

void main() {
  final random = Random(42);
  final samples = <String, List<int>>{
    'empty': const [],
    'one byte': [7],
    'text': utf8.encode('Hello, world! ' * 500),
    'random': List<int>.generate(70000, (_) => random.nextInt(256)),
    'runs': [
      for (var i = 0; i < 100000; i++)
        if (i % 7 == 0) random.nextInt(4) else 0,
    ],
    'binary-ish': List<int>.generate(200000, (i) => (i * i) % 251),
  };

  for (final MapEntry(key: name, value: data) in samples.entries) {
    test('deflate round-trips $name, and zlib reads it', () {
      for (final level in [0, 1, 6, 9]) {
        final compressed = deflate(data, level: level);
        expect(inflate(compressed), data, reason: 'level $level');
        expect(
          ZLibCodec(raw: true).decode(compressed),
          data,
          reason: 'zlib reads level $level',
        );
      }
      final z = zlibEncode(data);
      expect(zlibDecode(z), data);
      expect(ZLibCodec().decode(z), data);
    });

    test('inflate reads what zlib writes: $name', () {
      expect(inflate(ZLibCodec(raw: true, level: 9).encode(data)), data);
      expect(zlibDecode(ZLibCodec().encode(data)), data);
    });
  }

  test('Huffman codes deeper than the limit are shortened, complete', () {
    // Frequencies as the Fibonacci numbers: a tree 18 deep, for codes of
    // 7 bits at most (the code length alphabet's).
    final fib = [1, 1];
    while (fib.length < 19) {
      fib.add(fib[fib.length - 1] + fib[fib.length - 2]);
    }
    for (final maxBits in [7, 9, 15]) {
      final lengths = huffmanLengths(fib, maxBits);
      expect(lengths.every((l) => l >= 1 && l <= maxBits), isTrue);
      // Neither over-subscribed nor incomplete: inflaters reject both.
      final kraft = lengths.fold(0, (sum, l) => sum + (1 << (maxBits - l)));
      expect(kraft, 1 << maxBits, reason: 'at most $maxBits bits');
    }
  });

  test('compression is effective on text', () {
    final text = utf8.encode(File('LICENSE').readAsStringSync() * 20);
    final ours = zlibEncode(text);
    final theirs = ZLibCodec().encode(text);
    expect(ours.length, lessThan(theirs.length * 1.2));
  });

  test('the same input compresses to the same bytes', () {
    final data = utf8.encode('deterministic ' * 1000);
    expect(zlibEncode(data), zlibEncode(Uint8List.fromList(data)));
  });

  test('corrupt data is rejected', () {
    expect(() => zlibDecode([1, 2, 3, 4, 5, 6]), throwsFormatException);
    final z = zlibEncode(utf8.encode('abc'));
    z[z.length - 1] ^= 1;
    expect(() => zlibDecode(z), throwsFormatException);
  });

  test('adler32', () {
    expect(adler32(utf8.encode('Wikipedia')), 0x11E60398);
  });

  test('md5', () {
    String hex(List<int> b) =>
        [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();
    expect(hex(md5(const [])), 'd41d8cd98f00b204e9800998ecf8427e');
    expect(
      hex(md5(utf8.encode('The quick brown fox jumps over the lazy dog'))),
      '9e107d9d372bb6826bd81d3542a419d6',
    );
    expect(hex(md5(List<int>.filled(1000, 97))), isNotEmpty);
  });
}

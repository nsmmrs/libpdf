import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:libpdf/libpdf.dart';
import 'package:test/test.dart';

/// A page with each of [lines] in its font, at 14 points.
Uint8List textPdf(List<(PdfFont, String)> lines) {
  final out = BytesBuilder(copy: false);
  final writer = PdfWriter(
    out.add,
    options: const PdfWriterOptions(deterministic: true),
  );
  final catalog = writer.reserve();
  final pages = writer.reserve();
  final fonts = <PdfFont, String>{};
  final content = StringBuffer();
  var y = 750;
  for (final (font, text) in lines) {
    final key = fonts.putIfAbsent(font, () => 'F${fonts.length + 1}');
    final glyphs = font.shape(text, ligatures: true);
    final items = <String>[];
    for (final glyph in glyphs) {
      final bytes = font.encode([glyph]);
      final hex = [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')]
          .join();
      items.add('<$hex>');
      if (glyph.kerning != 0) items.add(formatNumber(-glyph.kerning));
    }
    content.write('BT /$key 14 Tf 50 $y Td [${items.join(' ')}] TJ ET\n');
    y -= 30;
  }
  final stream = writer.write(PdfStream(latin1.encode(content.toString())));
  final page = writer.write(
    PdfDict({
      'Type': const PdfName('Page'),
      'Parent': pages,
      'MediaBox': PdfArray.numbers([0, 0, 612, 792]),
      'Resources': PdfDict({
        'Font': PdfDict({
          for (final MapEntry(key: font, value: key) in fonts.entries)
            key: font.reference(writer),
        }),
      }),
      'Contents': stream,
    }),
  );
  for (final font in fonts.keys) {
    font.writeTo(writer);
  }
  writer
    ..write(
      PdfDict({
        'Type': const PdfName('Pages'),
        'Kids': PdfArray([page]),
        'Count': const PdfInt(1),
      }),
      pages,
    )
    ..write(
      PdfDict({'Type': const PdfName('Catalog'), 'Pages': pages}),
      catalog,
    )
    ..close(root: catalog);
  return out.takeBytes();
}

bool _has(String tool) => Process.runSync('which', [tool]).exitCode == 0;

final bool _tools = _has('qpdf') && _has('pdftotext') && _has('pdftoppm');

List<int> serif() =>
    File('test/fonts/notoserif-regular-latin.ttf').readAsBytesSync();
List<int> cff() => File('test/fonts/notoserif-cff.otf').readAsBytesSync();
List<int> cid() => File('test/fonts/notoserif-cid.otf').readAsBytesSync();
List<int> mplus() =>
    File('test/fonts/mplus1p-regular-multilingual.ttf').readAsBytesSync();

(String check, String text) inspect(Uint8List pdf) {
  final dir = Directory.systemTemp.createTempSync('libpdf.');
  try {
    final file = File('${dir.path}/t.pdf')..writeAsBytesSync(pdf);
    final check = Process.runSync('qpdf', ['--check', file.path]);
    final text = Process.runSync('pdftotext', [
      '-enc',
      'UTF-8',
      file.path,
      '-',
    ]);
    return ('${check.stdout}${check.stderr}', '${text.stdout}');
  } finally {
    dir.deleteSync(recursive: true);
  }
}

void main() {
  test('OpenType tables are read', () {
    final font = EmbeddedFont.parse(serif()).font;
    expect(font.unitsPerEm, anyOf(1000, 2048));
    expect(font.postScriptName, 'NotoSerif');
    expect(font.glyphFor(0x41), isNot(0));
    expect(font.isTrueType, isTrue);
    expect(font.ascender, greaterThan(0));
    expect(font.typoAscender, isNotNull);
    expect(font.typoDescender, lessThan(0));
  });

  test('kern table pairs, from all subtables or one', () {
    final font = EmbeddedFont.parse(
      File('test/fonts/notoserif-kern-subtables.ttf').readAsBytesSync(),
    ).font;
    int glyph(String char) => font.glyphFor(char.codeUnitAt(0));
    // A later subtable's pair wins; one subtable alone gives its own.
    expect(font.kernTablePair(glyph('A'), glyph('V')), -40);
    expect(font.kernTablePair(glyph('A'), glyph('V'), subtable: 0), -80);
    expect(font.kernTablePair(glyph('T'), glyph('o'), subtable: 0), isNull);
    expect(font.kernTablePair(glyph('T'), glyph('o'), subtable: 1), -60);
    expect(font.kernTablePair(glyph('T'), glyph('o'), subtable: 2), isNull);
  });

  test('text kerned by one kern subtable alone', () {
    final bytes = File('test/fonts/notoserif-kern-subtables.ttf')
        .readAsBytesSync();
    final first = EmbeddedFont.parse(bytes, kernTableSubtable: 0);
    final second = EmbeddedFont.parse(bytes, kernTableSubtable: 1);
    double kerning(EmbeddedFont font, String text) =>
        font.shape(text).first.kerning;
    final unit = 1000 / first.font.unitsPerEm;
    // (Without a subtable, the font's GPOS pairs kern instead.)
    expect(kerning(first, 'AV'), closeTo(-80 * unit, 1e-6));
    expect(kerning(first, 'To'), 0);
    expect(kerning(second, 'AV'), closeTo(-40 * unit, 1e-6));
    expect(kerning(second, 'To'), closeTo(-60 * unit, 1e-6));
  });

  test('standard font metrics and kerning', () {
    final helvetica = StandardFont.helvetica;
    expect(helvetica.widthOf('A', 1000, kerning: false), 667);
    final shaped = helvetica.shape('AV');
    expect(shaped.first.kerning, -70);
    expect(helvetica.widthOf('AV', 10), closeTo((667 + 667 - 70) / 100, 1e-9));
    expect(helvetica.covers(0x20ac), isTrue); // € in WinAnsi
    expect(helvetica.covers(0x3b1), isFalse); // α
    expect(StandardFont.named('Symbol').covers(0x3b1), isTrue);
  });

  test('OpenType features substitute glyphs: old-style numerals, '
      'small capitals', () {
    final font = EmbeddedFont.parse(
      File('test/fonts/notoserif-features.ttf').readAsBytesSync(),
    );
    expect(font.font.hasFeature('onum'), isTrue);
    expect(font.font.hasFeature('zero'), isFalse);
    List<int> ids(String text, [Set<String> features = const {}]) => [
      for (final glyph in font.shape(text, features: features)) glyph.id,
    ];
    final lining = ids('2026');
    final oldstyle = ids('2026', {'onum'});
    expect(oldstyle, hasLength(4));
    expect(oldstyle, isNot(lining));
    final small = ids('Abc', {'smcp'});
    // The capital stays; the lowercase letters become small capitals.
    expect(small.first, ids('A').single);
    expect(small.sublist(1), isNot(ids('bc')));
    // The text they stand for is unchanged.
    expect(
      font.shape('2026', features: {'onum'}).map((g) => g.text).join(),
      '2026',
    );
  });

  test('small capitals by multiple substitutions of one glyph', () {
    // Libertinus's smcp is a GSUB type 2 lookup.
    final font = EmbeddedFont.parse(
      File('test/fonts/libertinus-smcp.otf').readAsBytesSync(),
    );
    List<int> ids(String text, [Set<String> features = const {}]) => [
      for (final glyph in font.shape(text, features: features)) glyph.id,
    ];
    final small = ids('Abc', {'smcp'});
    expect(small, hasLength(3));
    expect(small.sublist(1), isNot(ids('bc')));
  });

  test('ligatures replace their sequence', () {
    final font = EmbeddedFont.parse(serif());
    final shaped = font.shape('office', ligatures: true);
    expect(shaped.map((g) => g.text).join(), 'office');
    if (font.font.ligatures.isNotEmpty) {
      expect(shaped.length, lessThan(6));
    }
  });

  test('a character without a glyph is .notdef, not mapped to text', () {
    final font = EmbeddedFont.parse(mplus());
    expect(font.covers(0x3093), isFalse); // ん: not in this subset
    final bytes = font.encode(font.shape('xん'));
    expect(bytes.sublist(2), [0, 0]);
    expect(font.missedGlyphs, isTrue);
  });

  test('subsets keep only the glyphs used', () {
    final dir = Directory.systemTemp.createTempSync('libpdf.');
    addTearDown(() => dir.deleteSync(recursive: true));
    final pdf = textPdf([(EmbeddedFont.parse(serif()), 'Hi')]);
    expect(pdf.length, lessThan(serif().length ~/ 2));
  });

  test(
    'embedded and standard fonts: qpdf is clean and the text extracts',
    () {
      final pdf = textPdf([
        (StandardFont.helvetica, 'AVAST, Water — “quotes” and €'),
        (StandardFont.timesRoman, 'Times: office ffi'),
        (EmbeddedFont.parse(serif()), 'Noto Serif: Ångström, office, “ok”'),
        (EmbeddedFont.parse(mplus()), 'M+ 1p: Привет, Γειά'),
      ]);
      final (check, text) = inspect(pdf);
      expect(check, contains('No syntax or stream encoding errors found'));
      final lines = text
          .trim()
          .split(RegExp(r'\n+'))
          .map((l) => l.trim())
          .toList();
      expect(lines, [
        'AVAST, Water — “quotes” and €',
        'Times: office ffi',
        'Noto Serif: Ångström, office, “ok”',
        'M+ 1p: Привет, Γειά',
      ]);
    },
    tags: ['pdf-tools'],
    skip: _tools ? false : 'qpdf or poppler missing',
  );

  test(
    'a subset renders like the whole font',
    () {
      const text = 'The quick brown fox — Ångström 0123456789';
      final subset = textPdf([(EmbeddedFont.parse(serif()), text)]);
      final whole = textPdf([
        (EmbeddedFont.parse(serif(), subset: false), text),
      ]);
      final dir = Directory.systemTemp.createTempSync('libpdf.');
      addTearDown(() => dir.deleteSync(recursive: true));
      List<int> render(Uint8List pdf, String name) {
        File('${dir.path}/$name.pdf').writeAsBytesSync(pdf);
        Process.runSync('pdftoppm', [
          '-r',
          '72',
          '-gray',
          '${dir.path}/$name.pdf',
          '${dir.path}/$name',
        ]);
        final image = dir.listSync().whereType<File>().firstWhere(
          (f) => f.path.contains('$name-') || f.path.endsWith('$name-1.pgm'),
        );
        return image.readAsBytesSync();
      }

      expect(render(subset, 'subset'), render(whole, 'whole'));
    },
    tags: ['pdf-tools'],
    skip: _tools ? false : 'poppler missing',
  );

  for (final (name, bytes) in [('name-keyed', cff), ('CID-keyed', cid)]) {
    test(
      'a $name CFF font is subset and renders like the TrueType font',
      () {
        const text = 'The quick brown fox — Ångström 0123456789 HHH';
        final subset = textPdf([(EmbeddedFont.parse(bytes()), text)]);
        final trueType = textPdf([(EmbeddedFont.parse(serif()), text)]);
        final (check, extracted) = inspect(subset);
        expect(check, contains('No syntax or stream encoding errors'));
        expect(extracted, contains(text));
        // Only the glyphs used, and the subroutines they call: far less
        // than the whole font.
        expect(subset.length, lessThan(bytes().length ~/ 4));
        final dir = Directory.systemTemp.createTempSync('libpdf.');
        addTearDown(() => dir.deleteSync(recursive: true));
        Uint8List render(Uint8List pdf, String name) {
          File('${dir.path}/$name.pdf').writeAsBytesSync(pdf);
          Process.runSync('pdftoppm', [
            '-r',
            '72',
            '-gray',
            '-singlefile',
            '${dir.path}/$name.pdf',
            '${dir.path}/$name',
          ]);
          return File('${dir.path}/$name.pgm').readAsBytesSync();
        }

        final a = render(subset, 'cff');
        final b = render(trueType, 'ttf');
        expect(a.length, b.length);
        // The same outlines (cubic where TrueType's are quadratic):
        // about the same ink, and in the same places.
        int ink(Uint8List image) => image.where((v) => v < 128).length;
        var apart = 0;
        for (var i = 0; i < a.length; i++) {
          if ((a[i] < 128) != (b[i] < 128)) apart++;
        }
        expect(ink(b), greaterThan(500));
        expect(ink(a), closeTo(ink(b), ink(b) * 0.05));
        // Rasterized a little differently (CFF and TrueType hinting).
        expect(apart, lessThan(ink(b) * 0.5));
      },
      tags: ['pdf-tools'],
      skip: _tools ? false : 'qpdf or poppler missing',
    );
  }
}

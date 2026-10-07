// The OpenType MATH table, MathML and the math layout, with a subset of
// Noto Sans Math (its MATH values checked against fontTools').
import 'dart:convert';
import 'dart:io';

import 'package:libpdf/libpdf.dart';
import 'package:test/test.dart';

bool _has(String tool) => Process.runSync('which', [tool]).exitCode == 0;

void main() {
  final font = EmbeddedFont.parse(
    File('test/fonts/notosansmath-subset.ttf').readAsBytesSync(),
  );
  final table = OpenTypeMathTable.parse(font.font.table('MATH')!)!;
  final layout = MathLayout(font);
  MathBox box(String mathml, {bool display = false}) =>
      layout.layout(parseMathML(mathml), size: 10, display: display);
  String math(String inner) =>
      '<math xmlns="http://www.w3.org/1998/Math/MathML">$inner</math>';

  group('MATH table', () {
    test('constants', () {
      expect(table[MathConstant.scriptPercentScaleDown], 60);
      expect(table[MathConstant.scriptScriptPercentScaleDown], 50);
      expect(table[MathConstant.displayOperatorMinHeight], 2300);
      expect(table[MathConstant.axisHeight], 278);
      expect(table[MathConstant.fractionRuleThickness], 71);
      expect(table[MathConstant.superscriptShiftUp], 390);
      expect(table[MathConstant.subscriptShiftDown], 210);
      expect(table[MathConstant.radicalKernAfterDegree], -450);
      expect(table[MathConstant.radicalDegreeBottomRaisePercent], 56);
    });

    test('variants and assemblies, italic corrections', () {
      final paren = table.vertical(font.font.glyphFor(0x28))!;
      expect(paren.variants.first.advance, 942);
      expect(
        paren.variants.map((v) => v.advance),
        orderedEquals([...paren.variants.map((v) => v.advance)]..sort()),
      );
      expect(paren.parts, hasLength(3));
      expect(paren.parts.where((p) => p.extender), hasLength(1));
      expect(table.minConnectorOverlap, 100);
      // Mathematical italic small f.
      expect(table.italicsCorrections[font.font.glyphFor(0x1d453)], 145);
    });
  });

  group('MathML', () {
    test('elements, with or without a prefix', () {
      final node = parseMathML(
        '<mml:math><mml:msubsup><mml:mi>a</mml:mi><mml:mn>1</mml:mn>'
        '<mml:mn>2</mml:mn></mml:msubsup></mml:math>',
      );
      expect(node, isA<MathScripts>());
      final scripts = node as MathScripts;
      expect((scripts.base as MathToken).text, 'a');
      expect((scripts.sub! as MathToken).kind, MathTokenKind.number);
      expect((scripts.sup! as MathToken).text, '2');
    });

    test('styles, tables and enclosures', () {
      final styled = parseMathML(
        math(
          '<mstyle mathcolor="#ff0000" mathvariant="bold"> <mi>x</mi> '
          '</mstyle>',
        ),
      );
      expect(styled, isA<MathStyled>());
      expect((styled as MathStyled).color, const RgbColor(1, 0, 0));
      expect(styled.variant, 'bold');
      final table = parseMathML(
        math(
          '<mtable><mtr><mtd><mi>a</mi></mtd><mtd><mi>b</mi></mtd></mtr>'
          '<mtr><mtd><mi>c</mi></mtd></mtr></mtable>',
        ),
      );
      expect((table as MathTable).rows.map((r) => r.length), [2, 1]);
      final enclose = parseMathML(
        math(
          '<menclose notation="box updiagonalstrike"> <mi>x</mi> '
          '</menclose>',
        ),
      );
      expect((enclose as MathEnclose).notations, ['box', 'updiagonalstrike']);
    });

    test('not MathML', () {
      expect(() => parseMathML('<math>'), throwsA(isA<MathMLException>()));
    });
  });

  group('layout', () {
    test('a superscript is raised, a subscript lowered', () {
      final base = box(math('<mi>x</mi>'));
      final sup = box(math('<msup><mi>x</mi><mn>2</mn></msup>'));
      final sub = box(math('<msub><mi>x</mi><mn>2</mn></msub>'));
      expect(sup.width, greaterThan(base.width));
      // At least SuperscriptShiftUp (3.9 points at 10) over the baseline.
      expect(sup.height, greaterThan(3.9));
      expect(sub.depth, greaterThanOrEqualTo(2.1));
      expect(sub.height, closeTo(base.height, 0.01));
    });

    test('a fraction about the math axis', () {
      final frac = box(math('<mfrac><mi>a</mi><mi>b</mi></mfrac>'));
      final display = box(
        math('<mfrac><mi>a</mi><mi>b</mi></mfrac>'),
        display: true,
      );
      expect(frac.height, greaterThan(2.78));
      expect(frac.depth, greaterThan(0));
      // Display style: larger shifts, full-size parts.
      expect(
        display.height + display.depth,
        greaterThan(frac.height + frac.depth),
      );
    });

    test('a radical over its radicand, an index before it', () {
      final x = box(math('<mi>x</mi>'));
      final root = box(math('<msqrt><mi>x</mi></msqrt>'));
      final cube = box(math('<mroot><mi>x</mi><mn>3</mn></mroot>'));
      expect(root.height, greaterThan(x.height));
      expect(root.width, greaterThan(x.width));
      // The index over the sign's left (its kern after the degree is
      // negative), the root no narrower.
      expect(cube.width, greaterThanOrEqualTo(root.width));
      expect(cube.height, greaterThanOrEqualTo(root.height));
    });

    test('delimiters stretch to what they enclose', () {
      final plain = box(math('<mrow><mo>(</mo><mi>x</mi><mo>)</mo></mrow>'));
      final tall = box(
        math(
          '<mrow><mo>(</mo><mtable>'
          '<mtr><mtd><mi>a</mi></mtd></mtr>'
          '<mtr><mtd><mi>b</mi></mtd></mtr>'
          '<mtr><mtd><mi>c</mi></mtd></mtr>'
          '</mtable><mo>)</mo></mrow>',
        ),
      );
      expect(
        tall.height + tall.depth,
        greaterThan(2 * (plain.height + plain.depth)),
      );
    });

    test('a large operator is larger in display style, with limits', () {
      const sum =
          '<munderover><mo>\u2211</mo><mi>i</mi><mi>n</mi></munderover>';
      final inline = box(math(sum));
      final display = box(math(sum), display: true);
      // DisplayOperatorMinHeight: 2.3 em at least.
      expect(display.height + display.depth, greaterThan(23));
      expect(
        display.height + display.depth,
        greaterThan(inline.height + inline.depth),
      );
      // Inline, the limits are scripts: beside, so wider than the sign.
      final sign = box(math('<mo>\u2211</mo>'));
      expect(inline.width, greaterThan(sign.width));
    });

    test('an accent over its base', () {
      final v = box(math('<mi>v</mi>'));
      final vec = box(
        math('<mover accent="true"><mi>v</mi><mo>\u2192</mo></mover>'),
      );
      expect(vec.height, greaterThan(v.height + 1));
    });

    test('spacing: thick around relations, none in scripts', () {
      final rel = box(math('<mi>a</mi><mo>=</mo><mi>b</mi>'));
      final tight = box(
        math(
          '<msup><mi>x</mi><mrow><mi>a</mi><mo>=</mo><mi>b</mi></mrow>'
          '</msup>',
        ),
      );
      final a = box(math('<mi>a</mi>'));
      final b = box(math('<mi>b</mi>'));
      final equals = box(math('<mo>=</mo>'));
      // Two thick spaces (5/18 em each).
      expect(
        rel.width,
        closeTo(a.width + equals.width + b.width + 2 * 5 / 18 * 10, 0.01),
      );
      expect(tight.width, lessThan(rel.width));
    });

    test('drawn: identifiers in math italic', () {
      final doc = PdfDocument();
      final page = doc.addPage(const PdfRect(0, 0, 200, 100));
      box(math('<mi>x</mi><mo>+</mo><mn>1</mn>')).paintAt(page.canvas, 10, 50);
      final file = File(
        '${Directory.systemTemp.createTempSync('math').path}/x.pdf',
      )..writeAsBytesSync(doc.save());
      // (UTF-8 both ways: Windows decodes output in its code page.)
      final text =
          Process.runSync('pdftotext', [
                '-enc',
                'UTF-8',
                file.path,
                '-',
              ], stdoutEncoding: utf8).stdout
              as String;
      expect(text.trim(), '\u{1d465}+1');
    }, skip: _has('pdftotext') ? false : 'needs pdftotext');
  });
}

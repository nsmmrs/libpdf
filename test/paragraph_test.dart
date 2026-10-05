import 'dart:io';

import 'package:libpdf/libpdf.dart';
import 'package:test/test.dart';

final PdfTextStyle body = PdfTextStyle(StandardFont.helvetica, 10);
final PdfTextStyle bold = PdfTextStyle(
  StandardFont.named('Helvetica-Bold'),
  10,
);

const String lorem =
    'Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do '
    'eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim '
    'ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut '
    'aliquip ex ea commodo consequat. Duis aute irure dolor in '
    'reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla '
    'pariatur.';

List<Line> lines(
  String text, {
  double width = 200,
  LineBreaker breaker = const FirstFitLineBreaker(),
  TextAlign align = TextAlign.left,
  LineHeight lineHeight = const LineHeight.font(),
  Hyphenator? hyphenator,
  bool breakLongWords = true,
  double firstLineIndent = 0,
}) => breaker.breakLines(
  Paragraph(
    [TextRun(text, body)],
    align: align,
    lineHeight: lineHeight,
    hyphenator: hyphenator,
    breakLongWords: breakLongWords,
    firstLineIndent: firstLineIndent,
  ),
  (_) => width,
);

String textOf(Line line) => [
  for (final fragment in line.fragments)
    if (fragment is TextFragment) fragment.text,
].join();

final class EveryThird implements Hyphenator {
  const new();

  @override
  List<int> hyphenate(String word) => [
    for (var i = 3; i < word.length - 2; i += 3) i,
  ];
}

void main() {
  test('first fit fills each line as far as it goes', () {
    final result = lines(lorem);
    expect(result.length, greaterThan(3));
    final words = lorem.split(' ');
    var next = 0;
    for (final (i, line) in result.indexed) {
      expect(line.width, lessThanOrEqualTo(200 + 1e-6));
      final text = textOf(line);
      next += text.split(' ').length;
      if (i < result.length - 1) {
        // The next word didn't fit.
        expect(line.width + body.measure(' ${words[next]}'), greaterThan(200));
      }
    }
    expect(result.map(textOf).join(' '), lorem);
  });

  test('Knuth-Plass evens out the lines', () {
    double slack(List<Line> lines) => [
      for (final line in lines.take(lines.length - 1))
        (200 - line.width) * (200 - line.width),
    ].fold(0, (a, b) => a + b);
    final greedy = lines(lorem);
    final total = lines(lorem, breaker: const KnuthPlassLineBreaker());
    expect(total.map(textOf).join(' '), lorem);
    for (final line in total) {
      expect(line.width, lessThanOrEqualTo(200 + 1e-6));
    }
    expect(slack(total), lessThanOrEqualTo(slack(greedy)));
  });

  test('justified lines reach both margins, except the last', () {
    for (final breaker in [
      const FirstFitLineBreaker(),
      const KnuthPlassLineBreaker(),
    ]) {
      final result = lines(lorem, align: TextAlign.justify, breaker: breaker);
      for (final line in result.take(result.length - 1)) {
        expect(line.width, closeTo(200, 1e-6));
        final last = line.fragments.last;
        expect(last.x + last.width, closeTo(200, 1e-6));
      }
      expect(result.last.width, lessThan(200));
    }
  });

  test('center and right alignment, and the first-line indent', () {
    final centered = lines('short', align: TextAlign.center).single;
    final w = body.measure('short');
    expect(centered.fragments.single.x, closeTo((200 - w) / 2, 1e-9));
    final right = lines('short', align: TextAlign.right).single;
    expect(right.fragments.single.x, closeTo(200 - w, 1e-9));
    final indented = lines(lorem, firstLineIndent: 20);
    expect(indented.first.fragments.first.x, 20);
    expect(indented.first.width, lessThanOrEqualTo(180 + 1e-6));
    expect(indented[1].fragments.first.x, 0);
  });

  test('hard breaks end lines, empty lines keep their height', () {
    final result = lines('one\ntwo\n\nfour');
    expect(result.map(textOf), ['one', 'two', '', 'four']);
    expect(result[2].height, result[0].height);
    expect(lines('a\r\nb').map(textOf), ['a', 'b']);
    expect(lines('a b').map(textOf), ['a', 'b']);
  });

  test('soft hyphens break with a hyphen, and are invisible otherwise', () {
    const word = 'extra­ordinary';
    expect(lines(word).map(textOf), ['extraordinary']);
    final narrow = lines('an $word thing', width: body.measure('an extra-'));
    expect(narrow.map(textOf), ['an extra-', 'ordinary', 'thing']);
    expect(narrow.first.hyphenated, isTrue);
  });

  test('a hyphenator gives break points inside words', () {
    final result = lines(
      'internationalization',
      width: body.measure('internation-'),
      hyphenator: const EveryThird(),
    );
    expect(result.length, greaterThan(1));
    expect(textOf(result.first), endsWith('-'));
    expect(
      result.map(textOf).join().replaceAll('-', ''),
      'internationalization',
    );
  });

  test('words wider than the line are broken anywhere, or stick out', () {
    const long = 'Pneumonoultramicroscopicsilicovolcanoconiosis';
    final broken = lines(long, width: 60);
    expect(broken.length, greaterThan(1));
    for (final line in broken) {
      expect(line.width, lessThanOrEqualTo(60 + 1e-6));
    }
    expect(broken.map(textOf).join(), long);
    final whole = lines(long, width: 60, breakLongWords: false);
    expect(whole.single.width, greaterThan(60));
  });

  test('runs keep their style; no break where runs meet inside a word', () {
    final paragraph = Paragraph([
      TextRun('a ', body),
      TextRun('bold', bold),
      TextRun('ish word', body),
    ]);
    final result = const FirstFitLineBreaker().breakLines(
      paragraph,
      (_) => body.measure('a ') + bold.measure('bold') + body.measure('ish'),
    );
    expect(result.map(textOf), ['a boldish', 'word']);
    final styles = [
      for (final f in result.first.fragments)
        if (f is TextFragment) f.style.font.name,
    ];
    expect(styles, ['Helvetica', 'Helvetica-Bold', 'Helvetica']);
  });

  test('UAX #14 opportunities: after hyphens, between ideographs', () {
    final narrow = body.measure('well-known') - 1;
    expect(lines('well-known', width: narrow).map(textOf), ['well-', 'known']);
    final items = paragraphItems(Paragraph([TextRun('漢字漢字', body)]));
    expect(items.whereType<PenaltyItem>().length, 3 + 1);
  });

  test('line height: font, multiple, exact; inline images', () {
    final font = lines('x').single;
    final helvetica = StandardFont.helvetica;
    expect(font.ascent, closeTo(helvetica.ascender / 100, 1e-9));
    expect(
      font.height,
      closeTo((helvetica.ascender - helvetica.descender) / 100, 1e-9),
    );
    expect(
      lines('x', lineHeight: const LineHeight.font(leading: 4)).single.height,
      closeTo(font.height + 4, 1e-9),
    );
    final multiple = lines(
      'x',
      lineHeight: const LineHeight.multiple(1.5),
    ).single;
    expect(multiple.height, 15);
    expect(
      multiple.baseline - multiple.ascent,
      closeTo((15 - (font.ascent - font.descent)) / 2, 1e-9),
    );
    expect(
      lines('x', lineHeight: const LineHeight.exact(30)).single.height,
      30,
    );

    final png = PdfImage.parse(
      File('test/images/pngsuite/basn2c08.png').readAsBytesSync(),
    );
    final withImage = const FirstFitLineBreaker().breakLines(
      Paragraph([
        TextRun('see ', body),
        InlineImage(png, 20, 20),
        TextRun(' here', body),
      ]),
      (_) => 200,
    );
    final line = withImage.single;
    expect(line.ascent, 20);
    final image = line.fragments.whereType<ImageFragment>().single;
    expect(image.x, closeTo(body.measure('see '), 1e-9));
    expect(textOf(line), 'see  here');
  });

  test(
    'a painted paragraph reads back with the same lines',
    () {
      final document = PdfDocument();
      final page = document.addPage(const PdfRect(0, 0, 300, 400));
      final result = lines(
        lorem,
        align: TextAlign.justify,
        breaker: const KnuthPlassLineBreaker(),
      );
      var top = 380.0;
      final links = <PdfRect>[];
      for (final line in result) {
        line.paint(page.canvas, 50, top, link: (rect, _) => links.add(rect));
        top -= line.height;
      }
      final dir = Directory.systemTemp.createTempSync('libpdf.');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/p.pdf')..writeAsBytesSync(document.save());
      final text =
          Process.runSync('pdftotext', ['-layout', file.path, '-']).stdout
              as String;
      final read = [
        for (final l in text.split('\n'))
          if (l.trim().isNotEmpty) l.trim().replaceAll(RegExp(' +'), ' '),
      ];
      expect(read, result.map(textOf).toList());
    },
    skip: Process.runSync('which', ['pdftotext']).exitCode == 0
        ? false
        : 'needs poppler',
    tags: ['pdf-tools'],
  );

  test(
    'inline decorations paint behind their text',
    () {
      final document = PdfDocument();
      final page = document.addPage(const PdfRect(0, 0, 100, 40));
      const FirstFitLineBreaker()
          .breakLines(
            Paragraph([
              TextRun(
                'MMMM',
                body,
                decoration: const InlineDecoration(
                  background: PdfColor.rgb(0, 1, 0),
                  padding: 2,
                ),
              ),
            ]),
            (_) => 100,
          )
          .single
          .paint(page.canvas, 10, 30);
      final dir = Directory.systemTemp.createTempSync('libpdf.');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/d.pdf')..writeAsBytesSync(document.save());
      Process.runSync('pdftoppm', [
        '-r',
        '72',
        '-singlefile',
        file.path,
        '${dir.path}/d',
      ]);
      final ppm = File('${dir.path}/d.ppm').readAsBytesSync();
      final pixels = ppm.sublist(ppm.length - 100 * 40 * 3);
      // Left of the text, inside the padding: green.
      const i = ((40 - 1 - 25) * 100 + 9) * 3;
      expect(pixels.sublist(i, i + 3), [0, 255, 0]);
    },
    skip: Process.runSync('which', ['pdftoppm']).exitCode == 0
        ? false
        : 'needs poppler',
    tags: ['pdf-tools'],
  );
}

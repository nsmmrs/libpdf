/// Paragraphs broken into lines: inline content becomes the boxes, glue
/// and penalties of Knuth and Plass's model, break opportunities come from
/// UAX #14, and a `LineBreaker` strategy chooses the breaks (first fit and
/// Knuth-Plass are provided). Lines are then aligned, measured and
/// painted.
library;

import 'dart:math' as math;

import 'package:libpdf/src/drawing/canvas.dart';
import 'package:libpdf/src/drawing/document.dart';
import 'package:libpdf/src/drawing/geometry.dart';
import 'package:libpdf/src/fonts/fonts.dart';
import 'package:libpdf/src/layout/inline.dart';
import 'package:libpdf/src/layout/line_break.dart';
import 'package:meta/meta.dart';

/// How the lines of a paragraph are spaced.
@immutable
sealed class LineHeight {
  const new _();

  /// The fonts' height (ascender to descender, plus their line gap) and
  /// [leading] more.
  const factory font({double leading}) = FontLineHeight;

  /// [factor] times the largest font size on the line, the extra split
  /// above and below the text (as CSS does).
  const factory multiple(double factor) = MultipleLineHeight;

  /// [points] per line.
  const factory exact(double points) = ExactLineHeight;
}

/// Lines as tall as their fonts, plus leading.
final class FontLineHeight extends LineHeight {
  /// The fonts' height plus [leading].
  const new({this.leading = 0}) : super._();

  /// The extra space between lines, in points.
  final double leading;
}

/// Lines a multiple of their font size tall.
final class MultipleLineHeight extends LineHeight {
  /// [factor] times the font size.
  const new(this.factor) : super._();

  /// The multiple.
  final double factor;
}

/// Lines of a fixed height.
final class ExactLineHeight extends LineHeight {
  /// [points] tall.
  const new(this.points) : super._();

  /// The height, in points.
  final double points;
}

/// How lines sit between the margins.
enum TextAlign {
  /// Against the left margin.
  left,

  /// Centered.
  center,

  /// Against the right margin.
  right,

  /// Against both margins, stretching the spaces (the last line, and
  /// lines ending in a hard break, are left aligned).
  justify,
}

/// Finds where words may be hyphenated.
abstract interface class Hyphenator {
  /// The offsets in [word] (letters only) a hyphen may go before.
  List<int> hyphenate(String word);
}

/// A paragraph: inline content, aligned and spaced.
@immutable
final class Paragraph {
  /// A paragraph of [content].
  const new(
    this.content, {
    this.align = TextAlign.left,
    this.lineHeight = const LineHeight.font(),
    this.firstLineIndent = 0,
    this.hyphenator,
    this.breakLongWords = true,
  });

  /// The inline content.
  final List<InlineContent> content;

  /// The alignment.
  final TextAlign align;

  /// The line spacing.
  final LineHeight lineHeight;

  /// The indent of the first line, in points.
  final double firstLineIndent;

  /// What hyphenates words, if anything.
  final Hyphenator? hyphenator;

  /// Whether a word wider than the line is broken between any two
  /// characters (rather than sticking out).
  final bool breakLongWords;
}

/// An item of the paragraph's line breaking model.
@immutable
sealed class LineItem {
  const new _();

  /// The item's natural width, in points.
  double get width;
}

/// Content that is never broken: a piece of a word, or an image.
final class BoxItem extends LineItem {
  /// The [text] of [content] (empty for an image), [width] wide.
  const new(this.content, this.text, this.width) : super._();

  /// The text run or image.
  final InlineContent content;

  /// The text.
  final String text;

  @override
  final double width;
}

/// A space: where a line may break (if a box comes before it), and what
/// stretches or shrinks to justify a line.
final class GlueItem extends LineItem {
  /// The space [text] of [run], [width] wide, which may grow by
  /// [stretch] and shrink by [shrink].
  const new(this.run, this.text, this.width, this.stretch, this.shrink)
    : super._();

  /// Glue that fills the rest of the last line.
  const new fill()
    : run = null,
      text = '',
      width = 0,
      stretch = double.infinity,
      shrink = 0,
      super._();

  /// The run the space belongs to (null for fill glue).
  final TextRun? run;

  /// The space characters.
  final String text;

  @override
  final double width;

  /// How much the space may grow.
  final double stretch;

  /// How much the space may shrink.
  final double shrink;
}

/// A place the line may break at a cost.
final class PenaltyItem extends LineItem {
  /// A break costing [penalty] (`forced` or below always breaks, `never`
  /// or above never does); [flagged] breaks add a hyphen of [width] in
  /// [run]'s style.
  const new(this.width, this.penalty, {this.flagged = false, this.run})
    : super._();

  /// The cost of breaking that forces a break.
  static const double forced = -10000;

  /// The cost of breaking that forbids it.
  static const double never = 10000;

  @override
  final double width;

  /// The cost of breaking here.
  final double penalty;

  /// Whether breaking here adds a hyphen.
  final bool flagged;

  /// The run the break is in: the hyphen's style, and the metrics of an
  /// empty line ending here.
  final TextRun? run;

  /// Whether the line must break here.
  bool get isForced => penalty <= forced;
}

/// The width available to each line (0-based) of a paragraph.
typedef LineWidths = double Function(int line);

/// Chooses where a paragraph's lines break.
abstract interface class LineBreaker {
  /// The lines of [paragraph] in [widths].
  List<Line> breakLines(Paragraph paragraph, LineWidths widths);
}

/// A line breaker over the items of [paragraphItems].
abstract base class ItemLineBreaker implements LineBreaker {
  /// A line breaker.
  const new();

  /// The indices of the items lines end at (glue or penalties), in order;
  /// the last is the final forced break.
  List<int> breakItems(List<LineItem> items, LineWidths widths);

  @override
  List<Line> breakLines(Paragraph paragraph, LineWidths widths) {
    final indent = paragraph.firstLineIndent;
    double indented(int line) => widths(line) - (line == 0 ? indent : 0);
    final items = paragraphItems(
      paragraph,
      maxWidth: paragraph.breakLongWords ? indented(0) : null,
    );
    if (items.isEmpty) return const [];
    return buildLines(paragraph, items, breakItems(items, indented), widths);
  }
}

/// The cost from which a break is a last resort for [FirstFitLineBreaker].
const double _lastResort = 500;

/// Breaks each line at the last opportunity that fits: the way most
/// word processors (and Prawn) fill lines. A break costing 500 or more
/// (between the characters of a word too long for a line) is taken only
/// when the line has no other.
final class FirstFitLineBreaker extends ItemLineBreaker {
  /// A first-fit line breaker.
  const new();

  @override
  List<int> breakItems(List<LineItem> items, LineWidths widths) {
    final breaks = <int>[];
    var start = 0;
    while (start < items.length) {
      final s = _skipDiscardable(items, start);
      if (s >= items.length) break;
      final available = widths(breaks.length) + _epsilon;
      var width = 0.0;
      int? candidate;
      var lastResort = false;
      int? end;
      for (var i = s; i < items.length; i++) {
        final item = items[i];
        switch (item) {
          case PenaltyItem(isForced: true):
            end = width <= available || candidate == null ? i : candidate;
          case PenaltyItem(:final penalty):
            // A costly break (between the characters of a word too long
            // for a line) only when the line has no other.
            final last = penalty >= _lastResort;
            if (penalty < PenaltyItem.never &&
                (!last || candidate == null || lastResort)) {
              if (width + item.width <= available) {
                candidate = i;
                lastResort = last;
              } else if (candidate == null) {
                end = i; // overfull, but the first chance to break
              }
            }
          case GlueItem(:final stretch):
            if (i > s && items[i - 1] is BoxItem && stretch.isFinite) {
              if (width <= available) {
                candidate = i;
                lastResort = false;
              } else {
                end = candidate ?? i;
              }
            }
            width += item.width;
          case BoxItem():
            width += item.width;
            if (width > available && candidate != null) end = candidate;
        }
        if (end != null) break;
      }
      final at = end ?? items.length - 1;
      breaks.add(at);
      start = at + 1;
    }
    return breaks;
  }
}

/// The total-fit algorithm of Knuth and Plass ("Breaking paragraphs into
/// lines", 1981): the breaks that minimize the sum of the lines'
/// demerits, so spacing is even across the paragraph.
final class KnuthPlassLineBreaker extends ItemLineBreaker {
  /// A Knuth-Plass line breaker; [tolerance] is the largest adjustment
  /// ratio accepted (retried larger when no breaks fit, then falling back
  /// to first fit).
  const new({
    this.tolerance = 2,
    this.linePenalty = 10,
    this.flaggedDemerits = 100,
    this.fitnessDemerits = 100,
  });

  /// The largest stretch ratio of a line.
  final double tolerance;

  /// The demerits of each line.
  final double linePenalty;

  /// The demerits of two hyphenated lines in a row.
  final double flaggedDemerits;

  /// The demerits of adjacent lines in very different fitness classes.
  final double fitnessDemerits;

  @override
  List<int> breakItems(List<LineItem> items, LineWidths widths) {
    for (final ratio in [tolerance, tolerance * 5, 100.0]) {
      final breaks = _total(items, widths, ratio);
      if (breaks != null) return breaks;
    }
    return const FirstFitLineBreaker().breakItems(items, widths);
  }

  List<int>? _total(List<LineItem> items, LineWidths widths, double limit) {
    // Running totals of the items before each index.
    final n = items.length;
    final totalWidth = List<double>.filled(n + 1, 0);
    final totalStretch = List<double>.filled(n + 1, 0);
    final totalShrink = List<double>.filled(n + 1, 0);
    for (var i = 0; i < n; i++) {
      final item = items[i];
      totalWidth[i + 1] =
          totalWidth[i] + (item is PenaltyItem ? 0 : item.width);
      totalStretch[i + 1] =
          totalStretch[i] + (item is GlueItem ? item.stretch : 0);
      totalShrink[i + 1] =
          totalShrink[i] + (item is GlueItem ? item.shrink : 0);
    }
    var active = <_Node>[_Node(-1, 0, 1, 0, null, flagged: false, start: 0)];
    for (var i = 0; i < n; i++) {
      final item = items[i];
      final penalty = switch (item) {
        PenaltyItem(:final penalty) when penalty < PenaltyItem.never => penalty,
        GlueItem(:final stretch)
            when i > 0 && items[i - 1] is BoxItem && stretch.isFinite =>
          0.0,
        _ => null,
      };
      if (penalty == null) continue;
      final flagged = item is PenaltyItem && item.flagged;
      final forced = item is PenaltyItem && item.isForced;
      final best = <(int, int), _Node>{};
      final survivors = <_Node>[];
      for (final node in active) {
        final start = node.start;
        var width = totalWidth[i] - totalWidth[start];
        if (item is PenaltyItem) width += item.width;
        final stretch = totalStretch[i] - totalStretch[start];
        final shrink = totalShrink[i] - totalShrink[start];
        final available = widths(node.line);
        final double ratio;
        if (width < available - _epsilon) {
          ratio = stretch > 0 ? (available - width) / stretch : double.infinity;
        } else if (width > available + _epsilon) {
          ratio = shrink > 0
              ? (available - width) / shrink
              : double.negativeInfinity;
        } else {
          ratio = 0;
        }
        if (ratio >= -1 && !forced) survivors.add(node);
        if (ratio < -1 || ratio > limit) continue;
        final badness = 100 * math.pow(ratio.abs(), 3);
        var demerits = math.pow(linePenalty + badness, 2).toDouble();
        if (penalty >= 0) {
          demerits += penalty * penalty;
        } else if (penalty > PenaltyItem.forced) {
          demerits -= penalty * penalty;
        }
        if (flagged && node.flagged) demerits += flaggedDemerits;
        final fitness = ratio < -0.5
            ? 0
            : ratio <= 0.5
            ? 1
            : ratio <= 1
            ? 2
            : 3;
        if ((fitness - node.fitness).abs() > 1) demerits += fitnessDemerits;
        final total = node.demerits + demerits;
        final key = (fitness, node.line + 1);
        if (best[key] == null || total < best[key]!.demerits) {
          best[key] = _Node(
            i,
            node.line + 1,
            fitness,
            total,
            node,
            flagged: flagged,
            start: _skipDiscardable(items, i + 1),
          );
        }
      }
      active = [...survivors, ...best.values];
      if (active.isEmpty) return null;
    }
    final finals = active.where((node) => node.position == n - 1);
    if (finals.isEmpty) return null;
    var node = finals.reduce((a, b) => a.demerits <= b.demerits ? a : b);
    final breaks = <int>[];
    for (_Node? at = node; at != null && at.position >= 0; at = at.previous) {
      breaks.add(at.position);
      node = at;
    }
    return breaks.reversed.toList();
  }
}

/// The letters at the start of a text.
final RegExp _leadingLetters = RegExp(r'\p{Alphabetic}*', unicode: true);

/// Typst's line breaking (typst-layout's `inline/linebreak.rs`, as of
/// v0.14): the breaks that minimize the sum of the lines' costs, each line
/// costing (1 + badness + penalty)². A line's badness is 100·|ratio|³,
/// its ratio how far its spaces stretch or shrink (past their stretch,
/// the rest spread over its spaces in half-ems); a line too full costs a
/// million rather than being refused. Ragged lines ([justify] false) may
/// not shrink, and the last line (before a forced break) costs only what
/// it shrinks. Penalties: a hyphenation [hyphenationCost] (15% more for
/// letter closer than five to the word's edge), two lines in a
/// row ending in a dash [hyphenationCost] more, a lone word on a line
/// before a forced break (a runt) [runtCost]. A penalty item's own
/// positive cost is added to its line's.
final class TypstLineBreaker extends ItemLineBreaker {
  /// A breaker for text set in [fontSize] points, justified or not.
  const new({
    this.justify = true,
    this.fontSize = 10,
    this.hyphenationCost = 135,
    this.runtCost = 100,
  });

  /// Whether the lines are justified (their spaces may shrink).
  final bool justify;

  /// The size of the text: stretch past the spaces' counts in half of it.
  final double fontSize;

  /// The cost of ending a line with a hyphenation.
  final double hyphenationCost;

  /// The cost of a lone word on the last line.
  final double runtCost;

  @override
  List<int> breakItems(List<LineItem> items, LineWidths widths) {
    final n = items.length;
    if (n == 0) return const [];
    // Running totals of the items before each index; infinite stretch (a
    // fill) counted apart.
    final width = List<double>.filled(n + 1, 0);
    final stretch = List<double>.filled(n + 1, 0);
    final shrink = List<double>.filled(n + 1, 0);
    final fills = List<int>.filled(n + 1, 0);
    final spaces = List<int>.filled(n + 1, 0);
    for (var i = 0; i < n; i++) {
      final item = items[i];
      width[i + 1] = width[i] + (item is PenaltyItem ? 0 : item.width);
      final infinite = item is GlueItem && !item.stretch.isFinite;
      stretch[i + 1] =
          stretch[i] + (item is GlueItem && !infinite ? item.stretch : 0);
      shrink[i + 1] = shrink[i] + (item is GlueItem ? item.shrink : 0);
      fills[i + 1] = fills[i] + (infinite ? 1 : 0);
      // (Justifiable spaces: not a fixed space, which never stretches.)
      spaces[i + 1] =
          spaces[i] +
          (item is GlueItem && !infinite && item.stretch > 0 ? 1 : 0);
    }
    bool candidate(int i) => switch (items[i]) {
      PenaltyItem(:final penalty) => penalty < PenaltyItem.never,
      GlueItem(stretch: final s) =>
        i > 0 && items[i - 1] is BoxItem && s.isFinite,
      BoxItem() => false,
    };
    final minRatio = justify ? -1.0 : 0.0;
    final entries = <_TypstEntry>[_TypstEntry(-1, 0, 0, 0, null, dash: false)];
    var active = 0;
    var previous = -1;
    for (var i = 0; i < n; i++) {
      if (!candidate(i)) continue;
      final item = items[i];
      final forced = item is PenaltyItem && item.isForced;
      final hyphen = item is PenaltyItem && item.flagged;
      // The line's end without the spaces before the break.
      var end = i;
      while (end > 0 && items[end - 1] is GlueItem) {
        end--;
      }
      var lastBox = end - 1;
      while (lastBox >= 0 && items[lastBox] is! BoxItem) {
        lastBox--;
      }
      final dash =
          hyphen ||
          (lastBox >= 0 && (items[lastBox] as BoxItem).text.endsWith('-'));
      // The letters of the word on each side of a hyphenation (not the
      // punctuation around it: Typst hyphenates "beyond" in “beyond”).
      double hyphenPenalty() {
        final before = StringBuffer();
        for (var k = i - 1; k >= 0 && items[k] is! GlueItem; k--) {
          if (items[k] case BoxItem(:final text)) {
            before.write(String.fromCharCodes(text.runes.toList().reversed));
          }
        }
        final after = StringBuffer();
        for (var k = i + 1; k < n && items[k] is! GlueItem; k++) {
          if (items[k] case BoxItem(:final text)) after.write(text);
        }
        int letters(String text) =>
            _leadingLetters.matchAsPrefix(text)?[0]?.runes.length ?? 0;
        // (Counted in code points.)
        final left = letters(before.toString());
        final right = letters(after.toString());
        final steps = math.max(0, 5 - left) + math.max(0, 5 - right);
        return (1 + 0.15 * steps) * hyphenationCost;
      }

      // (The same for every line ending here: computed once.)
      double? hyphenCost;
      _TypstEntry? best;
      for (var k = active; k < entries.length; k++) {
        final pred = entries[k];
        final start = pred.start;
        if (start > end) continue;
        var w = width[end] - width[start];
        if (item is PenaltyItem) w += item.width;
        final available = widths(pred.line);
        final infinite = fills[end] - fills[start] > 0;
        final ratio = _ratio(
          available - w,
          infinite ? double.infinity : stretch[end] - stretch[start],
          shrink[end] - shrink[start],
          spaces[end] - spaces[start],
        );
        final double badness;
        if (ratio < minRatio) {
          badness = 1000000;
        } else if (!forced || ratio < 0) {
          badness = 100 * math.pow(ratio.abs(), 3).toDouble();
        } else {
          badness = 0;
        }
        var penalty = 0.0;
        // A lone word: no break opportunity between the line's start and
        // its end.
        if (forced && pred.position == previous) penalty += runtCost;
        if (hyphen) penalty += hyphenCost ??= hyphenPenalty();
        if (dash && pred.dash) penalty += hyphenationCost;
        // A break's own cost (none of Typst's: a break between the
        // characters of a word too long for a line, say).
        if (item case PenaltyItem(penalty: final p)
            when !forced && !hyphen && p > 0) {
          penalty += p;
        }
        final cost = math.pow(1 + badness + penalty, 2).toDouble();
        if (ratio < minRatio && active == k) active++;
        final total = pred.total + cost;
        if (best == null || best.total >= total) {
          best = _TypstEntry(
            i,
            _skipDiscardable(items, i + 1),
            pred.line + 1,
            total,
            pred,
            dash: dash,
          );
        }
      }
      if (best != null) {
        entries.add(best);
        // Nothing breaks across a forced break.
        if (forced) active = entries.length - 1;
      }
      previous = i;
    }
    final breaks = <int>[];
    for (
      _TypstEntry? at = entries.last;
      at != null && at.position >= 0;
      at = at.previous
    ) {
      breaks.add(at.position);
    }
    return breaks.reversed.toList();
  }

  /// How far a line's spaces stretch (positive) or shrink (negative) to
  /// fill [rawDelta], Typst's `raw_ratio`.
  double _ratio(double rawDelta, double stretch, double shrink, int spaces) {
    final delta = rawDelta.abs() < 1e-9 ? 0.0 : rawDelta;
    final adjustability = math.max<double>(0, delta >= 0 ? stretch : shrink);
    var ratio = delta / adjustability;
    if (ratio.isNaN) ratio = 0;
    if (ratio > 1) {
      final extra = (delta - adjustability) / math.max(spaces, 1);
      ratio = 1 + extra / (fontSize / 2);
    }
    return ratio.clamp(-2.0, 10.0);
  }
}

final class _TypstEntry {
  new(
    this.position,
    this.start,
    this.line,
    this.total,
    this.previous, {
    required this.dash,
  });

  /// The item the line breaks at (-1 for the paragraph's start).
  final int position;

  /// The item the next line starts at.
  final int start;

  /// The number of lines up to this break.
  final int line;

  /// The cost of the lines up to this break.
  final double total;

  /// The break before.
  final _TypstEntry? previous;

  /// Whether the line ends with a dash (a hyphen).
  final bool dash;
}

final class _Node {
  new(
    this.position,
    this.line,
    this.fitness,
    this.demerits,
    this.previous, {
    required this.flagged,
    required this.start,
  });

  /// The item the break is at (-1 for the start of the paragraph).
  final int position;

  /// The number of lines before the break.
  final int line;

  final int fitness;
  final double demerits;
  final _Node? previous;
  final bool flagged;

  /// The first item of the line after the break.
  final int start;
}

const double _epsilon = 1e-6;

/// The first index from [start] that isn't glue or a penalty that
/// doesn't force a break (what a line break discards).
int _skipDiscardable(List<LineItem> items, int start) {
  var i = start;
  while (i < items.length &&
      (items[i] is GlueItem ||
          (items[i] is PenaltyItem && !(items[i] as PenaltyItem).isForced))) {
    i++;
  }
  return i;
}

/// The items of [paragraph]: its words as boxes, its spaces as glue, its
/// other break opportunities (UAX #14) as penalties, its hard breaks as
/// forced penalties. Soft hyphens, and the hyphenator's points, give
/// flagged penalties. With [maxWidth], a box wider than it is split into
/// characters with costly breaks between them.
List<LineItem> paragraphItems(Paragraph paragraph, {double? maxWidth}) {
  final contents = [
    for (final content in paragraph.content)
      ...switch (content) {
        PageReference(:final placeholder) => [content.resolve(placeholder)],
        TextRun(fallbackFonts: [_, ...]) => _withFallbacks(content),
        _ => [content],
      },
  ];
  final text = StringBuffer();
  for (final content in contents) {
    text.write(switch (content) {
      TextRun(:final text) => text,
      // U+FFFC OBJECT REPLACEMENT CHARACTER.
      InlineImage() => '\u{fffc}',
      PageReference(:final placeholder) => placeholder,
    });
  }
  final allowed = <int>{};
  final mandatory = <int>{};
  for (final b in lineBreaks(text.toString())) {
    (b.mandatory ? mandatory : allowed).add(b.offset);
  }
  final items = <LineItem>[];
  final word = StringBuffer();
  TextRun? wordRun;
  TextRun? lastRun;
  var softHyphen = false;

  void flush() {
    final run = wordRun;
    if (run == null || word.isEmpty) return;
    final piece = word.toString();
    word.clear();
    final hyphenator = paragraph.hyphenator;
    final points = hyphenator == null || !_isWord(piece)
        ? const <int>[]
        : hyphenator.hyphenate(piece);
    var from = 0;
    for (final point in [
      ...points.where((p) => p > 0 && p < piece.length),
    ]..sort()) {
      final part = piece.substring(from, point);
      items
        ..add(BoxItem(run, part, run.style.measure(part)))
        ..add(PenaltyItem(run.style.measure('-'), 50, flagged: true, run: run));
      from = point;
    }
    final rest = piece.substring(from);
    items.add(BoxItem(run, rest, run.style.measure(rest)));
  }

  var offset = 0;
  void breakBefore(int at) {
    if (at == 0) return;
    if (mandatory.contains(at)) {
      flush();
      items
        ..add(const GlueItem.fill())
        ..add(PenaltyItem(0, PenaltyItem.forced, run: lastRun));
    } else if (allowed.contains(at)) {
      flush();
      if (lastRun case final run? when softHyphen) {
        items.add(
          PenaltyItem(run.style.measure('-'), 50, flagged: true, run: run),
        );
      } else if (items.lastOrNull is! GlueItem) {
        items.add(PenaltyItem(0, 0, run: lastRun));
      }
    }
    softHyphen = false;
  }

  for (final content in contents) {
    switch (content) {
      case PageReference():
        break; // resolved above
      case InlineImage(:final width):
        breakBefore(offset);
        flush();
        items.add(BoxItem(content, '', width));
        offset += 1;
      case TextRun(:final text, :final style):
        final shrink = paragraph.align == TextAlign.justify
            ? style.measure(' ') / 3
            : 0.0;
        if (wordRun != content) flush();
        wordRun = content;
        lastRun = content;
        for (final rune in text.runes) {
          breakBefore(offset);
          wordRun = content;
          final length = rune > 0xffff ? 2 : 1;
          switch (rune) {
            case 0x0a || 0x0b || 0x0c || 0x0d || 0x85 || 0x2028 || 0x2029:
              break; // a hard break, already a forced penalty
            case 0x20 || 0x09:
              flush();
              final space = style.measure(' ');
              // Spaces only shrink in justified text: elsewhere nothing
              // would shrink them when the line is drawn.
              items.add(GlueItem(content, ' ', space, space / 2, shrink));
            case 0xad:
              softHyphen = true;
            case 0x200b || 0x2060 || 0xfeff:
              break; // zero width, not drawn
            default:
              word.writeCharCode(rune);
          }
          offset += length;
        }
        flush();
    }
  }
  flush();
  if (items.isEmpty) return items;
  items
    ..add(const GlueItem.fill())
    ..add(PenaltyItem(0, PenaltyItem.forced, run: lastRun));
  return maxWidth == null ? items : _splitWide(items, maxWidth);
}

/// [run] split where its font lacks characters a fallback font has.
List<TextRun> _withFallbacks(TextRun run) {
  final primary = run.style.font;
  PdfFont fontFor(int rune) {
    if (primary.covers(rune) || rune <= 0x20) return primary;
    for (final font in run.fallbackFonts) {
      if (font.covers(rune)) return font;
    }
    return primary;
  }

  final runs = <TextRun>[];
  final text = StringBuffer();
  PdfFont? current;
  void flush() {
    if (text.isEmpty) return;
    final piece = run.withText(text.toString());
    runs.add(
      identical(current, primary)
          ? piece
          : piece.withStyle(run.style.copyWith(font: current)),
    );
    text.clear();
  }

  for (final rune in run.text.runes) {
    // Spaces and controls stay with the font around them.
    final font = rune <= 0x20 && current != null ? current : fontFor(rune);
    if (!identical(font, current)) {
      flush();
      current = font;
    }
    text.writeCharCode(rune);
  }
  flush();
  return runs;
}

bool _isWord(String text) => text.runes.every(
  (c) =>
      lineBreakClass(c) == LineBreakClass.al ||
      lineBreakClass(c) == LineBreakClass.hl,
);

/// [items] with each box wider than [maxWidth] split into characters,
/// with costly breaks between them.
List<LineItem> _splitWide(List<LineItem> items, double maxWidth) {
  if (!items.any((item) => item is BoxItem && item.width > maxWidth)) {
    return items;
  }
  return [
    for (final item in items)
      if (item case BoxItem(content: final TextRun run, :final text)
          when item.width > maxWidth)
        for (final (i, char) in [
          for (final rune in text.runes) String.fromCharCode(rune),
        ].indexed) ...[
          if (i > 0) PenaltyItem(0, 1000, run: run),
          BoxItem(run, char, run.style.measure(char)),
        ]
      else
        item,
  ];
}

/// A piece of a line.
@immutable
sealed class LineFragment {
  const new _(this.x, this.width);

  /// The offset from the line's start, in points.
  final double x;

  /// The width, in points.
  final double width;
}

/// Text of one run on a line.
final class TextFragment extends LineFragment {
  /// [glyphs] of [run] set in [style] at [x].
  const new(super.x, super.width, this.run, this.text, this.glyphs, this.style)
    : super._();

  /// The run the text comes from.
  final TextRun run;

  /// The text (with its spaces).
  final String text;

  /// The shaped glyphs.
  final List<ShapedGlyph> glyphs;

  /// The style it is drawn in: the run's, with the word spacing that
  /// justifies the line.
  final PdfTextStyle style;
}

/// An inline image on a line.
final class ImageFragment extends LineFragment {
  /// [image] at [x], its bottom [bottom] points above the baseline.
  const new(super.x, super.width, this.image, this.bottom) : super._();

  /// The image.
  final InlineImage image;

  /// The offset of its bottom from the baseline (negative: below it).
  final double bottom;
}

/// A line of a paragraph, ready to paint.
@immutable
final class Line {
  /// A line of [fragments].
  const new(
    this.fragments, {
    required this.width,
    required this.height,
    required this.baseline,
    required this.ascent,
    required this.descent,
    required this.hyphenated,
  });

  /// The fragments, left to right, positioned for the alignment.
  final List<LineFragment> fragments;

  /// The width of the content, in points.
  final double width;

  /// The height the line takes, in points.
  final double height;

  /// The baseline's distance from the top of the line.
  final double baseline;

  /// The height of the content above the baseline.
  final double ascent;

  /// The depth of the content below the baseline (negative).
  final double descent;

  /// Whether the line ends with a hyphen the break added.
  final bool hyphenated;

  /// Paints the line with its top-left corner at ([x], [top]), reporting
  /// the rectangles of links to [link] and the positions of anchors to
  /// [anchor].
  void paint(
    PdfCanvas canvas,
    double x,
    double top, {
    void Function(PdfRect rect, LinkTarget target)? link,
    void Function(String name, double x, double y)? anchor,
  }) {
    final y = top - baseline;
    for (final fragment in fragments) {
      final left = x + fragment.x;
      switch (fragment) {
        case TextFragment(:final run, :final glyphs, :final style):
          final font = style.font;
          final size = style.size;
          if (run.decoration case final decoration?) {
            _decorate(
              canvas,
              decoration,
              PdfRect(
                left - decoration.padding,
                y + font.descender * size / 1000,
                fragment.width + 2 * decoration.padding,
                (font.ascender - font.descender) * size / 1000,
              ),
            );
          }
          canvas.save();
          if (run.color case final color?) canvas.setFillColor(color);
          canvas.glyphs(glyphs, left, y, style);
          final thickness = font.underlineThickness * size / 1000;
          if (run.underline) {
            canvas
              ..rect(
                PdfRect(
                  left,
                  y + font.underlinePosition * size / 1000 - thickness / 2,
                  fragment.width,
                  thickness,
                ),
              )
              ..fill();
          }
          if (run.strikethrough) {
            canvas
              ..rect(
                PdfRect(
                  left,
                  y + font.xHeight * size / 2000 - thickness / 2,
                  fragment.width,
                  thickness,
                ),
              )
              ..fill();
          }
          canvas.restore();
          if (run.link case final target? when link != null) {
            link(
              PdfRect(
                left,
                y + font.descender * size / 1000,
                fragment.width,
                (font.ascender - font.descender) * size / 1000,
              ),
              target,
            );
          }
          if (run.anchor case final name? when anchor != null) {
            anchor(name, left, y + font.ascender * size / 1000);
          }
        case ImageFragment(:final image, :final bottom):
          image.image.paint(
            canvas,
            PdfRect(left, y + bottom, image.width, image.height),
          );
          if (image.link case final target? when link != null) {
            link(PdfRect(left, y + bottom, image.width, image.height), target);
          }
      }
    }
  }
}

void _decorate(PdfCanvas canvas, InlineDecoration decoration, PdfRect rect) {
  void shape(PdfRect r) => decoration.radius > 0
      ? canvas.roundedRect(r, decoration.radius)
      : canvas.rect(r);
  canvas.save();
  if (decoration.background case final background?) {
    canvas.setFillColor(background);
    shape(rect);
    canvas.fill();
  }
  final w = decoration.borderWidth;
  if (decoration.borderColor case final color? when w > 0) {
    canvas
      ..setStrokeColor(color)
      ..setLineWidth(w);
    shape(
      PdfRect(
        rect.left + w / 2,
        rect.bottom + w / 2,
        rect.width - w,
        rect.height - w,
      ),
    );
    canvas.stroke();
  }
  canvas.restore();
}

/// The lines of [paragraph] from its [items] broken at [breaks], in
/// [widths].
List<Line> buildLines(
  Paragraph paragraph,
  List<LineItem> items,
  List<int> breaks,
  LineWidths widths,
) {
  final lines = <Line>[];
  var start = 0;
  for (final (number, end) in breaks.indexed) {
    final s = _skipDiscardable(items, start);
    final content = s < end ? items.sublist(s, end) : <LineItem>[];
    while (content.isNotEmpty && content.last is GlueItem) {
      content.removeLast();
    }
    final breakItem = items[end];
    final hyphen = breakItem is PenaltyItem && breakItem.flagged
        ? breakItem.run
        : null;
    final last =
        number == breaks.length - 1 ||
        (breakItem is PenaltyItem && breakItem.isForced);
    final indent = number == 0 ? paragraph.firstLineIndent : 0.0;
    final emptyRun = breakItem is PenaltyItem ? breakItem.run : null;
    lines.add(
      _line(
        paragraph,
        content,
        hyphen,
        widths(number) - indent,
        indent,
        justify: paragraph.align == TextAlign.justify && !last,
        emptyRun: emptyRun,
      ),
    );
    start = end + 1;
  }
  return lines;
}

Line _line(
  Paragraph paragraph,
  List<LineItem> items,
  TextRun? hyphen,
  double available,
  double indent, {
  required bool justify,
  required TextRun? emptyRun,
}) {
  // Runs of items of the same content, in order.
  final pieces = <(InlineContent, StringBuffer)>[];
  for (final item in items) {
    final (InlineContent? content, String text) = switch (item) {
      BoxItem(:final content, :final text) => (content, text),
      GlueItem(:final run?, :final text) => (run, text),
      _ => (null, ''),
    };
    if (content == null) continue;
    if (content is TextRun &&
        pieces.isNotEmpty &&
        identical(pieces.last.$1, content)) {
      pieces.last.$2.write(text);
    } else {
      pieces.add((content, StringBuffer(text)));
    }
  }
  if (hyphen != null) {
    if (pieces.isNotEmpty && identical(pieces.last.$1, hyphen)) {
      pieces.last.$2.write('-');
    } else {
      pieces.add((hyphen, StringBuffer('-')));
    }
  }

  // Natural widths, and the spaces justification stretches.
  var natural = 0.0;
  var spaces = 0;
  final shaped = <(InlineContent, String, List<ShapedGlyph>, double)>[];
  for (final (content, buffer) in pieces) {
    final text = buffer.toString();
    switch (content) {
      case TextRun(:final style):
        final glyphs = style.shape(text);
        final width = style.widthOf(glyphs);
        shaped.add((content, text, glyphs, width));
        natural += width;
        spaces += ' '.allMatches(text).length;
      case InlineImage(:final width):
        shaped.add((content, text, const [], width));
        natural += width;
      case PageReference():
        throw StateError('page references are resolved before breaking');
    }
  }
  final extra = justify && spaces > 0 ? (available - natural) / spaces : 0.0;
  final width = natural + extra * spaces;
  var x =
      indent +
      switch (paragraph.align) {
        TextAlign.left || TextAlign.justify => 0.0,
        TextAlign.center => (available - width) / 2,
        TextAlign.right => available - width,
      };

  // Vertical metrics.
  var ascent = 0.0;
  var descent = 0.0;
  var gap = 0.0;
  var size = 0.0;
  var xHeight = 0.0;
  void text(PdfTextStyle style) {
    final scale = style.size / 1000;
    ascent = math.max(
      ascent,
      style.font.ascender * scale + math.max(0, style.rise),
    );
    descent = math.min(
      descent,
      style.font.descender * scale + math.min(0, style.rise),
    );
    gap = math.max(gap, style.font.lineGap * scale);
    size = math.max(size, style.size);
    xHeight = math.max(xHeight, style.font.xHeight * scale);
  }

  for (final (content, _, _, _) in shaped) {
    if (content is TextRun) text(content.style);
  }
  if (shaped.isEmpty && emptyRun != null) text(emptyRun.style);
  final textAscent = ascent;
  final fragments = <LineFragment>[];
  for (final (content, string, glyphs, natural) in shaped) {
    switch (content) {
      case TextRun(:final style):
        final count = ' '.allMatches(string).length;
        final adjusted = extra == 0
            ? style
            : style.copyWith(wordSpacing: style.wordSpacing + extra);
        final w = natural + extra * count;
        fragments.add(TextFragment(x, w, content, string, glyphs, adjusted));
        x += w;
      case InlineImage(:final height, :final alignment):
        final bottom = switch (alignment) {
          InlineAlignment.baseline => 0.0,
          InlineAlignment.middle => xHeight / 2 - height / 2,
          InlineAlignment.top => textAscent - height,
        };
        ascent = math.max(ascent, bottom + height);
        descent = math.min(descent, bottom);
        if (size == 0) size = height;
        fragments.add(ImageFragment(x, content.width, content, bottom));
        x += content.width;
      case PageReference():
        throw StateError('page references are resolved before breaking');
    }
  }
  final (height, baseline) = switch (paragraph.lineHeight) {
    FontLineHeight(:final leading) => (
      ascent - descent + gap + leading,
      ascent,
    ),
    MultipleLineHeight(:final factor) => _centered(
      factor * size,
      ascent,
      descent,
    ),
    ExactLineHeight(:final points) => _centered(points, ascent, descent),
  };
  return Line(
    fragments,
    width: width,
    height: height,
    baseline: baseline,
    ascent: ascent,
    descent: descent,
    hyphenated: hyphen != null,
  );
}

/// A line [height] tall with its content centered (the extra split above
/// and below, as CSS does).
(double, double) _centered(double height, double ascent, double descent) =>
    (height, (height - (ascent - descent)) / 2 + ascent);

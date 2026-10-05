/// The box tree and pagination: blocks, paragraphs, images, spacers,
/// drawings, breaks and column sets flow into the regions of pages made
/// from templates, splitting where they must. Keep rules, orphans and
/// widows are decided by a `PageBreaker` strategy. Running headers and
/// footers see the page number, the page count and running marks; page
/// references are resolved by laying out again until nothing moves.
library;

import 'dart:math' as math;

import 'package:libpdf/src/drawing/canvas.dart';
import 'package:libpdf/src/drawing/color.dart';
import 'package:libpdf/src/drawing/document.dart';
import 'package:libpdf/src/drawing/geometry.dart';
import 'package:libpdf/src/images/images.dart';
import 'package:libpdf/src/layout/inline.dart';
import 'package:libpdf/src/layout/paragraph.dart';
import 'package:meta/meta.dart';

/// Distances on the four sides of a box.
@immutable
final class EdgeInsets {
  /// The given sides (0 elsewhere).
  const new({this.top = 0, this.right = 0, this.bottom = 0, this.left = 0});

  /// [value] on every side.
  const new all(double value)
    : top = value,
      right = value,
      bottom = value,
      left = value;

  /// [vertical] above and below, [horizontal] left and right.
  const new symmetric({double vertical = 0, double horizontal = 0})
    : top = vertical,
      bottom = vertical,
      left = horizontal,
      right = horizontal;

  /// No distance.
  static const EdgeInsets zero = EdgeInsets();

  /// The top distance.
  final double top;

  /// The right distance.
  final double right;

  /// The bottom distance.
  final double bottom;

  /// The left distance.
  final double left;

  /// Left plus right.
  double get horizontal => left + right;

  /// Top plus bottom.
  double get vertical => top + bottom;

  @override
  bool operator ==(Object other) =>
      other is EdgeInsets &&
      other.top == top &&
      other.right == right &&
      other.bottom == bottom &&
      other.left == left;

  @override
  int get hashCode => Object.hash(top, right, bottom, left);
}

/// A box's border: its width on each side, one color, and a corner
/// radius (drawn when the four widths are the same).
@immutable
final class Border {
  /// A border of [widths] in [color].
  const new({
    this.widths = EdgeInsets.zero,
    this.color = const GrayColor(0),
    this.radius = 0,
  });

  /// The width on each side.
  final EdgeInsets widths;

  /// The color.
  final PdfColor color;

  /// The corner radius.
  final double radius;

  /// No border.
  static const Border none = Border();
}

/// How a box is spaced, decorated and kept with others.
@immutable
final class BoxStyle {
  /// A style.
  const new({
    this.margin = EdgeInsets.zero,
    this.padding = EdgeInsets.zero,
    this.border = Border.none,
    this.background,
    this.keepTogether = false,
    this.keepWithNext = false,
    this.anchor,
    this.marks = const {},
  });

  /// The space outside the border.
  final EdgeInsets margin;

  /// The space between the border and the content.
  final EdgeInsets padding;

  /// The border.
  final Border border;

  /// The fill inside the border.
  final PdfColor? background;

  /// Whether the box moves to the next region rather than split (when it
  /// fits in a whole region).
  final bool keepTogether;

  /// Whether the box stays in the region where the next box starts.
  final bool keepWithNext;

  /// A name for the box's position (its top), for destinations.
  final String? anchor;

  /// Running marks the box sets where it starts (a chapter title for the
  /// running header).
  final Map<String, String> marks;
}

/// How a box narrower than its region sits in it.
enum BoxAlign {
  /// At the left.
  left,

  /// Centered.
  center,

  /// At the right.
  right,
}

/// A box of the layout tree.
@immutable
sealed class LayoutBox {
  const new _(this.style);

  /// The box's style.
  final BoxStyle style;
}

/// A box holding other boxes, one below the other.
final class BlockBox extends LayoutBox {
  /// A block of [children].
  const new(this.children, {BoxStyle style = const BoxStyle()})
    : _continued = false,
      super._(style);

  const new _rest(this.children, BoxStyle style)
    : _continued = true,
      super._(style);

  /// The children.
  final List<LayoutBox> children;

  /// Whether this is the rest of a block split by a break (no top margin,
  /// border or padding).
  final bool _continued;
}

/// A paragraph: lines broken from inline content. Its style's margins
/// apply; for padding, borders or a background, put it in a [BlockBox].
final class ParagraphBox extends LayoutBox {
  /// A box of [paragraph], keeping at least [orphans] lines before a
  /// break and [widows] after one.
  const new(
    this.paragraph, {
    BoxStyle style = const BoxStyle(),
    this.orphans = 2,
    this.widows = 2,
    this.lineBreaker,
  }) : _from = 0,
       _source = null,
       super._(style);

  new _rest(ParagraphBox source, this._from)
    : paragraph = source.paragraph,
      orphans = source.orphans,
      widows = source.widows,
      lineBreaker = source.lineBreaker,
      _source = source._source ?? source,
      super._(source.style);

  /// The paragraph.
  final Paragraph paragraph;

  /// The fewest lines before a break.
  final int orphans;

  /// The fewest lines after a break.
  final int widows;

  /// The line breaker, or null for the layout's.
  final LineBreaker? lineBreaker;

  /// The first line of this piece.
  final int _from;

  /// The paragraph this is the rest of.
  final ParagraphBox? _source;
}

/// An image of a given size.
final class ImageBox extends LayoutBox {
  /// [image] at [width] by [height], aligned by [align]; [shrinkToFit]
  /// scales it down when it is taller than a whole region.
  const new(
    this.image,
    this.width,
    this.height, {
    BoxStyle style = const BoxStyle(),
    this.align = BoxAlign.left,
    this.shrinkToFit = true,
  }) : super._(style);

  /// The image.
  final PdfImage image;

  /// The width.
  final double width;

  /// The height.
  final double height;

  /// Its alignment.
  final BoxAlign align;

  /// Whether it shrinks to fit a region.
  final bool shrinkToFit;
}

/// Vertical space, dropped at the top of a region.
final class SpacerBox extends LayoutBox {
  /// [height] points of space.
  const new(this.height) : super._(const BoxStyle());

  /// The height.
  final double height;
}

/// A box of a fixed height, drawn by a callback (a rule, a custom
/// graphic).
final class DrawingBox extends LayoutBox {
  /// A box [height] tall (and [width] wide, or the region's width) that
  /// [draw] paints into its rectangle.
  const new(
    this.height,
    this.draw, {
    this.width,
    BoxStyle style = const BoxStyle(),
    this.align = BoxAlign.left,
  }) : super._(style);

  /// The height.
  final double height;

  /// The width, or null for the region's width.
  final double? width;

  /// Paints the box into its rectangle.
  final void Function(PdfCanvas canvas, PdfRect rect) draw;

  /// Its alignment.
  final BoxAlign align;
}

/// Where a break goes.
enum BreakKind {
  /// To the next page.
  page,

  /// To the next column (or page, after the last column).
  column,
}

/// A forced break.
final class BreakBox extends LayoutBox {
  /// A break to the next page, made from the template named [template]
  /// (the layout's choice when null).
  const new page({this.template})
    : kind = BreakKind.page,
      super._(const BoxStyle());

  /// A break to the next column.
  const new column()
    : kind = BreakKind.column,
      template = null,
      super._(const BoxStyle());

  /// The kind of break.
  final BreakKind kind;

  /// The template of the next page.
  final String? template;
}

/// Boxes flowing through [count] columns, column by column, from where
/// the set starts to the bottom of the region (and on to the next).
final class ColumnsBox extends LayoutBox {
  /// [children] in [count] columns [gap] apart.
  const new(
    this.children, {
    this.count = 2,
    this.gap = 12,
    BoxStyle style = const BoxStyle(),
  }) : _continued = false,
       super._(style);

  const new _rest(this.children, this.count, this.gap, BoxStyle style)
    : _continued = true,
      super._(style);

  /// The children.
  final List<LayoutBox> children;

  /// The number of columns.
  final int count;

  /// The space between columns.
  final double gap;

  final bool _continued;
}

/// Decides where content breaks across regions.
abstract interface class PageBreaker {
  /// How many of the lines of [heights] go in [available] height (0 moves
  /// them all to the next region), keeping [orphans] lines before the
  /// break and [widows] after it; [atTop] when nothing is above them in
  /// the region (they can't move to a fresher one).
  int linesThatFit(
    List<double> heights,
    double available, {
    required int orphans,
    required int widows,
    required bool atTop,
  });

  /// Whether a box kept together, [height] tall, moves to the next
  /// region rather than split, with [available] left of a region
  /// [regionHeight] tall.
  bool moveKeptBox(double height, double available, double regionHeight);
}

/// The usual rules: as many lines as fit, unless that leaves fewer than
/// the orphans before the break or the widows after it; kept boxes move
/// when they fit in a whole region.
final class DefaultPageBreaker implements PageBreaker {
  /// The default page breaker.
  const new();

  @override
  int linesThatFit(
    List<double> heights,
    double available, {
    required int orphans,
    required int widows,
    required bool atTop,
  }) {
    var fit = 0;
    var used = 0.0;
    while (fit < heights.length && used + heights[fit] <= available + 1e-6) {
      used += heights[fit];
      fit++;
    }
    final total = heights.length;
    if (fit >= total) return total;
    // A line must go somewhere: at the top of a region, at least one.
    final least = atTop ? math.max(1, fit) : 0;
    if (fit < orphans) return least;
    if (total - fit < widows) {
      final kept = total - widows;
      return kept >= orphans ? kept : least;
    }
    return fit;
  }

  @override
  bool moveKeptBox(double height, double available, double regionHeight) =>
      height > available + 1e-6 && height <= regionHeight + 1e-6;
}

/// What a running header or footer knows about its page.
final class PageInfo {
  new _(this.number, this.count, this.label, this._marks);

  /// The page number (1-based).
  final int number;

  /// The number of pages.
  final int count;

  /// The page's label (its number as the layout writes it).
  final String label;

  final Map<String, String> _marks;

  /// The value of the running mark [name] on this page: the first one set
  /// on the page, or else the last one set before it.
  String? mark(String name) => _marks[name];
}

/// The pages content is laid out on.
@immutable
final class PageTemplate {
  /// Pages of [size] whose content area is inside [margins], in
  /// [columns] columns [columnGap] apart; [header] and [footer] give the
  /// boxes of the top and bottom margins, [background] paints under the
  /// content.
  const new(
    this.size, {
    this.margins = const EdgeInsets.all(72),
    this.columns = 1,
    this.columnGap = 12,
    this.header,
    this.footer,
    this.background,
  });

  /// The page size.
  final PdfRect size;

  /// The margins around the content area.
  final EdgeInsets margins;

  /// The number of columns of the content area.
  final int columns;

  /// The space between columns.
  final double columnGap;

  /// The boxes of the top margin for a page.
  final List<LayoutBox> Function(PageInfo page)? header;

  /// The boxes of the bottom margin for a page.
  final List<LayoutBox> Function(PageInfo page)? footer;

  /// Paints under a page's content.
  final void Function(PdfCanvas canvas, PageInfo page)? background;

  /// The regions content flows through, in order.
  List<PdfRect> get regions {
    final width = size.width - margins.horizontal;
    final columnWidth = (width - columnGap * (columns - 1)) / columns;
    return [
      for (var i = 0; i < columns; i++)
        PdfRect(
          size.left + margins.left + i * (columnWidth + columnGap),
          size.bottom + margins.bottom,
          columnWidth,
          size.height - margins.vertical,
        ),
    ];
  }
}

/// Where an anchor ended up.
@immutable
final class AnchorPosition {
  /// [page] (0-based) at ([x], [y]).
  const new(this.page, this.x, this.y);

  /// The page index.
  final int page;

  /// The x coordinate.
  final double x;

  /// The y coordinate (the top of what is anchored).
  final double y;
}

/// Lays boxes out on pages.
final class FlowLayout {
  /// A layout of pages from [template] (or, by name, from [templates],
  /// whose `null` entry is the default), breaking lines with
  /// [lineBreaker] and pages with [pageBreaker]; [pageLabel] writes page
  /// numbers (for references and headers).
  new({
    PageTemplate? template,
    Map<String?, PageTemplate>? templates,
    this.pageBreaker = const DefaultPageBreaker(),
    this.lineBreaker = const FirstFitLineBreaker(),
    String Function(int number)? pageLabel,
    this.maxPasses = 5,
  }) : templates = {null: ?template, ...?templates},
       pageLabel = pageLabel ?? _decimal {
    if (this.templates[null] == null) {
      throw ArgumentError('a default page template is needed');
    }
  }

  /// The page templates by name (`null` is the default).
  final Map<String?, PageTemplate> templates;

  /// Decides where content breaks across regions.
  final PageBreaker pageBreaker;

  /// Breaks paragraphs into lines (unless a paragraph has its own).
  final LineBreaker lineBreaker;

  /// Writes a page number.
  final String Function(int number) pageLabel;

  /// The most layouts tried to resolve page references.
  final int maxPasses;

  static String _decimal(int number) => '$number';

  /// [content] laid out on pages.
  LayoutResult layout(List<LayoutBox> content) {
    var anchors = <String, AnchorPosition>{};
    late _Pass pass;
    for (var i = 0; i < maxPasses; i++) {
      pass = _Pass(this, anchors)..run(content);
      final found = pass.anchors;
      final stable =
          found.length == anchors.length &&
          found.entries.every((e) => anchors[e.key]?.page == e.value.page);
      anchors = found;
      if (stable || !pass.hasReferences) break;
    }
    return LayoutResult._(this, pass.pages, anchors);
  }
}

/// One layout of the content.
final class _Pass {
  new(this.layout, this.previous);

  final FlowLayout layout;

  /// The anchors of the previous pass (for page references).
  final Map<String, AnchorPosition> previous;

  final List<_Page> pages = [];
  final Map<String, AnchorPosition> anchors = {};
  final Map<(ParagraphBox, double), List<Line>> _lines = {};
  bool hasReferences = false;

  void run(List<LayoutBox> content) {
    LayoutBox? rest = BlockBox(content);
    String? template;
    var guard = 0;
    while (rest != null) {
      final page = _Page(layout.templates[template] ?? layout.templates[null]!);
      template = null;
      for (final region in page.template.regions) {
        _regionHeight = region.height;
        final fit = _place(rest!, region.width, region.height, atTop: true);
        page.placed.add((region, fit.placed));
        rest = fit.rest;
        if (rest == null) break;
        if (fit.hit case BreakBox(kind: BreakKind.page, template: final name)) {
          template = name;
          break;
        }
      }
      pages.add(page);
      if (++guard > 100000) throw StateError('layout does not progress');
    }
    for (final (i, page) in pages.indexed) {
      for (final (region, placed) in page.placed) {
        placed?.visit(region.left, region.top, (anchor, x, y) {
          anchors.putIfAbsent(anchor, () => AnchorPosition(i, x, y));
        }, page.marks.add);
      }
    }
  }

  /// The label of the page of [anchor] from the previous pass.
  String? _pageOf(String anchor) => switch (previous[anchor]) {
    AnchorPosition(:final page) => layout.pageLabel(page + 1),
    null => null,
  };

  List<Line> _linesOf(ParagraphBox box, double width) {
    final source = box._source ?? box;
    return _lines[(source, width)] ??= () {
      final paragraph = source.paragraph;
      final content = [
        for (final c in paragraph.content)
          if (c case PageReference(:final anchor, :final placeholder))
            c.resolve(_pageOf(anchor) ?? placeholder)
          else
            c,
      ];
      if (content.length != paragraph.content.length ||
          paragraph.content.any((c) => c is PageReference)) {
        hasReferences = true;
      }
      final resolved = Paragraph(
        content,
        align: paragraph.align,
        lineHeight: paragraph.lineHeight,
        firstLineIndent: paragraph.firstLineIndent,
        hyphenator: paragraph.hyphenator,
        breakLongWords: paragraph.breakLongWords,
      );
      return (source.lineBreaker ?? layout.lineBreaker).breakLines(
        resolved,
        (_) => width,
      );
    }();
  }

  /// The height of [box] laid out with no limit.
  double _measure(LayoutBox box, double width) =>
      _place(box, width, double.infinity, atTop: false).height;

  /// The least height [box] needs where it starts (to keep a box with
  /// it).
  double _minHeight(LayoutBox box, double width) {
    final margin = box.style.margin;
    switch (box) {
      case ParagraphBox(:final orphans):
        final lines = _linesOf(box, width - margin.horizontal);
        return margin.top +
            lines.take(orphans).fold(0, (sum, line) => sum + line.height);
      case BlockBox(:final children) || ColumnsBox(:final children):
        final style = box.style;
        final inner =
            width -
            margin.horizontal -
            style.border.widths.horizontal -
            style.padding.horizontal;
        return margin.top +
            style.border.widths.top +
            style.padding.top +
            (children.isEmpty ? 0 : _minHeight(children.first, inner));
      case ImageBox() || DrawingBox():
        return _measure(box, width);
      case SpacerBox() || BreakBox():
        return 0;
    }
  }

  _Fit _place(
    LayoutBox box,
    double width,
    double available, {
    required bool atTop,
  }) => switch (box) {
    BlockBox() => _block(box, width, available, atTop: atTop),
    ParagraphBox() => _paragraph(box, width, available, atTop: atTop),
    ImageBox() => _image(box, width, available, atTop: atTop),
    DrawingBox() => _drawing(box, width, available, atTop: atTop),
    SpacerBox(:final height) =>
      atTop
          ? const _Fit(_PlacedSpace(0), 0, null)
          : _Fit(
              _PlacedSpace(math.min(height, available)),
              math.min(height, available),
              null,
            ),
    BreakBox() => _Fit(const _PlacedSpace(0), 0, null, hit: box),
    ColumnsBox() => _columns(box, width, available, atTop: atTop),
  };

  _Fit _block(
    BlockBox box,
    double width,
    double available, {
    required bool atTop,
  }) {
    final style = box.style;
    final continued = box._continued;
    final top =
        (atTop || continued ? 0 : style.margin.top) +
        (continued ? 0 : style.border.widths.top + style.padding.top);
    final bottom = style.padding.bottom + style.border.widths.bottom;
    final inner =
        width -
        style.margin.horizontal -
        style.border.widths.horizontal -
        style.padding.horizontal;
    if (style.keepTogether && !atTop && !continued && available.isFinite) {
      final whole = _measure(box, width);
      final region = _regionHeight;
      if (layout.pageBreaker.moveKeptBox(whole, available, region)) {
        return _Fit.moved(box);
      }
    }
    final room = available - top - bottom;
    final children = <(double, _Placed)>[];
    var cursor = 0.0;
    final atTopInside = atTop && top == 0;
    _Fit split(List<LayoutBox> rest, {BreakBox? hit}) {
      if (children.isEmpty && rest.length == box.children.length && !atTop) {
        return _Fit.moved(box);
      }
      final placed = _PlacedBlock(
        style,
        width,
        top + cursor,
        children,
        top: atTop || continued ? 0 : style.margin.top,
        openTop: continued,
        openBottom: true,
        marks: continued ? const {} : style.marks,
        anchor: continued ? null : style.anchor,
      );
      return _Fit(
        placed,
        placed.height,
        rest.isEmpty && hit == null ? null : BlockBox._rest(rest, style),
        hit: hit,
      );
    }

    for (var i = 0; i < box.children.length; i++) {
      final child = box.children[i];
      final childAtTop = atTopInside && cursor == 0;
      if (child is BreakBox) {
        if (childAtTop) continue; // a break at the top of a region: none
        final rest = box.children.sublist(i + 1);
        return split(rest, hit: child);
      }
      final fit = _place(child, inner, room - cursor, atTop: childAtTop);
      if (fit.placed == null) {
        return split(box.children.sublist(i));
      }
      if (fit.rest == null &&
          fit.hit == null &&
          child.style.keepWithNext &&
          i + 1 < box.children.length &&
          !childAtTop) {
        final next = _minHeight(box.children[i + 1], inner);
        if (cursor + fit.height + next > room + 1e-6) {
          return split(box.children.sublist(i));
        }
      }
      children.add((cursor, fit.placed!));
      cursor += fit.height;
      if (fit.rest != null || fit.hit != null) {
        return split([?fit.rest, ...box.children.sublist(i + 1)], hit: fit.hit);
      }
    }
    final placed = _PlacedBlock(
      style,
      width,
      top + cursor + bottom + style.margin.bottom,
      children,
      top: atTop || continued ? 0 : style.margin.top,
      openTop: continued,
      openBottom: false,
      marks: continued ? const {} : style.marks,
      anchor: continued ? null : style.anchor,
    );
    return _Fit(placed, placed.height, null);
  }

  /// The height of the region being filled (for keep rules).
  double _regionHeight = double.infinity;

  _Fit _paragraph(
    ParagraphBox box,
    double width,
    double available, {
    required bool atTop,
  }) {
    final margin = box.style.margin;
    final lines = _linesOf(box, width - margin.horizontal);
    final from = box._from;
    final top = atTop || from > 0 ? 0.0 : margin.top;
    final heights = [for (final line in lines.skip(from)) line.height];
    final count = layout.pageBreaker.linesThatFit(
      heights,
      available - top,
      orphans: box.orphans,
      widows: box.widows,
      atTop: atTop,
    );
    if (count == 0 && heights.isNotEmpty) return _Fit.moved(box);
    final placed = lines.sublist(from, from + count);
    final done = from + count >= lines.length;
    final height =
        top +
        placed.fold<double>(0, (sum, line) => sum + line.height) +
        (done ? margin.bottom : 0);
    return _Fit(
      _PlacedLines(
        placed,
        margin.left,
        top,
        height,
        from == 0 ? box.style.anchor : null,
        from == 0 ? box.style.marks : const {},
      ),
      height,
      done ? null : ParagraphBox._rest(box, from + count),
    );
  }

  _Fit _image(
    ImageBox box,
    double width,
    double available, {
    required bool atTop,
  }) {
    final margin = box.style.margin;
    final top = atTop ? 0.0 : margin.top;
    var w = box.width;
    var h = box.height;
    final room = width - margin.horizontal;
    if (w > room) {
      h *= room / w;
      w = room;
    }
    if (top + h > available + 1e-6) {
      if (!atTop) return _Fit.moved(box);
      if (box.shrinkToFit && available.isFinite) {
        w *= (available - top) / h;
        h = available - top;
      }
    }
    final x =
        margin.left +
        switch (box.align) {
          BoxAlign.left => 0.0,
          BoxAlign.center => (room - w) / 2,
          BoxAlign.right => room - w,
        };
    final height = top + h + margin.bottom;
    return _Fit(
      _PlacedImage(box.image, x, top, w, h, height, box.style.anchor),
      height,
      null,
    );
  }

  _Fit _drawing(
    DrawingBox box,
    double width,
    double available, {
    required bool atTop,
  }) {
    final margin = box.style.margin;
    final top = atTop ? 0.0 : margin.top;
    if (top + box.height > available + 1e-6 && !atTop) {
      return _Fit.moved(box);
    }
    final room = width - margin.horizontal;
    final w = math.min(box.width ?? room, room);
    final x =
        margin.left +
        switch (box.align) {
          BoxAlign.left => 0.0,
          BoxAlign.center => (room - w) / 2,
          BoxAlign.right => room - w,
        };
    final height = top + box.height + margin.bottom;
    return _Fit(
      _PlacedDrawing(box.draw, x, top, w, box.height, height, box.style.anchor),
      height,
      null,
    );
  }

  _Fit _columns(
    ColumnsBox box,
    double width,
    double available, {
    required bool atTop,
  }) {
    final style = box.style;
    final top = atTop || box._continued ? 0.0 : style.margin.top;
    final inner = width - style.margin.horizontal;
    final columnWidth = (inner - box.gap * (box.count - 1)) / box.count;
    LayoutBox? rest = BlockBox(box.children);
    final columns = <(double, _Placed)>[];
    var height = 0.0;
    BreakBox? hit;
    for (var c = 0; c < box.count && rest != null; c++) {
      final fit = _place(
        rest,
        columnWidth,
        available - top,
        atTop: c > 0 || atTop,
      );
      if (fit.placed == null) {
        if (c == 0) return _Fit.moved(box);
        break;
      }
      columns.add((
        style.margin.left + c * (columnWidth + box.gap),
        fit.placed!,
      ));
      height = math.max(height, fit.height);
      rest = fit.rest;
      if (fit.hit case BreakBox(kind: BreakKind.page) && final page) {
        hit = page;
        break;
      }
    }
    final done = rest == null;
    final total = top + height + (done ? style.margin.bottom : 0);
    return _Fit(
      _PlacedColumns(columns, top, total),
      total,
      done
          ? null
          : ColumnsBox._rest(
              switch (rest) {
                BlockBox(:final children) => children,
                final other => [other],
              },
              box.count,
              box.gap,
              style,
            ),
      hit: hit,
    );
  }
}

/// What placing a box gave: the placed part, its height, and the rest
/// (null when all of it was placed).
final class _Fit {
  const new(this.placed, this.height, this.rest, {this.hit});

  /// Nothing placed: all of [box] goes to the next region.
  const new moved(LayoutBox box)
    : placed = null,
      height = 0,
      rest = box,
      hit = null;

  final _Placed? placed;
  final double height;
  final LayoutBox? rest;

  /// The forced break that ended the placing.
  final BreakBox? hit;
}

final class _Page {
  new(this.template);

  final PageTemplate template;
  final List<(PdfRect, _Placed?)> placed = [];

  /// The marks set on the page, in order.
  final List<(String, String)> marks = [];
}

/// A placed piece of a box, positioned relative to the top left of the
/// space it was placed in.
sealed class _Placed {
  const new();

  double get height;

  /// Reports the anchors and marks of the piece at ([x], [top]).
  void visit(
    double x,
    double top,
    void Function(String anchor, double x, double y) anchor,
    void Function((String, String) mark) mark,
  );

  /// Paints the piece at ([x], [top]).
  void paint(_Painter painter, double x, double top);
}

final class _Painter {
  new(this.canvas, this.page);

  final PdfCanvas canvas;
  final PdfPage page;
}

final class _PlacedSpace extends _Placed {
  const new(this.height);

  @override
  final double height;

  @override
  void visit(
    double x,
    double top,
    void Function(String anchor, double x, double y) anchor,
    void Function((String, String) mark) mark,
  ) {}

  @override
  void paint(_Painter painter, double x, double top) {}
}

final class _PlacedBlock extends _Placed {
  const new(
    this.style,
    this.width,
    this.height,
    this.children, {
    required this.top,
    required this.openTop,
    required this.openBottom,
    required this.marks,
    required this.anchor,
  });

  final BoxStyle style;
  final double width;
  @override
  final double height;

  /// The children and their offsets below the content top.
  final List<(double, _Placed)> children;

  /// The top margin taken.
  final double top;

  final bool openTop;
  final bool openBottom;
  final Map<String, String> marks;
  final String? anchor;

  double get _contentTop =>
      top + (openTop ? 0 : style.border.widths.top + style.padding.top);

  double get _contentLeft =>
      style.margin.left + style.border.widths.left + style.padding.left;

  @override
  void visit(
    double x,
    double top,
    void Function(String anchor, double x, double y) anchor,
    void Function((String, String) mark) mark,
  ) {
    if (this.anchor case final name?) {
      anchor(name, x + style.margin.left, top - this.top);
    }
    marks.entries.map((e) => (e.key, e.value)).forEach(mark);
    for (final (offset, child) in children) {
      child.visit(x + _contentLeft, top - _contentTop - offset, anchor, mark);
    }
  }

  @override
  void paint(_Painter painter, double x, double top) {
    final canvas = painter.canvas;
    final border = style.border;
    final left = x + style.margin.left;
    final boxWidth = width - style.margin.horizontal;
    final boxTop = top - this.top;
    final bottomMargin = openBottom ? 0 : style.margin.bottom;
    final boxHeight = height - this.top - bottomMargin;
    final rect = PdfRect(left, boxTop - boxHeight, boxWidth, boxHeight);
    final uniform =
        border.widths.top == border.widths.left &&
        border.widths.left == border.widths.right &&
        border.widths.right == border.widths.bottom &&
        !openTop &&
        !openBottom;
    if (style.background case final background?) {
      canvas
        ..save()
        ..setFillColor(background);
      if (border.radius > 0 && uniform) {
        canvas.roundedRect(rect, border.radius);
      } else {
        canvas.rect(rect);
      }
      canvas
        ..fill()
        ..restore();
    }
    final widths = border.widths;
    if (widths != EdgeInsets.zero) {
      canvas
        ..save()
        ..setStrokeColor(border.color);
      if (uniform && widths.top > 0) {
        final w = widths.top;
        final inset = PdfRect(
          rect.left + w / 2,
          rect.bottom + w / 2,
          rect.width - w,
          rect.height - w,
        );
        canvas.setLineWidth(w);
        if (border.radius > 0) {
          canvas.roundedRect(inset, math.max(0, border.radius - w / 2));
        } else {
          canvas.rect(inset);
        }
        canvas.stroke();
      } else {
        void side(double w, double x1, double y1, double x2, double y2) {
          if (w <= 0) return;
          canvas
            ..setLineWidth(w)
            ..moveTo(x1, y1)
            ..lineTo(x2, y2)
            ..stroke();
        }

        final PdfRect(left: l, bottom: b, right: r, top: t) = rect;
        if (!openTop) {
          side(widths.top, l, t - widths.top / 2, r, t - widths.top / 2);
        }
        if (!openBottom) {
          side(
            widths.bottom,
            l,
            b + widths.bottom / 2,
            r,
            b + widths.bottom / 2,
          );
        }
        side(widths.left, l + widths.left / 2, b, l + widths.left / 2, t);
        side(widths.right, r - widths.right / 2, b, r - widths.right / 2, t);
      }
      canvas.restore();
    }
    for (final (offset, child) in children) {
      child.paint(painter, x + _contentLeft, top - _contentTop - offset);
    }
  }
}

final class _PlacedLines extends _Placed {
  const new(
    this.lines,
    this.left,
    this.top,
    this.height,
    this.anchor,
    this.marks,
  );

  final Map<String, String> marks;

  final List<Line> lines;
  final double left;
  final double top;
  @override
  final double height;
  final String? anchor;

  @override
  void visit(
    double x,
    double top,
    void Function(String anchor, double x, double y) anchor,
    void Function((String, String) mark) mark,
  ) {
    if (this.anchor case final name?) anchor(name, x + left, top - this.top);
    marks.entries.map((e) => (e.key, e.value)).forEach(mark);
    var y = top - this.top;
    for (final line in lines) {
      for (final fragment in line.fragments) {
        if (fragment case TextFragment(:final run, :final style)
            when run.anchor != null) {
          anchor(
            run.anchor!,
            x + left + fragment.x,
            y - line.baseline + style.font.ascender * style.size / 1000,
          );
        }
      }
      y -= line.height;
    }
  }

  @override
  void paint(_Painter painter, double x, double top) {
    var y = top - this.top;
    for (final line in lines) {
      line.paint(painter.canvas, x + left, y, link: painter.page.link);
      y -= line.height;
    }
  }
}

final class _PlacedImage extends _Placed {
  const new(
    this.image,
    this.left,
    this.top,
    this.width,
    this.imageHeight,
    this.height,
    this.anchor,
  );

  final PdfImage image;
  final double left;
  final double top;
  final double width;
  final double imageHeight;
  @override
  final double height;
  final String? anchor;

  @override
  void visit(
    double x,
    double top,
    void Function(String anchor, double x, double y) anchor,
    void Function((String, String) mark) mark,
  ) {
    if (this.anchor case final name?) anchor(name, x + left, top - this.top);
  }

  @override
  void paint(_Painter painter, double x, double top) {
    painter.canvas.image(
      image,
      PdfRect(x + left, top - this.top - imageHeight, width, imageHeight),
    );
  }
}

final class _PlacedDrawing extends _Placed {
  const new(
    this.draw,
    this.left,
    this.top,
    this.width,
    this.drawingHeight,
    this.height,
    this.anchor,
  );

  final void Function(PdfCanvas canvas, PdfRect rect) draw;
  final double left;
  final double top;
  final double width;
  final double drawingHeight;
  @override
  final double height;
  final String? anchor;

  @override
  void visit(
    double x,
    double top,
    void Function(String anchor, double x, double y) anchor,
    void Function((String, String) mark) mark,
  ) {
    if (this.anchor case final name?) anchor(name, x + left, top - this.top);
  }

  @override
  void paint(_Painter painter, double x, double top) {
    painter.canvas.saved(
      () => draw(
        painter.canvas,
        PdfRect(x + left, top - this.top - drawingHeight, width, drawingHeight),
      ),
    );
  }
}

final class _PlacedColumns extends _Placed {
  const new(this.columns, this.top, this.height);

  final List<(double, _Placed)> columns;
  final double top;
  @override
  final double height;

  @override
  void visit(
    double x,
    double top,
    void Function(String anchor, double x, double y) anchor,
    void Function((String, String) mark) mark,
  ) {
    for (final (left, column) in columns) {
      column.visit(x + left, top - this.top, anchor, mark);
    }
  }

  @override
  void paint(_Painter painter, double x, double top) {
    for (final (left, column) in columns) {
      column.paint(painter, x + left, top - this.top);
    }
  }
}

/// Content laid out on pages, ready to render.
final class LayoutResult {
  new _(this._layout, this._pages, this.anchors);

  final FlowLayout _layout;
  final List<_Page> _pages;

  /// Where each anchor is.
  final Map<String, AnchorPosition> anchors;

  /// The number of pages.
  int get pageCount => _pages.length;

  /// The page number of [anchor] (1-based), if it is anchored.
  int? pageOf(String anchor) => switch (anchors[anchor]) {
    AnchorPosition(:final page) => page + 1,
    null => null,
  };

  /// Adds the pages to [document]; anchors become named destinations.
  List<PdfPage> render(PdfDocument document) {
    final rendered = <PdfPage>[];
    final carried = <String, String>{};
    for (final (i, page) in _pages.indexed) {
      // A mark's value on a page: the first set on it, else the last
      // carried over.
      final marks = {...carried};
      final firsts = <String>{};
      for (final (name, value) in page.marks) {
        if (firsts.add(name)) marks[name] = value;
        carried[name] = value;
      }
      final info = PageInfo._(
        i + 1,
        _pages.length,
        _layout.pageLabel(i + 1),
        marks,
      );
      final template = page.template;
      final pdfPage = document.addPage(template.size);
      final painter = _Painter(pdfPage.canvas, pdfPage);
      template.background?.call(pdfPage.canvas, info);
      _running(template.header?.call(info), template, painter, header: true);
      for (final (region, placed) in page.placed) {
        placed?.paint(painter, region.left, region.top);
      }
      _running(template.footer?.call(info), template, painter, header: false);
      rendered.add(pdfPage);
    }
    for (final MapEntry(key: name, value: position) in anchors.entries) {
      document.addDestination(
        name,
        PdfDestination.xyz(
          rendered[position.page],
          left: position.x,
          top: position.y,
        ),
      );
    }
    return rendered;
  }

  /// Lays out and paints running content in the top or bottom margin.
  void _running(
    List<LayoutBox>? boxes,
    PageTemplate template,
    _Painter painter, {
    required bool header,
  }) {
    if (boxes == null || boxes.isEmpty) return;
    final size = template.size;
    final margins = template.margins;
    final width = size.width - margins.horizontal;
    final height = header ? margins.top : margins.bottom;
    final pass = _Pass(_layout, anchors).._regionHeight = height;
    final fit = pass._place(BlockBox(boxes), width, height, atTop: true);
    final top = header ? size.top : size.bottom + margins.bottom;
    fit.placed?.paint(painter, size.left + margins.left, top);
  }
}

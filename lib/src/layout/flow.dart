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
import 'package:libpdf/src/drawing/graphic.dart';
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

/// Paints extra decoration over a block's background and border, before
/// its content: [rect] is the part of the block (inside its margins) on
/// [page]; [first] and [last] tell whether it is where the block starts
/// and ends (a block split across pages has a piece on each).
typedef BoxDecoration = void Function(
  PdfPage page,
  PdfRect rect, {
  required bool first,
  required bool last,
});

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
    this.decoration,
    this.tag,
    this.float,
    this.floatBarrier = false,
    this.verticalAlign,
    this.cloneEdges = false,
    this.floatClearance = 0,
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

  /// A name the layout reports the pages the box is placed on by
  /// ([LayoutResult.tagPages]): the first and the last, when it breaks
  /// across pages.
  final String? tag;

  /// Running marks the box sets where it starts (a chapter title for the
  /// running header).
  final Map<String, String> marks;

  /// Extra decoration: of a block, painted over its background and
  /// border; of a custom box, painted under its content (in the box's
  /// width, without its margins).
  final BoxDecoration? decoration;

  /// Where the box floats (a figure), or null when it stays in the flow.
  /// A floating box that doesn't fit where it is (and isn't at the top of
  /// a region) goes to the top of the next region, the content after it
  /// filling the room; one that fits goes to the top or the bottom of its
  /// region ([FloatPlacement]), the content flowing around it. Blocks and
  /// custom boxes float, not inside columns, tables or framed blocks.
  final FloatPlacement? float;

  /// Whether the box floats.
  bool get floating => float != null;

  /// Whether floating boxes waiting for the next region keep the box
  /// from being placed before them (a section heading): it starts the
  /// next region after them.
  final bool floatBarrier;

  /// Where a block that starts a region, and fits in it whole, sits in
  /// the room there: at the top (as without), in the middle or at the
  /// bottom (a dedication alone on its page). Blocks only.
  final VerticalAlign? verticalAlign;

  /// Whether each piece of a block split across regions has the block's
  /// padding and border at its top and bottom (CSS's `box-decoration-break:
  /// clone`, as Typst's breakable blocks have their inset), rather than
  /// the first piece alone at its top and the last at its bottom.
  final bool cloneEdges;

  /// The space between a floating box set at the top or bottom of a
  /// region and the content (below it at the top, above it at the
  /// bottom: Typst's `clearance`).
  final double floatClearance;

  /// This style with [tag] ([BoxStyle.tag]).
  BoxStyle withTag(String? tag) => BoxStyle(
    margin: margin,
    padding: padding,
    border: border,
    background: background,
    keepTogether: keepTogether,
    keepWithNext: keepWithNext,
    anchor: anchor,
    marks: marks,
    decoration: decoration,
    tag: tag,
    float: float,
    floatBarrier: floatBarrier,
    verticalAlign: verticalAlign,
    cloneEdges: cloneEdges,
    floatClearance: floatClearance,
  );

  /// This style without floating.
  BoxStyle get _unfloated => BoxStyle(
    margin: margin,
    padding: padding,
    border: border,
    background: background,
    keepTogether: keepTogether,
    keepWithNext: keepWithNext,
    anchor: anchor,
    marks: marks,
    decoration: decoration,
    tag: tag,
    floatBarrier: floatBarrier,
    verticalAlign: verticalAlign,
    cloneEdges: cloneEdges,
    floatClearance: floatClearance,
  );

  /// This style with the room above the block as its top margin (where
  /// [verticalAlign] put it), kept together no more.
  BoxStyle _lowered(double room) => BoxStyle(
    margin: EdgeInsets(
      top: room,
      right: margin.right,
      bottom: margin.bottom,
      left: margin.left,
    ),
    padding: padding,
    border: border,
    background: background,
    keepWithNext: keepWithNext,
    anchor: anchor,
    marks: marks,
    decoration: decoration,
    tag: tag,
    float: float,
    floatBarrier: floatBarrier,
    cloneEdges: cloneEdges,
    floatClearance: floatClearance,
  );
}

/// Where a floating box goes when it fits in its region.
enum FloatPlacement {
  /// Where it is: it floats only when it doesn't fit (to the top of the
  /// next region).
  next,

  /// To the top of its region.
  top,

  /// To the bottom of its region (above its notes).
  bottom,

  /// To the top or the bottom of its region, whichever it is nearer.
  auto,
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
  /// [image] (raster or SVG) at [width] by [height], aligned by [align];
  /// [shrinkToFit]
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
  final Graphic image;

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

/// A side of a spread: recto pages are the odd-numbered ones (the
/// first page is a recto), verso pages the even-numbered ones.
enum PageSide {
  /// An odd-numbered page.
  recto,

  /// An even-numbered page.
  verso;

  /// The side of page [number] (1-based).
  static PageSide of(int number) => number.isOdd ? recto : verso;
}

/// A forced break.
final class BreakBox extends LayoutBox {
  /// A break to the next page, made from the template named [template]
  /// (the layout's choice when null); ignored at the top of a region
  /// unless [force]d (which leaves the region blank). With a [side], the
  /// content after the break starts on a page of that side, after a blank
  /// page when needed (and at the top of a page of the other side, that
  /// page stays blank).
  const new page({this.template, this.force = false, this.side})
    : kind = BreakKind.page,
      super._(const BoxStyle());

  /// A break to the next column, ignored at the top of a region unless
  /// [force]d.
  const new column({this.force = false})
    : kind = BreakKind.column,
      template = null,
      side = null,
      super._(const BoxStyle());

  /// The kind of break.
  final BreakKind kind;

  /// The template of the next page.
  final String? template;

  /// Whether the break is made even at the top of a region.
  final bool force;

  /// The side of the page the content after the break starts on.
  final PageSide? side;
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

/// Content that lays itself out: the layout gives it the width and the
/// height left, and it places as much as fits. Callers implement it to
/// reproduce another engine's text boxes exactly, with the box tree
/// still deciding pagination around them.
abstract interface class CustomContent {
  /// As much of the content as fits in [available] height at [width]
  /// (`rest` holds what is left), or null to move all of it to the next
  /// region. With [atTop] (nothing above it in the region), something
  /// must be placed.
  CustomPlacement? place(double width, double available, {required bool atTop});

  /// The least height the content needs where it starts (to keep a box
  /// with it).
  double minHeight(double width);

  /// The narrowest and widest the content can usefully be (for automatic
  /// table columns).
  (double, double) intrinsicWidths();
}

/// What placing custom content gave.
final class CustomPlacement {
  /// A piece [height] tall that [paint] draws with its top left at (x,
  /// top), with [anchors] at offsets from that corner; [rest] is what
  /// didn't fit.
  const new({
    required this.height,
    required this.paint,
    this.rest,
    this.anchors = const [],
  });

  /// The height of the piece.
  final double height;

  /// Paints the piece on `page` (through its canvas) at (`x`, `top`).
  final void Function(PdfPage page, double x, double top) paint;

  /// What didn't fit, or null.
  final CustomContent? rest;

  /// Names and offsets (right and down from the top left) of positions in
  /// the piece.
  final List<(String, double, double)> anchors;
}

/// A box of content that lays itself out (see [CustomContent]); its
/// style's margins apply.
final class CustomBox extends LayoutBox {
  /// A box of [content].
  const new(this.content, {BoxStyle style = const BoxStyle()})
    : _continued = false,
      super._(style);

  const new _rest(this.content, BoxStyle style)
    : _continued = true,
      super._(style);

  /// The content.
  final CustomContent content;

  final bool _continued;
}

/// How a cell's content sits in a row taller than it.
enum VerticalAlign {
  /// At the top.
  top,

  /// In the middle.
  middle,

  /// At the bottom.
  bottom,
}

/// A table cell: boxes, spanning columns and rows.
@immutable
final class TableCell {
  /// A cell of [content].
  const new(
    this.content, {
    this.colSpan = 1,
    this.rowSpan = 1,
    this.padding = const EdgeInsets.all(4),
    this.background,
    this.border = Border.none,
    this.verticalAlign = VerticalAlign.top,
    this.verticalOffset,
    this.decoration,
  }) : _openTop = false;

  new _rest(TableCell cell, this.content, this.rowSpan)
    : colSpan = cell.colSpan,
      padding = cell.padding,
      background = cell.background,
      border = cell.border,
      verticalAlign = cell.verticalAlign,
      verticalOffset = cell.verticalOffset,
      decoration = cell.decoration,
      _openTop = true;

  /// The content.
  final List<LayoutBox> content;

  /// The columns the cell spans.
  final int colSpan;

  /// The rows the cell spans.
  final int rowSpan;

  /// The space between the cell's edges and its content.
  final EdgeInsets padding;

  /// The fill.
  final PdfColor? background;

  /// The border, centered on the cell's edges.
  final Border border;

  /// Where the content sits.
  final VerticalAlign verticalAlign;

  /// How far below the top of the room inside the padding the content
  /// sits, given that room's height and the content's (in place of
  /// [verticalAlign]).
  final double Function(double room, double contentHeight)? verticalOffset;

  /// Paints the cell's border (in place of [border]), over the content,
  /// given the cell's rectangle and whether the piece is where the cell
  /// starts and ends.
  final BoxDecoration? decoration;

  /// Whether this is the rest of a cell split by a break.
  final bool _openTop;
}

/// A table row.
@immutable
final class TableRow {
  /// A row of [cells] (left to right, skipping columns that cells from
  /// rows above span), at least [minHeight] tall.
  const new(this.cells, {this.minHeight = 0});

  /// The cells.
  final List<TableCell> cells;

  /// The least height.
  final double minHeight;
}

/// The width of a table column.
@immutable
sealed class ColumnWidth {
  const new _();

  /// [points] wide.
  const factory fixed(double points) = FixedColumnWidth;

  /// A share of the width the fixed and auto columns leave, by [weight].
  const factory fraction(double weight) = FractionColumnWidth;

  /// As wide as the content wants, within what is available.
  const factory auto() = AutoColumnWidth;

  /// The width [width] gives for the table's width.
  const factory computed(double Function(double tableWidth) width) =
      ComputedColumnWidth;
}

/// A column of a fixed width.
final class FixedColumnWidth extends ColumnWidth {
  /// [points] wide.
  const new(this.points) : super._();

  /// The width.
  final double points;
}

/// A column sharing what is left.
final class FractionColumnWidth extends ColumnWidth {
  /// A share by [weight].
  const new(this.weight) : super._();

  /// The weight.
  final double weight;
}

/// A column as wide as its content.
final class AutoColumnWidth extends ColumnWidth {
  /// An auto column.
  const new() : super._();
}

/// A column whose width depends on the table's (a fixed column once the
/// table's width is known).
final class ComputedColumnWidth extends ColumnWidth {
  /// A column [width] wide for the table's width.
  const new(this.width) : super._();

  /// The width for the table's width.
  final double Function(double tableWidth) width;
}

/// A table: rows of cells in columns. Header rows repeat at the top of
/// each region the table continues in.
final class TableBox extends LayoutBox {
  /// A table of [rows] in [columns]; the first [headerRows] rows are the
  /// header. The table is [width] wide (the region's width when null; as
  /// narrow as its content allows with [shrinkToContent]).
  const new(
    this.rows, {
    required this.columns,
    this.headerRows = 0,
    this.width,
    this.shrinkToContent = false,
    this.align = BoxAlign.left,
    this.stripes = const [],
    BoxStyle style = const BoxStyle(),
  }) : _grid = null,
       _widths = null,
       super._(style);

  new _rest(TableBox table, this._grid, this._widths)
    : rows = table.rows,
      columns = table.columns,
      headerRows = table.headerRows,
      width = table.width,
      shrinkToContent = table.shrinkToContent,
      align = table.align,
      stripes = table.stripes,
      super._(table.style);

  /// The rows.
  final List<TableRow> rows;

  /// The columns' widths.
  final List<ColumnWidth> columns;

  /// The number of header rows.
  final int headerRows;

  /// The table's width.
  final double? width;

  /// Whether the table is as narrow as its content allows.
  final bool shrinkToContent;

  /// Its alignment when narrower than the region.
  final BoxAlign align;

  /// The backgrounds the body rows take in turn (cells without their own),
  /// counting from the first body row in each region.
  final List<PdfColor?> stripes;

  /// The rows left to place (with their cells' columns), when this is the
  /// rest of a split table.
  final List<_GridRow>? _grid;

  /// The columns' widths, fixed by the first piece.
  final List<double>? _widths;
}

/// A row with each cell's column.
final class _GridRow {
  const new(this.cells, this.minHeight, {this.header = false});

  final List<(int, TableCell)> cells;
  final double minHeight;
  final bool header;
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
  new _(
    this.number,
    this.count,
    this.label,
    this._marks,
    this.template,
    this._topMarks, {
    this.isEmpty = false,
  });

  /// The template of the page.
  final PageTemplate template;

  /// The page number (1-based).
  final int number;

  /// The number of pages.
  final int count;

  /// The page's label (its number as the layout writes it).
  final String label;

  final Map<String, String> _marks;

  /// Whether nothing was laid out on the page (a blank page before a
  /// recto or verso start, say).
  final bool isEmpty;

  /// The value of the running mark [name] on this page: the first one set
  /// on the page, or else the last one set before it.
  String? mark(String name) => _marks[name];

  final Map<String, String> _topMarks;

  /// The value of the running mark [name] at the top of this page: the last
  /// one set before it (what a header set at the page's top sees, as
  /// Typst's headers do).
  String? topMark(String name) => _topMarks[name];
}

/// The pages content is laid out on.
@immutable
final class PageTemplate {
  /// Pages of [size] whose content area is inside [margins], in
  /// [columns] columns [columnGap] apart; [header] and [footer] give the
  /// boxes of the top and bottom margins, [background] paints under the
  /// content and [foreground] over everything.
  const new(
    this.size, {
    this.margins = const EdgeInsets.all(72),
    this.columns = 1,
    this.columnGap = 12,
    this.header,
    this.footer,
    this.background,
    this.foreground,
    this.bleed,
  });

  /// The page size.
  final PdfRect size;

  /// How far the sheet runs past [size] on every side, for content that
  /// is trimmed off in print: with a bleed (0 included), [size] is the
  /// `TrimBox` and the sheet (`MediaBox`, `BleedBox`) is [size] grown by
  /// it; without one (null), the page has no print boxes. Layout is on
  /// [size].
  final double? bleed;

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

  /// Paints over a page's content and its header and footer.
  final void Function(PdfCanvas canvas, PageInfo page)? foreground;

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
    this.startTemplate,
    this.keepTemplate = false,
    this.templateForPage,
    this.notes = const {},
    this.noteSeparator,
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

  /// The name of the first page's template (the default when null).
  final String? startTemplate;

  /// Whether a page break's template stays in effect for the pages after
  /// it (until another break names one), rather than for the next page
  /// alone. A break naming another template at the top of a page that's
  /// still empty then replaces that page.
  final bool keepTemplate;

  /// The template of each page, from the page number (1-based) and the
  /// template the content calls for (for margins that differ between recto
  /// and verso pages, say); the one the content calls for when null.
  final PageTemplate Function(PageTemplate template, int number)?
  templateForPage;

  /// Notes by the anchor that refers to them (footnotes): a note is set
  /// at the bottom of the region its anchor is placed in, the region's
  /// content making room for it; what doesn't fit there goes on at the
  /// bottom of the next region.
  final Map<String, LayoutBox> notes;

  /// What is set above the notes of a region (a short rule, say).
  final LayoutBox? noteSeparator;

  static String _decimal(int number) => '$number';

  /// [content] laid out on pages.
  LayoutResult layout(
    List<LayoutBox> content, {
    LayoutResult? reuse,
    int unchangedBefore = 0,
    Set<int>? changedPages,
  }) {
    var anchors = <String, AnchorPosition>{};
    // Laid out again after a change at or after [unchangedBefore]: the
    // pages before the last clean boundary before it are kept, and the
    // first pass goes on from there.
    _Boundary? resumeAt;
    if (reuse != null && identical(reuse._layout, this)) {
      anchors = reuse.anchors;
      for (final boundary in reuse._boundaries) {
        if (boundary.index > unchangedBefore) break;
        if (boundary.index <= content.length && !boundary.hasReferences) {
          resumeAt = boundary;
        }
      }
    }
    late _Pass pass;
    for (var i = 0; i < maxPasses; i++) {
      pass = _Pass(this, anchors);
      if (i == 0 && resumeAt != null) {
        pass.resume(content, reuse!, resumeAt, changedPages);
      } else {
        pass.run(content);
      }
      final found = pass.anchors;
      final stable =
          found.length == anchors.length &&
          found.entries.every((e) => anchors[e.key]?.page == e.value.page);
      anchors = found;
      if (stable || !pass.hasReferences) break;
    }
    return LayoutResult._(
      this,
      pass.pages,
      anchors,
      pass.tagPages,
      pass.boundaries,
      pass.repeatedAnchors,
    );
  }
}

/// A point between two pages of a pass where nothing is pending (no
/// floating box, deferred note or carried piece) and the rest of the
/// content is the top-level boxes from [index] on: a pass may go on from
/// here as from the start.
final class _Boundary {
  const new({
    required this.index,
    required this.pages,
    required this.template,
    required this.notesSet,
    required this.floatsSet,
    required this.hasReferences,
  });

  /// The first top-level box after the boundary.
  final int index;

  /// The pages before it.
  final int pages;

  /// The template the next page takes.
  final String? template;

  /// The notes placed before it.
  final Set<String> notesSet;

  /// The floating boxes set at a region's edge before it.
  final Set<LayoutBox> floatsSet;

  /// Whether the content before it refers to pages.
  final bool hasReferences;

  /// Whether a pass at [other] goes on as one at this boundary does
  /// (neither referring to pages, whose numbers may have moved).
  bool sameAs(_Boundary other) =>
      index == other.index &&
      pages == other.pages &&
      template == other.template &&
      !hasReferences &&
      !other.hasReferences &&
      notesSet.length == other.notesSet.length &&
      notesSet.containsAll(other.notesSet) &&
      floatsSet.length == other.floatsSet.length &&
      floatsSet.containsAll(other.floatsSet);
}

/// One layout of the content.
final class _Pass {
  new(this.layout, this.previous);

  final FlowLayout layout;

  /// The anchors of the previous pass (for page references).
  final Map<String, AnchorPosition> previous;

  final List<_Page> pages = [];
  final Map<String, AnchorPosition> anchors = {};

  /// The first and last page (1-based) of each tagged box.
  final Map<String, ({int first, int last})> tagPages = {};
  final Map<(ParagraphBox, double), List<Line>> _lines = {};
  bool hasReferences = false;
  final List<_Boundary> boundaries = [];

  /// The pages (0-based) of the anchors placed more than once, after the
  /// first.
  final Map<String, List<int>> repeatedAnchors = {};

  /// The layout this pass goes on from, and the pages of it that change
  /// (null: all after where it goes on).
  LayoutResult? _reuse;
  Set<int>? _changedPages;

  /// The boundaries of [_reuse] by their box.
  Map<int, (int, _Boundary)> _reuseBoundaries = const {};

  /// The pages taken from [_reuse] (their marks are in them already).
  final Set<int> _kept = {};

  /// Lays [content] out from [boundary] of [reuse] (of the same content
  /// up to it): its pages before the boundary, then the rest, taking its
  /// pages again from a later boundary on when the pass comes to it as
  /// [reuse] did and none of them is in [changedPages].
  void resume(
    List<LayoutBox> content,
    LayoutResult reuse,
    _Boundary boundary,
    Set<int>? changedPages,
  ) {
    _reuse = reuse;
    _changedPages = changedPages;
    if (changedPages != null) {
      _reuseBoundaries = {
        for (final (i, b) in reuse._boundaries.indexed) b.index: (i, b),
      };
    }
    pages.addAll(reuse._pages.take(boundary.pages));
    _kept.addAll(Iterable.generate(boundary.pages));
    _notesSet.addAll(boundary.notesSet);
    _floatsSet.addAll(boundary.floatsSet);
    hasReferences = boundary.hasReferences;
    boundaries.addAll(
      reuse._boundaries.takeWhile((b) => b.index <= boundary.index),
    );
    run(content, from: boundary);
  }

  /// A page of the template named [name], as the page after [pages].
  _Page _newPage(String? name) {
    final template = layout.templates[name] ?? layout.templates[null]!;
    return _Page(
      layout.templateForPage?.call(template, pages.length + 1) ?? template,
    );
  }

  /// Adds [page], with what [carried] holds placed at its top.
  void _add(_Page page, List<_Placed> carried) {
    if (carried.isNotEmpty) {
      final region = page.template.regions.first;
      page.placed.insertAll(0, [
        for (final placed in carried) (region, placed),
      ]);
      carried.clear();
    }
    pages.add(page);
  }

  void run(List<LayoutBox> content, {_Boundary? from}) {
    LayoutBox? rest = from == null
        ? BlockBox(content)
        : from.index < content.length
        ? BlockBox._rest(content.sublist(from.index), const BoxStyle())
        : null;
    var template = from == null ? layout.startTemplate : from.template;
    var guard = 0;
    // What was placed on a page that was replaced (anchors, marks: it had
    // no height), carried to the page replacing it.
    final carried = <_Placed>[];
    // Notes deferred past the end of the content go on on pages of their
    // own.
    // Floating boxes that didn't fit, for the top of the next region.
    final floats = <LayoutBox>[];
    while (rest != null || _deferredNotes != null || floats.isNotEmpty) {
      final page = _newPage(template);
      if (!layout.keepTemplate) template = null;
      var discard = false;
      PageSide? side;
      for (final (i, region) in page.template.regions.indexed) {
        _regionHeight = region.height;
        // Floating boxes that waited: at the top of the region, those for
        // the bottom at its bottom.
        final waitingBottom = [
          for (final float in floats)
            if (float.style.float == FloatPlacement.bottom)
              ..._cleared(float, top: false),
        ];
        // (The others at the top, the content starting below them as at
        // the region's top.)
        var waitingTop = [
          for (final float in floats)
            if (float.style.float != FloatPlacement.bottom)
              ..._cleared(float, top: true),
        ];
        final restBox = rest ?? const BlockBox([]);
        // A break the floating boxes waited before: after them, in the
        // flow.
        bool startsWithBreak(LayoutBox box) => switch (box) {
          BreakBox() => true,
          BlockBox(:final children) when children.isNotEmpty => startsWithBreak(
            children.first,
          ),
          _ => false,
        };
        final breakFirst = waitingTop.isNotEmpty && startsWithBreak(restBox);
        final content = breakFirst
            ? BlockBox([...waitingTop, restBox])
            : restBox;
        if (breakFirst) waitingTop = const [];
        floats.clear();
        _floatsWaiting = 0;
        _floatsNotHere.clear();
        final reserved =
            (waitingBottom.isEmpty
                ? 0.0
                : _measure(BlockBox(waitingBottom), region.width)) +
            (waitingTop.isEmpty
                ? 0.0
                : _place(
                    BlockBox(waitingTop),
                    region.width,
                    double.infinity,
                    atTop: true,
                  ).height);
        var fit = _place(
          content,
          region.width,
          region.height - reserved,
          atTop: true,
        );
        // Floating boxes that fit, at the top or the bottom of the region:
        // the content in what the top ones leave.
        final top = <LayoutBox>[...waitingTop];
        final bottom = <LayoutBox>[...waitingBottom];
        if (fit.pinned.isNotEmpty) {
          fit = _pinFloats(content, region, fit, top, bottom);
        }
        final topFit = top.isEmpty
            ? null
            : _place(BlockBox(top), region.width, region.height, atTop: true);
        final topHeight = topFit?.height ?? 0.0;
        final area = topHeight == 0
            ? region
            : PdfRect(
                region.left,
                region.bottom,
                region.width,
                region.height - topHeight,
              );
        if (topFit != null) {
          page.placed.add((
            PdfRect(
              region.left,
              region.bottom + area.height,
              region.width,
              topHeight,
            ),
            topFit.placed,
          ));
        }
        if (layout.notes.isNotEmpty ||
            _deferredNotes != null ||
            bottom.isNotEmpty) {
          final (withNotes, notes) = _notes(content, area, fit, bottom: bottom);
          fit = withNotes;
          page.placed.add((area, fit.placed));
          if (notes != null) {
            page.placed.add((
              PdfRect(area.left, area.bottom, area.width, notes.height),
              notes.placed,
            ));
          }
        } else {
          page.placed.add((area, fit.placed));
        }
        rest = fit.rest;
        floats.addAll(fit.floated);
        if (rest == null && _deferredNotes == null && floats.isEmpty) break;
        if (fit.hit case BreakBox(
          kind: BreakKind.page,
          template: final name,
          side: final wanted,
        )) {
          side = wanted;
          if (name != null || !layout.keepTemplate) template = name;
          // A break to another template on a page still empty replaces it.
          discard =
              layout.keepTemplate &&
              name != null &&
              i == 0 &&
              (fit.placed?.height ?? 0) == 0;
          break;
        }
      }
      if (discard) {
        carried.addAll([for (final (_, placed) in page.placed) ?placed]);
      } else {
        _add(page, carried);
      }
      // A break to a side: a blank page first when the next page is on
      // the other side.
      if (side != null && PageSide.of(pages.length + 1) != side) {
        _add(_newPage(template), carried);
      }
      // A clean boundary: the rest is the top-level boxes from one on,
      // nothing pending.
      if (carried.isEmpty && floats.isEmpty && _deferredNotes == null) {
        if (rest case BlockBox(:final children, _continued: true)
            when children.isNotEmpty &&
                children.length < content.length &&
                identical(
                  children.first,
                  content[content.length - children.length],
                )) {
          var boundary = _Boundary(
            index: content.length - children.length,
            pages: pages.length,
            template: template,
            notesSet: {..._notesSet},
            floatsSet: Set.identity()..addAll(_floatsSet),
            hasReferences: hasReferences,
          );
          boundaries.add(boundary);
          // The pages of the layout gone on from, up to its next
          // boundary, when this one is the same as its and none of them
          // changes.
          while (true) {
            final (i, old) = _reuseBoundaries[boundary.index] ?? (-1, null);
            if (old == null || !old.sameAs(boundary)) break;
            final reuse = _reuse!;
            final next = i + 1 < reuse._boundaries.length
                ? reuse._boundaries[i + 1]
                : null;
            final end = next?.pages ?? reuse._pages.length;
            if (_changedPages!.any((p) => p >= old.pages && p < end)) break;
            for (final page in reuse._pages.sublist(old.pages, end)) {
              _kept.add(pages.length);
              pages.add(page);
            }
            if (next == null) {
              rest = null;
              break;
            }
            rest = BlockBox._rest(
              content.sublist(next.index),
              const BoxStyle(),
            );
            template = next.template;
            _notesSet
              ..clear()
              ..addAll(next.notesSet);
            _floatsSet
              ..clear()
              ..addAll(next.floatsSet);
            boundaries.add(boundary = next);
          }
        }
      }
      if (++guard > 100000) throw StateError('layout does not progress');
    }
    // A last page with nothing on it (after a trailing page break) is left
    // out.
    if (pages.length > 1 &&
        pages.last.placed.every((p) => (p.$2?.height ?? 0) == 0)) {
      pages.removeLast();
    }
    for (final (i, page) in pages.indexed) {
      final kept = _kept.contains(i);
      for (final (region, placed) in page.placed) {
        placed?.visit(
          region.left,
          region.top,
          (anchor, x, y) {
            if (anchors.containsKey(anchor)) {
              (repeatedAnchors[anchor] ??= []).add(i);
            } else {
              anchors[anchor] = AnchorPosition(i, x, y);
            }
          },
          // (Pages kept from another pass have their marks.)
          kept ? (_) {} : page.marks.add,
          (tag) {
            final first = tagPages[tag]?.first ?? i + 1;
            tagPages[tag] = (first: first, last: i + 1);
          },
        );
      }
    }
  }

  /// The notes whose anchors were placed (each set once).
  final Set<String> _notesSet = {};

  /// The notes that didn't fit in the region before.
  LayoutBox? _deferredNotes;

  /// The anchors [placed] reports, in order.
  static List<String> _anchorsOf(_Placed? placed) {
    final names = <String>[];
    placed?.visit(0, 0, (name, _, _) => names.add(name), (_) {}, (_) {});
    return names;
  }

  /// [first] (the placing of [content] in [region]) with room made for the
  /// notes its anchors refer to, and the notes placed at the bottom: the
  /// content placed again in less height until its notes fit below it.
  /// Notes that don't fit are deferred to the next region.
  (_Fit, _Fit?) _notes(
    LayoutBox content,
    PdfRect region,
    _Fit first, {
    List<LayoutBox> bottom = const [],
  }) {
    final width = region.width;
    var fit = first;
    final deferred = _deferredNotes;
    List<LayoutBox> pending(_Fit fit) => [
      ?deferred,
      for (final name in _anchorsOf(fit.placed))
        if (!_notesSet.contains(name)) ?layout.notes[name],
    ];
    // The bottom of the region: its floating boxes, then its notes under
    // the separator.
    List<LayoutBox> area(List<LayoutBox> notes) => [
      ...bottom,
      if (notes.isNotEmpty) ?layout.noteSeparator,
      ...notes,
    ];
    var notes = pending(fit);
    // Each try leaves the content less room, so it places no more (and
    // so no more notes) than the try before: it ends.
    for (var attempt = 0; notes.isNotEmpty || bottom.isNotEmpty; attempt++) {
      final box = BlockBox(area(notes));
      final height = _measure(box, width);
      if (fit.height + height <= region.height + 1e-6 || attempt == 4) {
        break;
      }
      final room = region.height - height;
      // Notes taller than most of the region: as many as fit under what
      // is placed, the rest on the next region.
      if (room < region.height / 4) break;
      _floatsWaiting = 0;
      fit = _place(content, width, room, atTop: true);
      notes = pending(fit);
    }
    for (final name in _anchorsOf(fit.placed)) {
      if (layout.notes.containsKey(name)) _notesSet.add(name);
    }
    _deferredNotes = null;
    if (notes.isEmpty && bottom.isEmpty) return (fit, null);
    final room = region.height - fit.height;
    final placed = _place(BlockBox(area(notes)), width, room, atTop: false);
    if (placed.placed == null || placed.height == 0) {
      // No note fits: all of them on the next region, without a
      // separator; the floating boxes stay, as they were measured to.
      _deferredNotes = notes.isEmpty ? null : BlockBox(notes);
      if (bottom.isEmpty) return (fit, null);
      return (
        fit,
        _place(BlockBox(bottom), width, double.infinity, atTop: false),
      );
    }
    _deferredNotes = placed.rest;
    return (fit, placed);
  }

  /// [first] (the placing of [content] in [region]) with the floating
  /// boxes it placed that fit taken out of the flow, for the top of the
  /// region ([top]) or its bottom ([bottom]): the content placed again in
  /// the height they leave.
  _Fit _pinFloats(
    LayoutBox content,
    PdfRect region,
    _Fit first,
    List<LayoutBox> top,
    List<LayoutBox> bottom,
  ) {
    var fit = first;
    // The floating boxes pinned here, with what each added to its edge.
    final pinned = <LayoutBox, List<LayoutBox>>{};
    double measured(List<LayoutBox> boxes) =>
        boxes.isEmpty ? 0 : _measure(BlockBox(boxes), region.width);
    void place() {
      _floatsWaiting = 0;
      _floatsReached.clear();
      fit = _place(
        content,
        region.width,
        region.height - measured(top) - measured(bottom),
        atTop: true,
      );
    }

    for (var attempt = 0; attempt < 4 && fit.pinned.isNotEmpty; attempt++) {
      var added = false;
      for (final (box, y, height) in fit.pinned) {
        if (!_floatsSet.add(box)) continue;
        added = true;
        // (Auto: at the top if its middle, placed in the flow, would be
        // in the region's upper half, the floats placed already taking
        // their room, as Typst's.)
        final atTop = switch (box.style.float) {
          FloatPlacement.top => true,
          FloatPlacement.bottom => false,
          _ =>
            measured(top) + measured(bottom) + y + height / 2 <=
                region.height / 2,
        };
        final cleared = _cleared(box, top: atTop);
        (atTop ? top : bottom).addAll(cleared);
        pinned[box] = cleared;
      }
      if (!added) break;
      place();
      // A box the content no longer reaches in the room left (the text
      // before it now goes on in the next region): it waits for the next
      // region, as Typst places a float only where its text is.
      final unreached = [
        for (final box in pinned.keys)
          if (!_floatsReached.contains(box)) box,
      ];
      if (unreached.isNotEmpty) {
        for (final box in unreached) {
          for (final piece in pinned.remove(box)!) {
            top.remove(piece);
            bottom.remove(piece);
          }
          _floatsSet.remove(box);
          _floatsNotHere.add(box);
        }
        place();
      }
    }
    return fit;
  }

  /// The label of the page of [anchor] from the previous pass.
  String? _pageOf(String anchor) => switch (previous[anchor]) {
    AnchorPosition(:final page) => layout.pageLabel(page + 1),
    null => null,
  };

  List<Line> _linesOf(ParagraphBox box, double width) {
    final source = box._source ?? box;
    return _lines[(source, width)] ??= () {
      return (source.lineBreaker ?? layout.lineBreaker).breakLines(
        _resolve(source.paragraph),
        (_) => width,
      );
    }();
  }

  /// [paragraph] with its page references filled in.
  Paragraph _resolve(Paragraph paragraph) {
    if (!paragraph.content.any((c) => c is PageReference)) return paragraph;
    hasReferences = true;
    return Paragraph(
      [
        for (final c in paragraph.content)
          if (c case PageReference(:final anchor, :final placeholder))
            c.resolve(_pageOf(anchor) ?? placeholder)
          else
            c,
      ],
      align: paragraph.align,
      lineHeight: paragraph.lineHeight,
      firstLineIndent: paragraph.firstLineIndent,
      hyphenator: paragraph.hyphenator,
      breakLongWords: paragraph.breakLongWords,
    );
  }

  /// The space the last of [children] leaves below the content: its
  /// margin below (and, through a block with nothing closing it, its own
  /// last child's), or a spacer's height.
  double _trailingSpace(List<LayoutBox> children) {
    if (children.isEmpty) return 0;
    final last = children.last;
    return switch (last) {
      SpacerBox(:final height) =>
        height + _trailingSpace(children.sublist(0, children.length - 1)),
      BlockBox(:final children, :final style)
          when style.padding.bottom == 0 && style.border.widths.bottom == 0 =>
        style.margin.bottom + _trailingSpace(children),
      _ => last.style.margin.bottom,
    };
  }

  /// The height of [box] laid out with no limit.
  double _measure(LayoutBox box, double width) =>
      _place(box, width, double.infinity, atTop: false).height;

  /// The least height [box] needs where it starts (to keep a box with
  /// it).
  double _minHeight(LayoutBox box, double width) {
    final margin = box.style.margin;
    // A block kept together starts whole, when a region holds it.
    if (box is BlockBox && box.style.keepTogether) {
      final whole = _measure(box, width);
      if (whole <= _regionHeight + 1e-6) return whole;
    }
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
      // A table splits after its first row (its header repeated): that
      // much of it, unless it is kept together.
      case TableBox(:final rows, :final headerRows)
          when box._grid == null &&
              !box.style.keepTogether &&
              rows.length > headerRows + 1:
        return _measure(
          TableBox(
            rows.sublist(0, headerRows + 1),
            columns: box.columns,
            headerRows: headerRows,
            width: box.width,
            shrinkToContent: box.shrinkToContent,
            align: box.align,
            stripes: box.stripes,
            style: box.style,
          ),
          width,
        );
      case ImageBox() || DrawingBox() || TableBox():
        return _measure(box, width);
      case CustomBox(:final content):
        return margin.top + content.minHeight(width - margin.horizontal);
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
    // Nothing floats out of a framed block (padded, bordered, filled or
    // decorated): it stays in its frame.
    BlockBox(:final style)
        when style.padding != EdgeInsets.zero ||
            style.border != Border.none ||
            style.background != null ||
            style.decoration != null =>
      _withoutFloats(() => _block(box, width, available, atTop: atTop)),
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
    ColumnsBox() => _withoutFloats(
      () => _columns(box, width, available, atTop: atTop),
    ),
    TableBox() => _withoutFloats(
      () => _table(box, width, available, atTop: atTop),
    ),
    CustomBox() => _custom(box, width, available, atTop: atTop),
  };

  _Fit _block(
    BlockBox box,
    double width,
    double available, {
    required bool atTop,
  }) {
    final style = box.style;
    final continued = box._continued;
    final clone = style.cloneEdges;
    final top =
        (atTop || continued ? 0.0 : style.margin.top) +
        (continued && !clone ? 0 : style.border.widths.top + style.padding.top);
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
    // A block aligned in the room of its region: the room above it as its
    // top margin, when it fits whole.
    if (style.verticalAlign case final align?
        when align != VerticalAlign.top &&
            atTop &&
            !continued &&
            available.isFinite) {
      // (Its margin below is outside it, and the space its last child
      // leaves below, as Typst drops the spacing at a container's end.)
      final whole =
          _measure(BlockBox(box.children, style: style._lowered(0)), width) -
          style.margin.bottom -
          _trailingSpace(box.children);
      if (whole < available) {
        final room =
            (available - whole) * (align == VerticalAlign.middle ? .5 : 1);
        return _block(
          BlockBox(box.children, style: style._lowered(room)),
          width,
          available,
          atTop: false,
        );
      }
    }
    // The bottom padding and border close the block: a page break inside
    // it reserves no room for them, they need room only below its last
    // child (if they don't fit there, the block is placed again with room
    // for them throughout).
    // (A block whose pieces each close reserves the room throughout.)
    final full = available - top - (clone ? bottom : 0);
    final fit = _blockChildren(
      box,
      width,
      inner,
      full,
      top,
      atTop: atTop,
      reserved: clone,
    );
    if (!clone &&
        fit.rest == null &&
        fit.hit == null &&
        bottom > 0 &&
        fit.height - style.margin.bottom > available + 1e-6) {
      return _blockChildren(
        box,
        width,
        inner,
        full - bottom,
        top,
        atTop: atTop,
        reserved: true,
      );
    }
    return fit;
  }

  /// [box]'s children placed in [room] below [top]: the block split where
  /// they don't fit, else the whole block.
  _Fit _blockChildren(
    BlockBox box,
    double width,
    double inner,
    double room,
    double top, {
    required bool atTop,
    bool reserved = false,
  }) {
    final style = box.style;
    final continued = box._continued;
    final bottom = style.padding.bottom + style.border.widths.bottom;
    final children = <(double, _Placed)>[];
    final floated = <LayoutBox>[];
    final pinned = <(LayoutBox, double, double)>[];
    var cursor = 0.0;
    var trailing = 0.0;
    final atTopInside = atTop && top == 0;
    _Fit split(List<LayoutBox> rest, {BreakBox? hit}) {
      if (children.isEmpty &&
          floated.isEmpty &&
          rest.length == box.children.length &&
          !atTop) {
        return _Fit.moved(box);
      }
      // (The space below the last piece placed doesn't carry to the
      // region's end: a piece with its own bottom edge closes right
      // under it.)
      final placed = _PlacedBlock(
        style,
        width,
        top +
            cursor -
            (style.cloneEdges ? trailing : 0) +
            (style.cloneEdges ? bottom : 0),
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
        // A box that ends with a break ends there: nothing of it (not
        // its bottom margin) is carried past the break.
        rest.isEmpty ? null : BlockBox._rest(rest, style),
        hit: hit,
        floated: floated,
        pinned: pinned,
      );
    }

    for (var i = 0; i < box.children.length; i++) {
      final child = box.children[i];
      // A floating box set at the top or bottom of a region already.
      if (_floatsSet.contains(child)) {
        _floatsReached.add(child);
        continue;
      }
      final childAtTop = atTopInside && cursor == 0;
      if (child is BreakBox) {
        // With floating boxes waiting, the break comes after them: the
        // region ends here, the break left for after them.
        if (floated.isNotEmpty || _floatsWaiting > 0) {
          return split(box.children.sublist(i));
        }
        // A break at the top of a region: none, unless forced (or a break
        // to a template, which replaces an empty page).
        if (childAtTop &&
            !child.force &&
            (child.template == null || !layout.keepTemplate) &&
            (child.side == null ||
                PageSide.of(pages.length + 1) == child.side)) {
          continue;
        }
        final rest = box.children.sublist(i + 1);
        return split(rest, hit: child);
      }
      // A box no floating box may pass: after them, in the next region.
      if (child.style.floatBarrier &&
          !childAtTop &&
          (floated.isNotEmpty || _floatsWaiting > 0)) {
        return split(box.children.sublist(i));
      }
      // A floating box this region's text no longer reaches (see
      // [_pinFloats]): for the next region.
      if (_floatsNotHere.contains(child) && _floatDepth == 0) {
        floated.add(child);
        _floatsWaiting++;
        continue;
      }
      final fit = _place(child, inner, room - cursor, atTop: childAtTop);
      if (fit.placed == null &&
          child.style.floating &&
          !childAtTop &&
          _floatDepth == 0) {
        floated.add(child);
        _floatsWaiting++;
        continue;
      }
      if (fit.placed == null) {
        return split(box.children.sublist(i));
      }
      floated.addAll(fit.floated);
      for (final (pin, y, height) in fit.pinned) {
        pinned.add((pin, top + cursor + y, height));
      }
      // A floating box that fits: for the top or bottom of the region.
      if (child.style.float case final float?
          when float != FloatPlacement.next &&
              fit.rest == null &&
              !childAtTop &&
              _floatDepth == 0 &&
              (child is BlockBox || child is CustomBox)) {
        pinned.add((child, top + cursor, fit.height));
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
      // The space below what was just placed (a spacer, a box's margin).
      trailing = switch (child) {
        SpacerBox() => fit.height,
        _ when fit.rest == null => math.min(
          child.style.margin.bottom,
          fit.height,
        ),
        _ => 0.0,
      };
      if (fit.rest != null || fit.hit != null) {
        return split([?fit.rest, ...box.children.sublist(i + 1)], hit: fit.hit);
      }
    }
    // Its margin below no more than the room left (a region's end takes
    // what doesn't fit of it).
    final marginBottom = math.min<double>(
      style.margin.bottom,
      // ([room] has the bottom edge's room taken out when [reserved].)
      math.max<double>(0, room + (reserved ? bottom : 0) - cursor - bottom),
    );
    final placed = _PlacedBlock(
      style,
      width,
      top + cursor + bottom + marginBottom,
      children,
      top: atTop || continued ? 0 : style.margin.top,
      openTop: continued,
      openBottom: false,
      marks: continued ? const {} : style.marks,
      anchor: continued ? null : style.anchor,
      marginBottom: marginBottom,
    );
    return _Fit(placed, placed.height, null, floated: floated, pinned: pinned);
  }

  /// The floating boxes set at the top or bottom of a region (their place
  /// in the flow is skipped).
  final Set<LayoutBox> _floatsSet = Set.identity();

  /// [box] set at the [top] or bottom of a region: not floating, its
  /// clearance ([BoxStyle.floatClearance]) on the content's side.
  static List<LayoutBox> _cleared(LayoutBox box, {required bool top}) {
    final clearance = box.style.floatClearance;
    if (clearance <= 0) return [_unfloated(box)];
    return top
        ? [_unfloated(box), SpacerBox(clearance)]
        : [SpacerBox(clearance), _unfloated(box)];
  }

  /// [box] (a floating block or custom box) as it is set at the top or
  /// bottom of a region: not floating.
  static LayoutBox _unfloated(LayoutBox box) => switch (box) {
    BlockBox(:final children, :final style) => BlockBox(
      children,
      style: style._unfloated,
    ),
    CustomBox(:final content, :final style) => CustomBox(
      content,
      style: style._unfloated,
    ),
    _ => box,
  };

  /// How many floating boxes wait for the next region in the placing
  /// under way (for float barriers).
  int _floatsWaiting = 0;

  /// The floating boxes set at a region's edge that the last placing of
  /// the content came to (passed over in the flow).
  final Set<LayoutBox> _floatsReached = Set.identity();

  /// The floating boxes that wait for the next region: the text before
  /// them goes on there.
  final Set<LayoutBox> _floatsNotHere = Set.identity();

  /// How deep the placing is in columns or tables, where boxes don't
  /// float.
  int _floatDepth = 0;

  /// [place] with boxes not floating.
  _Fit _withoutFloats(_Fit Function() place) {
    _floatDepth++;
    try {
      return place();
    } finally {
      _floatDepth--;
    }
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
        box.style.tag,
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

  /// The narrowest and the widest [box] can usefully be laid out.
  (double, double) _intrinsic(LayoutBox box) {
    final margin = box.style.margin.horizontal;
    switch (box) {
      case ParagraphBox(:final paragraph):
        var least = 0.0;
        var most = 0.0;
        var word = 0.0;
        var line = 0.0;
        for (final item in paragraphItems(_resolve(paragraph))) {
          switch (item) {
            case BoxItem(:final width):
              word += width;
              line += width;
            case GlueItem(:final width):
              least = math.max(least, word);
              word = 0;
              line += width;
            case PenaltyItem(:final isForced):
              least = math.max(least, word);
              word = 0;
              if (isForced) {
                most = math.max(most, line);
                line = 0;
              }
          }
        }
        final indent = paragraph.firstLineIndent;
        return (
          math.max(least, word) + margin + indent,
          math.max(most, line) + margin + indent,
        );
      case BlockBox(:final children):
        final insets =
            margin +
            box.style.border.widths.horizontal +
            box.style.padding.horizontal;
        var least = 0.0;
        var most = 0.0;
        for (final child in children) {
          final (a, b) = _intrinsic(child);
          least = math.max(least, a);
          most = math.max(most, b);
        }
        return (least + insets, most + insets);
      case ColumnsBox(:final children, :final count, :final gap):
        var least = 0.0;
        var most = 0.0;
        for (final child in children) {
          final (a, b) = _intrinsic(child);
          least = math.max(least, a);
          most = math.max(most, b);
        }
        final gaps = gap * (count - 1);
        return (least * count + gaps + margin, most * count + gaps + margin);
      case ImageBox(:final width):
        return (width + margin, width + margin);
      case DrawingBox(:final width):
        return ((width ?? 0) + margin, (width ?? 0) + margin);
      case SpacerBox() || BreakBox():
        return (0, 0);
      case CustomBox(:final content):
        final (a, b) = content.intrinsicWidths();
        return (a + margin, b + margin);
      case TableBox():
        final grid = box._grid ?? _gridOf(box);
        final (mins, maxs) = _columnRanges(box, grid);
        double sum(List<double> values) => values.fold(0, (a, b) => a + b);
        return (sum(mins) + margin, sum(maxs) + margin);
    }
  }

  /// The rows of [table] with each cell's column, as HTML places them:
  /// each cell in the first column not taken by a cell spanning down from
  /// above.
  List<_GridRow> _gridOf(TableBox table) {
    final n = table.columns.length;
    final busy = List<int>.filled(n, 0);
    final grid = <_GridRow>[];
    for (final (i, row) in table.rows.indexed) {
      final cells = <(int, TableCell)>[];
      final placed = List<int>.filled(n, 0);
      var col = 0;
      for (final cell in row.cells) {
        while (col < n && busy[col] > 0) {
          col++;
        }
        if (col >= n) break;
        final rowSpan = math.min(cell.rowSpan, table.rows.length - i);
        cells.add((
          col,
          rowSpan == cell.rowSpan ? cell : _withRowSpan(cell, rowSpan),
        ));
        for (var k = col; k < math.min(n, col + cell.colSpan); k++) {
          placed[k] = rowSpan;
        }
        col += cell.colSpan;
      }
      for (var k = 0; k < n; k++) {
        busy[k] = placed[k] > 0 ? placed[k] - 1 : math.max(0, busy[k] - 1);
      }
      grid.add(_GridRow(cells, row.minHeight, header: i < table.headerRows));
    }
    return grid;
  }

  static TableCell _withRowSpan(TableCell cell, int rowSpan) => TableCell(
    cell.content,
    colSpan: cell.colSpan,
    rowSpan: rowSpan,
    padding: cell.padding,
    background: cell.background,
    border: cell.border,
    verticalAlign: cell.verticalAlign,
  );

  /// Each column's narrowest and widest useful width.
  (List<double>, List<double>) _columnRanges(
    TableBox table,
    List<_GridRow> grid,
  ) {
    final n = table.columns.length;
    final mins = List<double>.filled(n, 0);
    final maxs = List<double>.filled(n, 0);
    final spanning = <(int, int, double, double)>[];
    for (final row in grid) {
      for (final (col, cell) in row.cells) {
        final (a, b) = _intrinsic(BlockBox(cell.content));
        final least = a + cell.padding.horizontal;
        final most = b + cell.padding.horizontal;
        final span = math.min(cell.colSpan, n - col);
        if (span == 1) {
          mins[col] = math.max(mins[col], least);
          maxs[col] = math.max(maxs[col], most);
        } else {
          spanning.add((col, span, least, most));
        }
      }
    }
    for (final (col, span, least, most) in spanning) {
      final columns = [for (var c = col; c < col + span; c++) c];
      final haveMin = columns.fold<double>(0, (s, c) => s + mins[c]);
      if (least > haveMin) {
        for (final c in columns) {
          mins[c] += (least - haveMin) / span;
        }
      }
      final haveMax = columns.fold<double>(0, (s, c) => s + maxs[c]);
      if (most > haveMax) {
        for (final c in columns) {
          maxs[c] += (most - haveMax) / span;
        }
      }
    }
    for (var c = 0; c < n; c++) {
      maxs[c] = math.max(maxs[c], mins[c]);
    }
    return (mins, maxs);
  }

  /// The columns' widths in [available]: fixed columns as given, auto
  /// columns from their content (as CSS's automatic table layout shares
  /// space), fraction columns sharing what is left.
  List<double> _columnWidths(
    TableBox table,
    List<_GridRow> grid,
    double available,
  ) {
    final (mins, maxs) = _columnRanges(table, grid);
    final n = table.columns.length;
    final widths = List<double>.filled(n, 0);
    final autos = <int>[];
    final fractions = <int>[];
    var fixed = 0.0;
    final whole = table.width ?? available;
    for (final (c, column) in table.columns.indexed) {
      switch (column) {
        case FixedColumnWidth(:final points):
          widths[c] = points;
          fixed += points;
        case ComputedColumnWidth(:final width):
          widths[c] = math.max(0, width(whole));
          fixed += widths[c];
        case FractionColumnWidth():
          fractions.add(c);
        case AutoColumnWidth():
          autos.add(c);
      }
    }
    double sum(List<int> columns, List<double> values) =>
        columns.fold(0, (s, c) => s + values[c]);
    var total = whole;
    if (table.shrinkToContent && fractions.isEmpty) {
      total = math.min(total, fixed + sum(autos, maxs));
    }
    final rest = total - fixed;

    void spread(List<int> columns, double room, {required bool grow}) {
      final least = sum(columns, mins);
      final most = sum(columns, maxs);
      for (final c in columns) {
        if (most <= room) {
          widths[c] =
              maxs[c] +
              (grow
                  ? (room - most) *
                        (most > 0 ? maxs[c] / most : 1 / columns.length)
                  : 0);
        } else if (least <= room) {
          widths[c] =
              mins[c] +
              (room - least) *
                  (most > least ? (maxs[c] - mins[c]) / (most - least) : 0);
        } else {
          widths[c] = least > 0
              ? mins[c] * room / least
              : room / columns.length;
        }
      }
    }

    if (fractions.isEmpty) {
      spread(autos, rest, grow: true);
    } else {
      final room = math.max<double>(0, rest - sum(fractions, mins));
      spread(autos, math.min(room, sum(autos, maxs)), grow: false);
      final left = math.max<double>(0, rest - sum(autos, widths));
      final weights = fractions.fold<double>(
        0,
        (s, c) => s + (table.columns[c] as FractionColumnWidth).weight,
      );
      for (final c in fractions) {
        final weight = (table.columns[c] as FractionColumnWidth).weight;
        widths[c] = weights > 0 ? left * weight / weights : 0;
      }
    }
    return widths;
  }

  double _cellWidth(int col, TableCell cell, List<double> widths) {
    var width = 0.0;
    for (var c = col; c < math.min(widths.length, col + cell.colSpan); c++) {
      width += widths[c];
    }
    return width;
  }

  /// The heights of [rows] (cells spanning down add to the last row they
  /// span).
  List<double> _rowHeights(List<_GridRow> rows, List<double> widths) {
    final heights = [for (final row in rows) row.minHeight];
    final spans = <(int, int, double)>[];
    for (final (i, row) in rows.indexed) {
      for (final (col, cell) in row.cells) {
        final width = _cellWidth(col, cell, widths) - cell.padding.horizontal;
        final needs =
            _measure(BlockBox(cell.content), width) + cell.padding.vertical;
        final span = math.min(cell.rowSpan, rows.length - i);
        if (span == 1) {
          heights[i] = math.max(heights[i], needs);
        } else {
          spans.add((i, span, needs));
        }
      }
    }
    for (final (i, span, needs) in spans) {
      final have = heights
          .sublist(i, i + span)
          .fold<double>(0, (a, b) => a + b);
      if (needs > have) heights[i + span - 1] += needs - have;
    }
    return heights;
  }

  /// The last row of the group starting at [start]: rows joined by cells
  /// spanning down.
  int _groupEnd(List<_GridRow> rows, int start) {
    var end = start;
    for (var i = start; i <= end && i < rows.length; i++) {
      for (final (_, cell) in rows[i].cells) {
        end = math.max(end, math.min(rows.length - 1, i + cell.rowSpan - 1));
      }
    }
    return end;
  }

  _Fit _table(
    TableBox box,
    double width,
    double available, {
    required bool atTop,
  }) {
    final style = box.style;
    final continued = box._grid != null;
    if (style.keepTogether && !atTop && !continued && available.isFinite) {
      final whole = _measure(box, width);
      if (layout.pageBreaker.moveKeptBox(whole, available, _regionHeight)) {
        return _Fit.moved(box);
      }
    }
    final margin = style.margin;
    final top = atTop || continued ? 0.0 : margin.top;
    final room = width - margin.horizontal;
    final grid = box._grid ?? _gridOf(box);
    final widths = box._widths ?? _columnWidths(box, grid, room);
    final tableWidth = widths.fold<double>(0, (a, b) => a + b);
    final left =
        margin.left +
        switch (box.align) {
          BoxAlign.left => 0.0,
          BoxAlign.center => (room - tableWidth) / 2,
          BoxAlign.right => room - tableWidth,
        };
    final columnLeft = [
      for (var c = 0, x = left; c < widths.length; x += widths[c], c++) x,
    ];
    final cells = <_PlacedCell>[];
    final space = available - top;
    var used = 0.0;

    /// Places [cell] (at [col]) [height] tall at [y]; returns the rest of
    /// its content if it didn't all fit.
    LayoutBox? cellAt(
      int col,
      TableCell cell,
      double y,
      double height, {
      required bool openBottom,
      PdfColor? stripe,
    }) {
      final width = _cellWidth(col, cell, widths);
      final padding = cell.padding;
      final fit = _place(
        BlockBox(cell.content),
        width - padding.horizontal,
        height - padding.vertical,
        atTop: true,
      );
      cells.add(
        _PlacedCell(
          cell,
          columnLeft[col],
          y,
          width,
          height,
          fit.placed,
          fit.height,
          openBottom: openBottom || fit.rest != null,
          stripe: stripe,
        ),
      );
      return fit.rest;
    }

    // The body rows placed in this region, for the stripes.
    var stripeIndex = 0;
    PdfColor? nextStripe({required bool body}) {
      if (!body || box.stripes.isEmpty) return null;
      return box.stripes[stripeIndex++ % box.stripes.length];
    }

    void placeRows(
      List<_GridRow> rows,
      List<double> heights, {
      bool body = true,
    }) {
      var y = top + used;
      for (final (i, row) in rows.indexed) {
        final stripe = nextStripe(body: body);
        for (final (col, cell) in row.cells) {
          final span = math.min(cell.rowSpan, rows.length - i);
          final height = heights
              .sublist(i, i + span)
              .fold<double>(0, (a, b) => a + b);
          cellAt(col, cell, y, height, openBottom: false, stripe: stripe);
        }
        y += heights[i];
      }
      used += heights.fold<double>(0, (a, b) => a + b);
    }

    final headers = [
      for (final row in grid)
        if (row.header) row,
    ];
    final body = [
      for (final row in grid)
        if (!row.header) row,
    ];
    final headerHeights = _rowHeights(headers, widths);
    final headerHeight = headerHeights.fold<double>(0, (a, b) => a + b);
    if (headerHeight > space + 1e-6 && !atTop) return _Fit.moved(box);
    placeRows(headers, headerHeights, body: false);

    List<_GridRow>? rest;
    var placedBody = 0;
    var i = 0;
    while (i < body.length) {
      final end = _groupEnd(body, i);
      final group = body.sublist(i, end + 1);
      final heights = _rowHeights(group, widths);
      final groupHeight = heights.fold<double>(0, (a, b) => a + b);
      if (used + groupHeight <= space + 1e-6) {
        placeRows(group, heights);
        placedBody += group.length;
        i = end + 1;
        continue;
      }
      if (placedBody > 0) {
        rest = body.sublist(i);
        break;
      }
      if (!atTop) return _Fit.moved(box);
      // At the top of a region and still too tall: split the group.
      final room = space - used;
      var fitting = 0;
      var fittingHeight = 0.0;
      while (fitting < group.length &&
          fittingHeight + heights[fitting] <= room + 1e-6) {
        fittingHeight += heights[fitting];
        fitting++;
      }
      final restRows = <_GridRow>[];
      if (fitting > 0) {
        final carried = <(int, TableCell)>[];
        var y = top + used;
        for (var r = 0; r < fitting; r++) {
          final stripe = nextStripe(body: true);
          for (final (col, cell) in group[r].cells) {
            final span = math.min(cell.rowSpan, group.length - r);
            if (r + span <= fitting) {
              final height = heights
                  .sublist(r, r + span)
                  .fold<double>(0, (a, b) => a + b);
              cellAt(col, cell, y, height, openBottom: false, stripe: stripe);
            } else {
              final height = heights
                  .sublist(r, fitting)
                  .fold<double>(0, (a, b) => a + b);
              final left = cellAt(
                col,
                cell,
                y,
                height,
                openBottom: true,
                stripe: stripe,
              );
              carried.add((
                col,
                TableCell._rest(cell, [?left], r + span - fitting),
              ));
            }
          }
          y += heights[r];
        }
        used += fittingHeight;
        final next = group[fitting];
        restRows
          ..add(
            _GridRow(
              [...next.cells, ...carried]..sort((a, b) => a.$1 - b.$1),
              next.minHeight,
            ),
          )
          ..addAll(group.sublist(fitting + 1));
      } else {
        // Not even one row fits: split the first row's cells.
        final row = group.first;
        final carried = <(int, TableCell)>[];
        final stripe = nextStripe(body: true);
        for (final (col, cell) in row.cells) {
          final span = math.min(cell.rowSpan, group.length);
          final left = cellAt(
            col,
            cell,
            top + used,
            room,
            openBottom: true,
            stripe: stripe,
          );
          carried.add((col, TableCell._rest(cell, [?left], span)));
        }
        used += room;
        restRows
          ..add(_GridRow(carried, 0))
          ..addAll(group.sublist(1));
      }
      rest = [...restRows, ...body.sublist(end + 1)];
      break;
    }
    final height = top + used + (rest == null ? margin.bottom : 0);
    return _Fit(
      _PlacedTable(
        cells,
        height,
        rest == null ? style.anchor : null,
        style.tag,
      ),
      height,
      rest == null ? null : TableBox._rest(box, [...headers, ...rest], widths),
    );
  }

  _Fit _custom(
    CustomBox box,
    double width,
    double available, {
    required bool atTop,
  }) {
    final style = box.style;
    final margin = style.margin;
    final top = atTop || box._continued ? 0.0 : margin.top;
    final placement = box.content.place(
      width - margin.horizontal,
      available - top,
      atTop: atTop,
    );
    if (placement == null) return _Fit.moved(box);
    final rest = placement.rest;
    // Its margin below no more than the room left (a region's end takes
    // what doesn't fit of it).
    final height =
        top +
        placement.height +
        (rest == null
            ? math.min(
                margin.bottom,
                math.max(0.0, available - top - placement.height),
              )
            : 0);
    return _Fit(
      _PlacedCustom(
        placement,
        margin.left,
        top,
        height,
        box._continued ? null : style.anchor,
        box._continued ? const {} : style.marks,
        width: width - margin.horizontal,
        decoration: style.decoration,
        first: !box._continued,
        last: rest == null,
        tag: style.tag,
      ),
      height,
      rest == null ? null : CustomBox._rest(rest, style),
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
    // Too little room for the first box: the set goes on in the next
    // region.
    if (!atTop &&
        !box._continued &&
        box.children.isNotEmpty &&
        _minHeight(box.children.first, columnWidth) > available - top + 1e-6) {
      return _Fit.moved(box);
    }
    final columns = <(double, _Placed)>[];
    var height = 0.0;
    BreakBox? hit;
    for (var c = 0; c < box.count && rest != null; c++) {
      // Each column starts at the top of a region (a break or a margin
      // at the top of the first one counts for nothing too).
      final fit = _place(rest, columnWidth, available - top, atTop: true);
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
  const new(
    this.placed,
    this.height,
    this.rest, {
    this.hit,
    this.floated = const [],
    this.pinned = const [],
  });

  /// Nothing placed: all of [box] goes to the next region.
  const new moved(LayoutBox box)
    : placed = null,
      height = 0,
      rest = box,
      hit = null,
      floated = const [],
      pinned = const [];

  final _Placed? placed;
  final double height;
  final LayoutBox? rest;

  /// The forced break that ended the placing.
  final BreakBox? hit;

  /// Floating boxes that didn't fit, for the top of the next region.
  final List<LayoutBox> floated;

  /// Floating boxes that fit, for the top or bottom of the region: each
  /// with its top (from the placed part's top) and height.
  final List<(LayoutBox, double, double)> pinned;
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
    void Function(String tag) tag,
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
    void Function(String tag) tag,
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
    this.marginBottom,
  });

  final BoxStyle style;
  final double width;
  @override
  final double height;

  /// The margin below taken (of a last piece), when less than the
  /// style's.
  final double? marginBottom;

  /// The children and their offsets below the content top.
  final List<(double, _Placed)> children;

  /// The top margin taken.
  final double top;

  final bool openTop;
  final bool openBottom;
  final Map<String, String> marks;
  final String? anchor;

  /// Whether the piece has the block's top and bottom edges (padding and
  /// border): the first and last piece's, or every piece's with
  /// [BoxStyle.cloneEdges].
  bool get _topEdge => !openTop || style.cloneEdges;
  bool get _bottomEdge => !openBottom || style.cloneEdges;

  double get _contentTop =>
      top + (_topEdge ? style.border.widths.top + style.padding.top : 0);

  double get _contentLeft =>
      style.margin.left + style.border.widths.left + style.padding.left;

  @override
  void visit(
    double x,
    double top,
    void Function(String anchor, double x, double y) anchor,
    void Function((String, String) mark) mark,
    void Function(String tag) tag,
  ) {
    if (this.anchor case final name?) {
      anchor(name, x + style.margin.left, top - this.top);
    }
    if (style.tag case final name?) tag(name);
    marks.entries.map((e) => (e.key, e.value)).forEach(mark);
    for (final (offset, child) in children) {
      child.visit(
        x + _contentLeft,
        top - _contentTop - offset,
        anchor,
        mark,
        tag,
      );
    }
  }

  @override
  void paint(_Painter painter, double x, double top) {
    final canvas = painter.canvas;
    final border = style.border;
    final left = x + style.margin.left;
    final boxWidth = width - style.margin.horizontal;
    final boxTop = top - this.top;
    final bottomMargin = openBottom ? 0 : marginBottom ?? style.margin.bottom;
    final boxHeight = height - this.top - bottomMargin;
    final rect = PdfRect(left, boxTop - boxHeight, boxWidth, boxHeight);
    final uniform =
        border.widths.top == border.widths.left &&
        border.widths.left == border.widths.right &&
        border.widths.right == border.widths.bottom &&
        _topEdge &&
        _bottomEdge;
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
        if (_topEdge) {
          side(widths.top, l, t - widths.top / 2, r, t - widths.top / 2);
        }
        if (_bottomEdge) {
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
    style.decoration?.call(
      painter.page,
      rect,
      first: _topEdge,
      last: _bottomEdge,
    );
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
    this.tag,
  );

  final Map<String, String> marks;

  /// The paragraph's tag ([BoxStyle.tag]).
  final String? tag;

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
    void Function(String tag) tag,
  ) {
    if (this.anchor case final name?) anchor(name, x + left, top - this.top);
    if (this.tag case final name?) tag(name);
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

  final Graphic image;
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
    void Function(String tag) tag,
  ) {
    if (this.anchor case final name?) anchor(name, x + left, top - this.top);
  }

  @override
  void paint(_Painter painter, double x, double top) {
    image.paint(
      painter.canvas,
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
    void Function(String tag) tag,
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

final class _PlacedCustom extends _Placed {
  const new(
    this.placement,
    this.left,
    this.top,
    this.height,
    this.anchor,
    this.marks, {
    required this.width,
    this.decoration,
    this.first = true,
    this.last = true,
    this.tag,
  });

  final double width;
  final BoxDecoration? decoration;

  /// The box's tag ([BoxStyle.tag]).
  final String? tag;
  final bool first;
  final bool last;

  final CustomPlacement placement;
  final double left;
  final double top;
  @override
  final double height;
  final String? anchor;
  final Map<String, String> marks;

  @override
  void visit(
    double x,
    double top,
    void Function(String anchor, double x, double y) anchor,
    void Function((String, String) mark) mark,
    void Function(String tag) tag,
  ) {
    if (this.tag case final name?) tag(name);
    if (this.anchor case final name?) anchor(name, x + left, top - this.top);
    marks.entries.map((e) => (e.key, e.value)).forEach(mark);
    for (final (name, dx, dy) in placement.anchors) {
      anchor(name, x + left + dx, top - this.top - dy);
    }
  }

  @override
  void paint(_Painter painter, double x, double top) {
    decoration?.call(
      painter.page,
      PdfRect(
        x + left,
        top - this.top - placement.height,
        width,
        placement.height,
      ),
      first: first,
      last: last,
    );
    placement.paint(painter.page, x + left, top - this.top);
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
    void Function(String tag) tag,
  ) {
    for (final (left, column) in columns) {
      column.visit(x + left, top - this.top, anchor, mark, tag);
    }
  }

  @override
  void paint(_Painter painter, double x, double top) {
    for (final (left, column) in columns) {
      column.paint(painter, x + left, top - this.top);
    }
  }
}

final class _PlacedCell {
  const new(
    this.cell,
    this.x,
    this.y,
    this.width,
    this.height,
    this.content,
    this.contentHeight, {
    required this.openBottom,
    this.stripe,
  });

  final TableCell cell;

  /// The background of the cell's row, for a cell without its own.
  final PdfColor? stripe;

  /// The left edge, from the table's region's left.
  final double x;

  /// The top edge, below the table's top.
  final double y;
  final double width;
  final double height;
  final _Placed? content;
  final double contentHeight;
  final bool openBottom;

  double get _contentTop {
    final padding = cell.padding;
    final room = height - padding.vertical;
    if (cell.verticalOffset case final offset?) {
      return y + padding.top + offset(room, contentHeight);
    }
    return y +
        padding.top +
        switch (cell.verticalAlign) {
          VerticalAlign.top => 0,
          VerticalAlign.middle => (room - contentHeight) / 2,
          VerticalAlign.bottom => room - contentHeight,
        };
  }
}

final class _PlacedTable extends _Placed {
  const new(this.cells, this.height, this.anchor, this.tag);

  final List<_PlacedCell> cells;

  /// The table's tag ([BoxStyle.tag]).
  final String? tag;
  @override
  final double height;
  final String? anchor;

  @override
  void visit(
    double x,
    double top,
    void Function(String anchor, double x, double y) anchor,
    void Function((String, String) mark) mark,
    void Function(String tag) tag,
  ) {
    if (this.anchor case final name?) anchor(name, x, top);
    if (this.tag case final name?) tag(name);
    for (final cell in cells) {
      cell.content?.visit(
        x + cell.x + cell.cell.padding.left,
        top - cell._contentTop,
        anchor,
        mark,
        tag,
      );
    }
  }

  @override
  void paint(_Painter painter, double x, double top) {
    final canvas = painter.canvas;
    for (final placed in cells) {
      if (placed.cell.background ?? placed.stripe case final background?) {
        canvas
          ..save()
          ..setFillColor(background)
          ..rect(
            PdfRect(
              x + placed.x,
              top - placed.y - placed.height,
              placed.width,
              placed.height,
            ),
          )
          ..fill()
          ..restore();
      }
    }
    for (final placed in cells) {
      placed.content?.paint(
        painter,
        x + placed.x + placed.cell.padding.left,
        top - placed._contentTop,
      );
    }
    for (final placed in cells) {
      if (placed.cell.decoration case final decoration?) {
        decoration(
          painter.page,
          PdfRect(
            x + placed.x,
            top - placed.y - placed.height,
            placed.width,
            placed.height,
          ),
          first: !placed.cell._openTop,
          last: !placed.openBottom,
        );
        continue;
      }
      final border = placed.cell.border;
      final widths = border.widths;
      if (widths == EdgeInsets.zero) continue;
      final l = x + placed.x;
      final r = l + placed.width;
      final t = top - placed.y;
      final b = t - placed.height;
      canvas
        ..save()
        ..setStrokeColor(border.color);
      void side(double w, double x1, double y1, double x2, double y2) {
        if (w <= 0) return;
        canvas
          ..setLineWidth(w)
          ..moveTo(x1, y1)
          ..lineTo(x2, y2)
          ..stroke();
      }

      // Borders are centered on the cell's edges, and the horizontal ones
      // reach over the vertical ones' halves at the corners.
      if (!placed.cell._openTop) {
        side(widths.top, l - widths.left / 2, t, r + widths.right / 2, t);
      }
      if (!placed.openBottom) {
        side(widths.bottom, l - widths.left / 2, b, r + widths.right / 2, b);
      }
      side(widths.left, l, b, l, t);
      side(widths.right, r, b, r, t);
      canvas.restore();
    }
  }
}

/// Content laid out on pages, ready to render.
final class LayoutResult {
  new _(
    this._layout,
    this._pages,
    this.anchors,
    this.tagPages,
    this._boundaries,
    this._repeatedAnchors,
  );

  final FlowLayout _layout;
  final List<_Page> _pages;
  final List<_Boundary> _boundaries;
  final Map<String, List<int>> _repeatedAnchors;

  /// The pages (0-based) [anchor] is placed on, in order: the page of
  /// [anchors]'s position, then those of its repetitions.
  List<int> anchorPages(String anchor) => [
    ?anchors[anchor]?.page,
    ...?_repeatedAnchors[anchor],
  ];

  /// The top-level boxes after which a later layout of the same content
  /// may go on from this one's pages (each the start of a run of pages
  /// nothing before it reaches into).
  List<int> get boundaries => [for (final b in _boundaries) b.index];

  /// The last of [boundaries] with only pages before [page] (0-based)
  /// before it, or 0: a later layout that changes nothing on the pages
  /// before [page] may go on from it.
  int boundaryBefore(int page) {
    var index = 0;
    for (final boundary in _boundaries) {
      if (boundary.pages > page) break;
      index = boundary.index;
    }
    return index;
  }

  /// Where each anchor is.
  final Map<String, AnchorPosition> anchors;

  /// The first and last page (1-based) of each box with a tag
  /// ([BoxStyle.tag]): a box that breaks across pages has two.
  final Map<String, ({int first, int last})> tagPages;

  /// The number of pages.
  int get pageCount => _pages.length;

  /// The page number of [anchor] (1-based), if it is anchored.
  int? pageOf(String anchor) => switch (anchors[anchor]) {
    AnchorPosition(:final page) => page + 1,
    null => null,
  };

  /// Adds the pages to [document]; anchors become named destinations,
  /// named by [destinationName] (the anchor's name when null).
  List<PdfPage> render(
    PdfDocument document, {
    String Function(String anchor)? destinationName,
  }) {
    final rendered = <PdfPage>[];
    final carried = <String, String>{};
    for (final (i, page) in _pages.indexed) {
      // A mark's value on a page: the first set on it, else the last
      // carried over.
      final marks = {...carried};
      final top = {...carried};
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
        page.template,
        top,
        isEmpty: page.placed.every((p) => (p.$2?.height ?? 0) == 0),
      );
      final template = page.template;
      final size = template.size;
      final PdfPage pdfPage;
      if (template.bleed case final bleed?) {
        final sheet = PdfRect(
          size.left - bleed,
          size.bottom - bleed,
          size.width + 2 * bleed,
          size.height + 2 * bleed,
        );
        pdfPage = document.addPage(sheet, trimBox: size, bleedBox: sheet);
      } else {
        pdfPage = document.addPage(size);
      }
      final painter = _Painter(pdfPage.canvas, pdfPage);
      template.background?.call(pdfPage.canvas, info);
      _running(template.header?.call(info), template, painter, header: true);
      for (final (region, placed) in page.placed) {
        placed?.paint(painter, region.left, region.top);
      }
      _running(template.footer?.call(info), template, painter, header: false);
      template.foreground?.call(pdfPage.canvas, info);
      rendered.add(pdfPage);
    }
    for (final MapEntry(key: name, value: position) in anchors.entries) {
      document.addDestination(
        destinationName?.call(name) ?? name,
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
    // Space in running content is meant: nothing is dropped at its top.
    final fit = pass._place(BlockBox(boxes), width, height, atTop: false);
    final top = header ? size.top : size.bottom + margins.bottom;
    fit.placed?.paint(painter, size.left + margins.left, top);
  }
}

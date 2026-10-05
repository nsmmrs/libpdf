/// Inline content of paragraphs: styled text runs and inline images.
library;

import 'package:libpdf/src/drawing/canvas.dart';
import 'package:libpdf/src/drawing/color.dart';
import 'package:libpdf/src/drawing/document.dart';
import 'package:libpdf/src/fonts/fonts.dart';
import 'package:libpdf/src/images/images.dart';
import 'package:meta/meta.dart';

/// A piece of a paragraph's content.
@immutable
sealed class InlineContent {
  const new _();
}

/// Text in one style.
final class TextRun extends InlineContent {
  /// [text] set in [style], painted in [color] (black by default), with
  /// the decorations asked for, linking to [link].
  const new(
    this.text,
    this.style, {
    this.color,
    this.underline = false,
    this.strikethrough = false,
    this.link,
    this.anchor,
    this.decoration,
    this.fallbackFonts = const [],
  }) : super._();

  /// The text.
  final String text;

  /// The font, size and text state.
  final PdfTextStyle style;

  /// The fill color, or null for the canvas's current color.
  final PdfColor? color;

  /// Whether the text is underlined.
  final bool underline;

  /// Whether the text is struck through.
  final bool strikethrough;

  /// Where the text links to.
  final LinkTarget? link;

  /// A name for the position of the text: layout reports where it ends
  /// up (for destinations, a table of contents, an index).
  final String? anchor;

  /// A background and border drawn behind the text.
  final InlineDecoration? decoration;

  /// The fonts that set the characters [style]'s font lacks: each
  /// character goes to the first that has it.
  final List<PdfFont> fallbackFonts;

  /// A run of [text] with this run's formatting.
  TextRun withText(String text) => TextRun(
    text,
    style,
    color: color,
    underline: underline,
    strikethrough: strikethrough,
    link: link,
    anchor: anchor,
    decoration: decoration,
    fallbackFonts: fallbackFonts,
  );

  /// This run in [style].
  TextRun withStyle(PdfTextStyle style) => TextRun(
    text,
    style,
    color: color,
    underline: underline,
    strikethrough: strikethrough,
    link: link,
    anchor: anchor,
    decoration: decoration,
  );
}

/// A box drawn behind a run of text: a background and a border around
/// the text's ascent and descent, wider by [padding] on each side.
@immutable
final class InlineDecoration {
  /// A decoration.
  const new({
    this.background,
    this.borderColor,
    this.borderWidth = 0,
    this.radius = 0,
    this.padding = 0,
  });

  /// The fill.
  final PdfColor? background;

  /// The border's color.
  final PdfColor? borderColor;

  /// The border's width.
  final double borderWidth;

  /// The corner radius.
  final double radius;

  /// The extra width on the left and right, in points.
  final double padding;
}

/// How an inline image sits on the line.
enum InlineAlignment {
  /// Its bottom on the baseline.
  baseline,

  /// Its middle on the middle of the line's text (half the x-height above
  /// the baseline of the run before it).
  middle,

  /// Its top at the top of the line's text.
  top,
}

/// An image in the text, of a given size.
final class InlineImage extends InlineContent {
  /// [image] drawn [width] by [height] points, aligned by [alignment].
  const new(
    this.image,
    this.width,
    this.height, {
    this.alignment = InlineAlignment.baseline,
    this.link,
  }) : super._();

  /// The image.
  final PdfImage image;

  /// Its width, in points.
  final double width;

  /// Its height, in points.
  final double height;

  /// Its vertical alignment.
  final InlineAlignment alignment;

  /// Where the image links to.
  final LinkTarget? link;
}

/// The page number (or label) of an anchor, filled in when the layout
/// knows it: a table of contents, "see page 12". Until then it takes the
/// room of [placeholder].
final class PageReference extends InlineContent {
  /// The page of [anchor], set in [style] like a [TextRun].
  const new(
    this.anchor,
    this.style, {
    this.placeholder = '000',
    this.color,
    this.link,
  }) : super._();

  /// The anchor whose page is shown.
  final String anchor;

  /// The font, size and text state.
  final PdfTextStyle style;

  /// The text measured before the page is known.
  final String placeholder;

  /// The fill color.
  final PdfColor? color;

  /// Where the reference links to.
  final LinkTarget? link;

  /// The reference as a run of [text].
  TextRun resolve(String text) =>
      TextRun(text, style, color: color, link: link);
}

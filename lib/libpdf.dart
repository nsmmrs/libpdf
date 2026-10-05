/// libpdf: a pure-Dart PDF library written from ISO 32000.
///
/// The object layer: the PDF object model (`PdfObject` and its kinds),
/// Flate compression, and a `PdfWriter` that writes a file with
/// cross-reference tables or streams. Fonts (`PdfFont`) and images
/// (`PdfImage`). The drawing layer: a `PdfDocument` of pages drawn on
/// `PdfCanvas`es, with links, destinations, outlines and page labels.
library;

export 'src/drawing/canvas.dart'
    show
        BlendMode,
        LineCap,
        LineJoin,
        PdfCanvas,
        PdfForm,
        PdfTextStyle,
        SoftMaskKind,
        TextRenderMode,
        TransparencyGroup;
export 'src/drawing/color.dart'
    show CmykColor, GrayColor, PdfColor, RgbColor, SpotColor;
export 'src/drawing/document.dart'
    show
        DestinationTarget,
        FitDestination,
        FitWidthDestination,
        LinkTarget,
        NamedTarget,
        PageLabel,
        PageMode,
        PageNumberStyle,
        PdfDestination,
        PdfDocument,
        PdfOutlineItem,
        PdfPage,
        UriTarget,
        XyzDestination;
export 'src/drawing/geometry.dart' show PdfMatrix, PdfRect;
export 'src/drawing/graphic.dart' show Graphic;
export 'src/drawing/shading.dart'
    show AxialShading, GradientStop, PdfShading, RadialShading;
export 'src/flate.dart' show adler32, deflate, inflate, zlibDecode, zlibEncode;
export 'src/fonts/fonts.dart'
    show EmbeddedFont, PdfFont, ShapedGlyph, StandardFont;
export 'src/fonts/opentype.dart' show FontFormatException, OpenTypeFont;
export 'src/images/images.dart'
    show ImageFormatException, JpegImage, PdfImage, PngColorType, PngImage;
export 'src/layout/flow.dart'
    show
        AnchorPosition,
        AutoColumnWidth,
        BlockBox,
        Border,
        BoxAlign,
        BoxDecoration,
        BoxStyle,
        BreakBox,
        BreakKind,
        ColumnWidth,
        ColumnsBox,
        ComputedColumnWidth,
        CustomBox,
        CustomContent,
        CustomPlacement,
        DefaultPageBreaker,
        DrawingBox,
        EdgeInsets,
        FixedColumnWidth,
        FlowLayout,
        FractionColumnWidth,
        ImageBox,
        LayoutBox,
        LayoutResult,
        PageBreaker,
        PageInfo,
        PageTemplate,
        ParagraphBox,
        SpacerBox,
        TableBox,
        TableCell,
        TableRow,
        VerticalAlign;
export 'src/layout/inline.dart'
    show
        InlineAlignment,
        InlineContent,
        InlineDecoration,
        InlineImage,
        PageReference,
        TextRun;
export 'src/layout/line_break.dart'
    show LineBreak, LineBreakClass, lineBreakClass, lineBreaks;
export 'src/layout/line_break_data.g.dart' show unicodeVersion;
export 'src/layout/paragraph.dart'
    show
        BoxItem,
        ExactLineHeight,
        FirstFitLineBreaker,
        FontLineHeight,
        GlueItem,
        Hyphenator,
        ImageFragment,
        ItemLineBreaker,
        KnuthPlassLineBreaker,
        Line,
        LineBreaker,
        LineFragment,
        LineHeight,
        LineItem,
        LineWidths,
        MultipleLineHeight,
        Paragraph,
        PenaltyItem,
        TextAlign,
        TextFragment,
        buildLines,
        paragraphItems;
export 'src/md5.dart' show md5;
export 'src/objects.dart'
    show
        PdfArray,
        PdfBool,
        PdfDict,
        PdfInt,
        PdfName,
        PdfNull,
        PdfObject,
        PdfReal,
        PdfRef,
        PdfStream,
        PdfString,
        formatNumber,
        pdfDocEncode;
export 'src/reader/reader.dart'
    show ImportedPage, PdfFile, PdfFormatException;
export 'src/svg/path.dart'
    show
        CloseSegment,
        CubicSegment,
        LineSegment,
        MoveSegment,
        PathSegment,
        SvgPath;
export 'src/svg/svg.dart' show SvgFontResolver, SvgImage, SvgImageResolver;
export 'src/writer.dart' show PdfInfo, PdfWriter, PdfWriterOptions, pdfDate;

/// The version of libpdf.
const String libpdfVersion = '0.1.0-dev';

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
export 'src/flate.dart' show adler32, deflate, inflate, zlibDecode, zlibEncode;
export 'src/fonts/fonts.dart'
    show EmbeddedFont, PdfFont, ShapedGlyph, StandardFont;
export 'src/fonts/opentype.dart' show FontFormatException, OpenTypeFont;
export 'src/images/images.dart'
    show ImageFormatException, JpegImage, PdfImage, PngColorType, PngImage;
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
export 'src/writer.dart' show PdfInfo, PdfWriter, PdfWriterOptions, pdfDate;

/// The version of libpdf.
const String libpdfVersion = '0.1.0-dev';

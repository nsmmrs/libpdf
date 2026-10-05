/// libpdf: a pure-Dart PDF library written from ISO 32000.
///
/// This library holds the object layer: the PDF object model (`PdfObject`
/// and its kinds), Flate compression, and a `PdfWriter` that writes a file
/// with cross-reference tables or streams.
library;

export 'src/flate.dart' show adler32, deflate, inflate, zlibDecode, zlibEncode;
export 'src/fonts/fonts.dart'
    show EmbeddedFont, PdfFont, ShapedGlyph, StandardFont;
export 'src/fonts/opentype.dart' show FontFormatException, OpenTypeFont;
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

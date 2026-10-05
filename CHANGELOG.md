# Changelog

## 0.1.0-dev (unreleased)

- The repository: package layout, analysis, CI (Linux, macOS, Windows, and
  a JavaScript compile of the library), the layered design (ADR-0001).
- The object layer: the PDF object model as sealed types (null, boolean,
  integer, real, string, name, array, dictionary, stream, reference) with
  their syntax; Flate (DEFLATE with dynamic Huffman codes, and inflate) and
  MD5 in pure Dart, so output is the same bytes on the VM and the web; a
  streaming writer with cross-reference tables, or cross-reference and
  object streams, document information and XMP metadata, file identifiers,
  and a deterministic mode. Checked with `qpdf --check` and poppler.
- Fonts: OpenType parsing (TrueType and CFF outlines, collections, cmap
  formats 0, 4, 6 and 12, kerning from `kern` and GPOS pair adjustment,
  `liga` ligatures from GSUB); TrueType subsetting that keeps glyph ids;
  embedding as Type0/Identity-H fonts with widths and a ToUnicode map, so
  text stays extractable; and the 14 standard fonts with metrics, kerning
  and WinAnsi encoding generated from the Adobe AFM files. CFF fonts are
  embedded whole for now.
- Images: JPEG files embedded as they are (DCTDecode; gray, RGB and CMYK,
  baseline and progressive, Adobe-inverted CMYK, EXIF orientation
  reported); PNG files of every color type and bit depth, embedded as they
  are when PDF can show them (FlateDecode with a PNG predictor), decoded
  otherwise: interlaced images, alpha split into a soft mask, palette
  transparency, color-key transparency, embedded ICC profiles; damaged
  files rejected. Checked against PngSuite by rendering with poppler.
- Drawing: `PdfDocument` with pages (media, crop, bleed, trim and art
  boxes; rotation) drawn on a `PdfCanvas`: paths (lines, Bézier curves,
  rectangles, rounded rectangles, ellipses), fill and stroke with the
  nonzero or even-odd rule, clipping, gray, RGB, CMYK and spot colors,
  line width, caps, joins, miter limit and dashes, transforms and
  save/restore; opacity, blend modes, soft masks and transparency groups;
  reusable forms; images; text at explicit positions with kerning,
  character and word spacing (also for embedded fonts), rise, horizontal
  scaling and render modes, measured as drawn. Links (URIs, named and
  explicit destinations), named destinations, outlines with nesting and
  styles, page labels, page mode, language and viewer preferences. Each
  document declares the lowest PDF version it needs.

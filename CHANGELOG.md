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
- Layout, paragraphs: break opportunities by the Unicode Line Breaking
  Algorithm (UAX #14, Unicode 18.0; the conformance test passes), styled
  text runs and inline images as boxes, glue and penalties, line breaking
  as a strategy (`LineBreaker`) with first fit and Knuth-Plass provided,
  soft hyphens and a hyphenation hook, words wider than the line broken
  anywhere, alignment (left, center, right, justified), first-line indent,
  line heights (font, multiple, exact), underline and strikethrough from
  the fonts' metrics, links and anchors reported where they are painted.
- Layout, pages: a box tree (blocks with margins, padding, borders and
  backgrounds; paragraphs; images; spacers; drawings; page and column
  breaks; column sets) flowing into the regions of page templates (with
  columns), split where needed (a split block's border stays open, and
  its bottom padding and border take room only below its last child), with
  keep-together, keep-with-next, orphans and widows decided by a
  `PageBreaker` strategy; running headers and footers that see the page
  number, the page count and running marks; anchors that become named
  destinations; page references resolved by laying out again.
- Layout, tables: fixed, fraction and auto column widths (auto columns
  share space by their content's narrowest and widest widths, as CSS's
  automatic table layout does), column and row spans, per-cell padding,
  backgrounds, borders and vertical alignment, header rows repeated on
  each page, row groups joined by spans kept together, and rows (and
  spanning cells) split when taller than a page. Inline decorations
  (background and border behind a run). A sample document with golden
  renders, and a benchmark (`benchmark/layout_benchmark.dart`, about 240
  pages a second on a laptop).
- Font fallback chains: a text run's characters its font lacks are set in
  the first of its fallback fonts that has them.
- SVG: `SvgImage` draws SVG as PDF vector graphics: the path grammar
  (arcs included), basic shapes, transforms, nested viewports with
  viewBox and preserveAspectRatio, `use` and `symbol`, fill and stroke
  styles, linear and radial gradients (shadings; stop opacity as a soft
  mask), clip paths, group opacity (transparency groups), a CSS subset
  (style sheets with type, class, id and descendant selectors; style
  attributes), text in PDF fonts with anchors and baselines, raster and
  SVG images from data URIs or a resolver. Masks, filters, markers,
  patterns and per-character text positions are reported as warnings.
  Checked against librsvg's renderings. Shadings (`AxialShading`,
  `RadialShading`, `PdfCanvas.shade`) join the drawing API; `Graphic`
  lets the layout place raster and SVG images alike.
- The package: only the supported API is exported (internals of the
  canvas and shadings are no longer public), checked against a snapshot in
  CI (`tool/api_check.dart`); examples (a styled report with a table of
  contents, an SVG chart, a two-column booklet) run as tests;
  `FlowLayout.startTemplate` chooses the first page's template.
- `CustomBox`: content that lays itself out (`CustomContent`), placed and
  split by the layout like any box, for callers reproducing another
  engine's text boxes.
- Fonts: `EmbeddedFont.parse(truncateWidths:)` writes glyph widths
  truncated rather than rounded (text then lines up with engines that
  truncate); OS/2 typographic metrics; `kern` table pairs;
  `StandardFont.boundingBox`.
- `BoxStyle.decoration`: a callback painting over each piece of a block,
  told whether the piece is where the block starts and ends.
- `BreakBox.page(force: true)` and `BreakBox.column(force: true)`: a
  break made even at the top of a region.
- `ColumnWidth.computed`: a table column whose width is computed from the
  table's width.
- `SvgImage.rootAttribute`: the root element's attributes as written.
- `FlowLayout(keepTemplate: true)`: a page break's template stays in
  effect for the pages after it, and a break to a template at the top of
  an empty page replaces it; `PageInfo.template` names a page's template.
  The top of each column of a `ColumnsBox` is a region top (breaks and
  top margins there count for nothing). A last page with nothing on it
  (after a trailing page break) is left out.
- `kernTablePair(subtable:)` and `EmbeddedFont.parse(kernTableSubtable:)`:
  kerning from one subtable of the `kern` table alone (Prawn kerns with
  the first).
- Tables: `TableCell.verticalOffset` places a cell's content by a
  function of the room and the content's height, `TableCell.decoration`
  paints a cell's border in place of `border`, and `TableBox.stripes`
  gives body rows backgrounds in turn, starting over in each region.
- Reading: `PdfFile.parse` reads a PDF file's objects (cross-reference
  tables and streams, incremental updates, object streams; rebuilt by
  scanning the file when the cross-references are broken; Flate, LZW,
  ASCIIHex, ASCII85 and RunLength filters with PNG predictors) and its
  pages; an `ImportedPage` paints into another document as a form XObject
  of the page's content, with its resources copied once (`PdfCanvas.page`),
  turned as the page is displayed. Encrypted files are rejected.
- A template break that replaces an empty page carries what was placed on
  it (anchors, marks) to the page replacing it.
- `BreakBox.page(side:)`: content after the break starts on a recto (odd)
  or verso (even) page, after a blank page when needed (`PageSide`);
  `FlowLayout(templateForPage:)` gives each page its template by number,
  for margins that differ between recto and verso pages.
- A custom box paints its style's decoration under its content.
- `PageTemplate.foreground` paints over a page's content, header and
  footer. `PdfDocument.openAction` (where the document opens),
  `PdfDocument(nonFullScreenPageMode:)` and `PdfDestination.fitHeight`
  (`FitV`).
- `SvgImage.parse(defaultFontFamily:, fallbackFontFamily:)`: the family
  of text without a `font-family`, and a family tried after an element's
  own.
- CFF fonts are subset: the glyphs used keep their charstrings and glyph
  ids, the others become empty, and so do the subroutines (local and
  global) no kept glyph calls; a CID-keyed font gets an identity charset,
  as text addresses glyphs by id. The CFF is embedded bare
  (`CIDFontType0C`). Fonts with CFF outlines no longer fail to embed (the
  glyph closure read TrueType composites). A CFF that can't be rewritten
  (`seac` accents, damaged) and CFF2 are embedded as they are.
- `LayoutResult.render(destinationName:)` names the destinations of the
  anchors.
- A fuzz test (seeded) damages JPEG, PNG, SVG, font and PDF input: every
  decoder either reads it or rejects it with its format exception. Fixed
  on the way: a damaged font could fail with a RangeError (the name table,
  table and glyph slices, composite glyphs), a PDF file with a damaged
  Flate stream or a truncated dictionary likewise, and an SVG image whose
  data URI had a bad percent escape failed the whole SVG.
- Faster text: standard-font kerning by code, number formatting without
  regular expressions, `TJ` written without per-glyph allocations, copying
  byte builders, embedded-font kerning pairs cached. BASELINE.md compares
  libpdf with package:pdf.
- `PatternHyphenator`: Liang's hyphenation over TeX patterns and
  exceptions (as hyph-utf8 distributes them), with the fewest letters
  before and after a hyphen; a `Hyphenator` for paragraphs.
- `FlowLayout(notes:, noteSeparator:)`: notes (footnotes) by the anchor
  that refers to them, set at the bottom of the region the anchor is
  placed in, the region's content making room; a note that doesn't fit
  goes on in the next region.

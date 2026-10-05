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

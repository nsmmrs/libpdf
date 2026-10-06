# Baseline

Numbers to watch, measured on the development machine (Linux x64, AMD
desktop, Dart 3.13 AOT). Re-measure after changes that touch drawing,
fonts, the writer or Flate.

## Against package:pdf (2026-10-06)

`benchmark/compare/` (a package of its own, so libpdf has no dependency
on package:pdf) makes the same documents with each library's drawing API,
no layout: 50 A4 pages of 45 lines of text in a standard font, the same
in an embedded TrueType font (Noto Serif, subset), and 50 pages each
with a JPEG. Median of 11 runs after 3 warmups; sizes of the files made.

| Document | libpdf | package:pdf | libpdf size | package:pdf size |
| --- | --: | --: | --: | --: |
| standard font text, 50 pages | 18.5 ms | 6.1 ms | 25 KB | 31 KB |
| TrueType text (subset), 50 pages | 32.9 ms | 12.0 ms | 40 KB | 41 KB |
| JPEG images, 50 pages | 4.8 ms | 2.5 ms | 42 KB | 50 KB |

libpdf is slower and makes smaller files:

- *Flate.* Its Flate encoder is pure Dart, so the bytes are the same on the
  VM and the web; package:pdf uses the platform's zlib on the VM. Flate is
  about 8 ms of the text documents' time.
- *Text.* Shaping applies kerning (the AFM pairs, or GPOS and `kern`) and
  can apply ligatures, and every glyph keeps the text it stands for, for
  the ToUnicode map. package:pdf draws strings as they are.

The first pass of tuning (2026-10-06) halved the text documents' time:
standard-font kerning by code instead of by glyph-name strings, number
formatting without regular expressions, no per-glyph allocations when
writing `TJ`, copying byte builders where bytes are added one at a time,
and embedded-font kerning pairs cached.

Run it: `cd benchmark/compare && dart pub get && dart compile exe
bin/compare.dart -o compare && ./compare`.

## Verification

- Golden images (`test/golden_test.dart`) and text extraction checks run
  in CI with poppler.
- Every written file is checked by `qpdf --check` in the tests that write
  one.
- `test/fuzz_test.dart` damages JPEG, PNG, SVG, font and PDF input with
  seeded random edits. Every decoder either reads it or rejects it with its
  format exception.
- veraPDF waits for PDF/A, which libpdf doesn't write yet.

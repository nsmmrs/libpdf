# ADR-0001: Three Layers, Strategies at the Seams

**Status:** Final. Decided on 2026-10-05 with the user (EPIC-g1cz95).

## Context

libpdf is a general-purpose PDF library in pure Dart, written from
ISO 32000-2. Its first consumer is asciidart's PDF backend, which must lay
out documents as asciidoctor-pdf (on Prawn) does; other consumers want a
library that doesn't know about asciidart or Prawn at all.

## Decision

1. **Three layers, each public and usable alone.**
   - *Objects and writer*: COS objects as sealed types (null, boolean,
     integer, real, string, name, array, dictionary, stream, reference),
     a serializer, cross-reference tables or streams, object streams,
     Flate in pure Dart (so the library runs on the web), document
     information and XMP metadata, and a deterministic mode.
   - *Drawing*: content streams through a typed graphics API (no hidden
     global cursor): paths, colors, transforms, clipping, transparency,
     text with embedded fonts, images, annotations, destinations,
     outlines, page labels, page boxes.
   - *Layout*: a typed box tree (sealed box kinds and style values) that is
     measured, broken into lines and pages, then painted. Measuring never
     paints; forward references (page numbers in a table of contents) are
     resolved by laying out again until nothing changes.
2. **Strategies at the seams.** Line breaking and page-break decisions are
   interfaces. libpdf ships defaults (first fit, Knuth-Plass for lines);
   callers plug in their own. asciidart's Prawn-compatible strategies live
   in asciidart, never here.
3. **Pure Dart, minimal dependencies.** Only the Dart team's packages,
   where unavoidable (`package:xml` for SVG is acceptable under its
   permissive license).
4. **Out of scope at first**: reading existing PDFs, forms, encryption,
   tagged PDF and PDF/A (later cards).

## Consequences

- Each layer has its own gate: `qpdf --check` on everything the writer
  produces, text extraction and rendering through poppler for drawing, and
  measured geometry plus golden renders for layout.
- The private-by-default rule asciidart follows applies here: only the
  supported API is exported, and an API snapshot is checked in CI.

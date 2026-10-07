# Test fonts

Subsets distributed with asciidoctor-epub3 2.3.0:

- `notoserif-regular-latin.ttf`: Noto Serif, Latin subset (Apache License
  2.0, https://www.apache.org/licenses/LICENSE-2.0; © Google).
- `mplus1p-regular-multilingual.ttf`: M+ 1p, multilingual subset (M+ FONTS
  license: unlimited permission to use, copy and distribute, with or
  without modification; © M+ FONTS PROJECT, Coji Morishita).

Made from them:

- `notoserif-kern-subtables.ttf`: `notoserif-regular-latin.ttf` with a
  `kern` table of two subtables (A V −80; then T o −60 and A V −40), made
  with fontTools.
- `notoserif-cff.otf`: `notoserif-regular-latin.ttf` with CFF outlines
  (the same curves, cubic), each glyph's outline in a local subroutine or,
  for every fifth glyph, a global one, and a hint mask in `H`, made with
  fontTools.
- `notoserif-cid.otf`: `notoserif-cff.otf` as a CID-keyed font (one font
  DICT, FDSelect format 3) whose CIDs aren't its glyph ids (1000 and up).

From Noto Serif 2.015 (SIL Open Font License 1.1, https://openfontlicense.org;
© 2022 The Noto Project Authors):

- `notoserif-features.ttf`: Basic Latin, with the `onum`, `smcp`, `liga`
  and `kern` features, made with
  `pyftsubset NotoSerif-Regular.ttf --unicodes=U+0020-007E --layout-features=onum,smcp,liga,kern --name-IDs='*'`.

From Libertinus Serif 7.051 (SIL Open Font License 1.1; © the Libertinus
Project Authors):

- `libertinus-smcp.otf`: "Abc", whose `smcp` is a multiple substitution
  (GSUB type 2) of one glyph each, made with
  `pyftsubset LibertinusSerif-Regular.otf --text=Abc --layout-features=smcp --name-IDs='*'`.

Web fonts, made from the fonts above:

- `notoserif-features.woff`: `notoserif-features.ttf` as WOFF, made with
  fontTools (`flavor = 'woff'`, timestamps kept).
- `notoserif-features.woff2`: made with `woff2_compress` (google/woff2;
  the glyf and loca tables transformed). The test checks its glyf and loca
  tables against `woff2_decompress`'s.
- `notoserif-features-hmtx.woff2`: made with fontTools'
  `woff2.compress(..., transform_tables={'glyf', 'loca', 'hmtx'})`.
- `libertinus-smcp.woff2`: `libertinus-smcp.otf` (CFF outlines), made with
  `woff2_compress`.

Math:

- `notosansmath-subset.ttf`: Noto Sans Math 3.000 (SIL Open Font License
  1.1, https://openfontlicense.org; © 2022 The Noto Project Authors),
  subset with fontTools to ASCII, the Greek letters, the math italic
  letters and the operators the math tests use; its `MATH` table kept.

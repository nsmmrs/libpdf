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

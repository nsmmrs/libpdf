# Unicode Character Database 18.0.0

From https://www.unicode.org/Public/18.0.0/ucd/, for
`tool/generate_line_break.dart` (which writes
`lib/src/layout/line_break_data.g.dart`):

- `LineBreak.txt`: the Line_Break property (UAX #14).
- `EastAsianWidth.txt`: East_Asian_Width, for the `$EastAsian` set of the
  rules.
- `extracted/DerivedGeneralCategory.txt` (as `DerivedGeneralCategory.txt`):
  General_Category, for Pi, Pf, Mn, Mc and Cn.
- `emoji/emoji-data.txt` (as `emoji-data.txt`): Extended_Pictographic.

The conformance test, `auxiliary/LineBreakTest.txt`, is in
`test/unicode/LineBreakTest.txt.gz`. Terms: `license.txt` (Unicode License
v3).

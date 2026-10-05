/// Line break opportunities by the Unicode Line Breaking Algorithm
/// (UAX #14, Unicode 18.0), with its default rules.
library;

import 'package:libpdf/src/layout/line_break_data.g.dart';
import 'package:meta/meta.dart';

/// A Line_Break class (UAX #14, 5.1).
enum LineBreakClass {
  /// Mandatory break.
  bk,

  /// Carriage return.
  cr,

  /// Line feed.
  lf,

  /// Combining mark.
  cm,

  /// Next line.
  nl,

  /// Surrogate.
  sg,

  /// Word joiner.
  wj,

  /// Zero width space.
  zw,

  /// Non-breaking ("glue").
  gl,

  /// Space.
  sp,

  /// Zero width joiner.
  zwj,

  /// Break opportunity before and after.
  b2,

  /// Break after.
  ba,

  /// Break before.
  bb,

  /// Hyphen.
  hy,

  /// Contingent break.
  cb,

  /// Close punctuation.
  cl,

  /// Close parenthesis.
  cp,

  /// Exclamation or interrogation.
  ex,

  /// Inseparable.
  in_,

  /// Nonstarter.
  ns,

  /// Open punctuation.
  op,

  /// Quotation.
  qu,

  /// Infix numeric separator.
  is_,

  /// Numeric.
  nu,

  /// Postfix numeric.
  po,

  /// Prefix numeric.
  pr,

  /// Symbols allowing a break after.
  sy,

  /// Ambiguous (alphabetic or ideographic).
  ai,

  /// Aksara.
  ak,

  /// Alphabetic.
  al,

  /// Aksara prebase.
  ap,

  /// Aksara start.
  as_,

  /// Conditional Japanese starter.
  cj,

  /// Emoji base.
  eb,

  /// Emoji modifier.
  em,

  /// Hangul LV syllable.
  h2,

  /// Hangul LVT syllable.
  h3,

  /// Unambiguous hyphen.
  hh,

  /// Hebrew letter.
  hl,

  /// Ideographic.
  id,

  /// Hangul L jamo.
  jl,

  /// Hangul V jamo.
  jv,

  /// Hangul T jamo.
  jt,

  /// Regional indicator.
  ri,

  /// Complex context dependent (South East Asian).
  sa,

  /// Virama final.
  vf,

  /// Virama.
  vi,

  /// Unknown.
  xx,
}

const int _eastAsian = 1 << 6;
const int _initialPunctuation = 1 << 7;
const int _finalPunctuation = 1 << 8;
const int _unassignedPictographic = 1 << 9;
const int _combiningMark = 1 << 10;

/// The line breaking properties of [codePoint]: its class (as in the data)
/// and flags.
int _properties(int codePoint) {
  var low = 0;
  var high = rangeStarts.length - 1;
  while (low < high) {
    final middle = (low + high + 1) >> 1;
    if (rangeStarts[middle] <= codePoint) {
      low = middle;
    } else {
      high = middle - 1;
    }
  }
  return rangeValues[low];
}

/// The Line_Break class of [codePoint], as in the Unicode data.
LineBreakClass lineBreakClass(int codePoint) =>
    LineBreakClass.values[_properties(codePoint) & 0x3f];

/// A place text may (or must) be broken: before the code unit at
/// [offset].
@immutable
final class LineBreak {
  /// A break before [offset]; [mandatory] after a hard line break.
  const new(this.offset, {required this.mandatory});

  /// The code unit offset of the break.
  final int offset;

  /// Whether the line must end here (after a line feed, a paragraph
  /// separator...).
  final bool mandatory;

  @override
  bool operator ==(Object other) =>
      other is LineBreak &&
      other.offset == offset &&
      other.mandatory == mandatory;

  @override
  int get hashCode => Object.hash(offset, mandatory);

  @override
  String toString() => 'LineBreak($offset${mandatory ? ', mandatory' : ''})';
}

/// One unit of the rules: a character with the combining marks (and
/// joiners) after it (LB9).
final class _Unit {
  new(this.cls, this.flags, this.codePoint, this.start);

  /// The resolved class.
  final LineBreakClass cls;

  /// The flags of the unit's base character.
  final int flags;

  /// The base character.
  final int codePoint;

  /// Its code unit offset.
  final int start;

  /// Whether the unit ends with a zero width joiner.
  bool endsWithJoiner = false;

  bool get eastAsian => flags & _eastAsian != 0;
  bool get initial => flags & _initialPunctuation != 0;
  bool get finalPunctuation => flags & _finalPunctuation != 0;
  bool get unassignedPictographic => flags & _unassignedPictographic != 0;

  /// AK, U+25CC DOTTED CIRCLE, or AS (the `(AK | [◌] | AS)` of LB28a).
  bool get aksara =>
      cls == LineBreakClass.ak ||
      codePoint == 0x25cc ||
      cls == LineBreakClass.as_;

  /// AK or U+25CC DOTTED CIRCLE.
  bool get aksaraOrCircle => cls == LineBreakClass.ak || codePoint == 0x25cc;
}

/// The break opportunities in [text], in order: every position the
/// default rules of UAX #14 allow a break at, and the end of the text
/// (mandatory). A break at offset 0 is never reported.
List<LineBreak> lineBreaks(String text) {
  final units = _units(text);
  final breaks = <LineBreak>[];
  for (var i = 1; i < units.length; i++) {
    final decision = _decide(units, i);
    if (decision != _Decision.keep) {
      breaks.add(
        LineBreak(units[i].start, mandatory: decision == _Decision.mandatory),
      );
    }
  }
  if (text.isNotEmpty) breaks.add(LineBreak(text.length, mandatory: true));
  return breaks;
}

/// The characters of [text] as units: classes resolved (LB1), combining
/// marks attached to their base (LB9) or made alphabetic (LB10).
List<_Unit> _units(String text) {
  final units = <_Unit>[];
  var offset = 0;
  for (final rune in text.runes) {
    final properties = _properties(rune);
    final original = LineBreakClass.values[properties & 0x3f];
    final cls = switch (original) {
      LineBreakClass.ai ||
      LineBreakClass.sg ||
      LineBreakClass.xx => LineBreakClass.al,
      LineBreakClass.sa when properties & _combiningMark != 0 =>
        LineBreakClass.cm,
      LineBreakClass.sa => LineBreakClass.al,
      LineBreakClass.cj => LineBreakClass.ns,
      final c => c,
    };
    final start = offset;
    offset += rune > 0xffff ? 2 : 1;
    if (cls == LineBreakClass.cm || cls == LineBreakClass.zwj) {
      final base = units.lastOrNull;
      if (base != null && !_noBase.contains(base.cls)) {
        // LB9: part of the base's unit.
        base.endsWithJoiner = cls == LineBreakClass.zwj;
        continue;
      }
      // LB10: as if it were U+0041 A.
      units.add(
        _Unit(LineBreakClass.al, 0, 0x41, start)
          ..endsWithJoiner = cls == LineBreakClass.zwj,
      );
      continue;
    }
    units.add(_Unit(cls, properties, rune, start));
  }
  return units;
}

const Set<LineBreakClass> _noBase = {
  LineBreakClass.bk,
  LineBreakClass.cr,
  LineBreakClass.lf,
  LineBreakClass.nl,
  LineBreakClass.sp,
  LineBreakClass.zw,
};

enum _Decision { keep, allow, mandatory }

/// Whether the text may break between `units[i - 1]` and `units[i]`.
_Decision _decide(List<_Unit> units, int i) {
  final before = units[i - 1];
  final after = units[i];
  final b = before.cls;
  final a = after.cls;
  LineBreakClass? at(int index) =>
      index >= 0 && index < units.length ? units[index].cls : null;

  /// The index of the unit before the spaces that end just before [i].
  int beforeSpaces(int index) {
    var j = index - 1;
    while (j >= 0 && units[j].cls == LineBreakClass.sp) {
      j--;
    }
    return j;
  }

  // LB4, LB5: hard line breaks.
  if (b == LineBreakClass.bk) return _Decision.mandatory;
  if (b == LineBreakClass.cr && a == LineBreakClass.lf) return _Decision.keep;
  if (b == LineBreakClass.cr ||
      b == LineBreakClass.lf ||
      b == LineBreakClass.nl) {
    return _Decision.mandatory;
  }
  // LB6.
  if (a == LineBreakClass.bk ||
      a == LineBreakClass.cr ||
      a == LineBreakClass.lf ||
      a == LineBreakClass.nl) {
    return _Decision.keep;
  }
  // LB7.
  if (a == LineBreakClass.sp || a == LineBreakClass.zw) return _Decision.keep;
  // LB8: ZW SP* ÷
  final spaced = beforeSpaces(i);
  if (spaced >= 0 && units[spaced].cls == LineBreakClass.zw) {
    return _Decision.allow;
  }
  // LB8a.
  if (before.endsWithJoiner) return _Decision.keep;
  // LB11.
  if (a == LineBreakClass.wj || b == LineBreakClass.wj) return _Decision.keep;
  // LB12.
  if (b == LineBreakClass.gl) return _Decision.keep;
  // LB12a.
  if (a == LineBreakClass.gl &&
      b != LineBreakClass.sp &&
      b != LineBreakClass.hy &&
      b != LineBreakClass.hh) {
    return _Decision.keep;
  }
  // LB13.
  if (a == LineBreakClass.cl ||
      a == LineBreakClass.cp ||
      a == LineBreakClass.ex ||
      a == LineBreakClass.sy) {
    return _Decision.keep;
  }
  // LB14: OP SP* ×
  if (spaced >= 0 && units[spaced].cls == LineBreakClass.op) {
    return _Decision.keep;
  }
  // LB15a: (sot | BK | CR | LF | NL | OP | QU | GL | SP | ZW) [Pi&QU] SP* ×
  if (spaced >= 0 &&
      units[spaced].cls == LineBreakClass.qu &&
      units[spaced].initial) {
    final previous = at(spaced - 1);
    if (previous == null || _beforeInitialQuote.contains(previous)) {
      return _Decision.keep;
    }
  }
  // LB15b: × [Pf&QU] (SP | GL | WJ | CL | QU | CP | EX | IS | SY | BK | CR |
  // LF | NL | ZW | eot)
  if (a == LineBreakClass.qu && after.finalPunctuation) {
    final next = at(i + 1);
    if (next == null || _afterFinalQuote.contains(next)) return _Decision.keep;
  }
  // LB15c: SP ÷ IS NU
  if (b == LineBreakClass.sp &&
      a == LineBreakClass.is_ &&
      at(i + 1) == LineBreakClass.nu) {
    return _Decision.allow;
  }
  // LB15d.
  if (a == LineBreakClass.is_) return _Decision.keep;
  // LB16: (CL | CP) SP* × NS
  if (a == LineBreakClass.ns &&
      spaced >= 0 &&
      (units[spaced].cls == LineBreakClass.cl ||
          units[spaced].cls == LineBreakClass.cp)) {
    return _Decision.keep;
  }
  // LB17: B2 SP* × B2
  if (a == LineBreakClass.b2 &&
      spaced >= 0 &&
      units[spaced].cls == LineBreakClass.b2) {
    return _Decision.keep;
  }
  // LB18.
  if (b == LineBreakClass.sp) return _Decision.allow;
  // LB19.
  if (a == LineBreakClass.qu && !after.initial) return _Decision.keep;
  if (b == LineBreakClass.qu && !before.finalPunctuation) {
    return _Decision.keep;
  }
  // LB19a.
  if (a == LineBreakClass.qu) {
    if (!before.eastAsian) return _Decision.keep;
    if (i + 1 >= units.length || !units[i + 1].eastAsian) {
      return _Decision.keep;
    }
  }
  if (b == LineBreakClass.qu) {
    if (!after.eastAsian) return _Decision.keep;
    if (i - 2 < 0 || !units[i - 2].eastAsian) return _Decision.keep;
  }
  // LB20.
  if (a == LineBreakClass.cb || b == LineBreakClass.cb) return _Decision.allow;
  // LB20a: (sot | BK | CR | LF | NL | SP | ZW | CB | GL) (HY | HH) ×
  // (AL | HL)
  if ((b == LineBreakClass.hy || b == LineBreakClass.hh) &&
      (a == LineBreakClass.al || a == LineBreakClass.hl)) {
    final previous = at(i - 2);
    if (previous == null || _beforeWordInitialHyphen.contains(previous)) {
      return _Decision.keep;
    }
  }
  // LB21.
  if (a == LineBreakClass.ba ||
      a == LineBreakClass.hh ||
      a == LineBreakClass.hy ||
      a == LineBreakClass.ns ||
      b == LineBreakClass.bb) {
    return _Decision.keep;
  }
  // LB21a: HL (HY | HH) × [^HL]
  if ((b == LineBreakClass.hy || b == LineBreakClass.hh) &&
      at(i - 2) == LineBreakClass.hl &&
      a != LineBreakClass.hl) {
    return _Decision.keep;
  }
  // LB21b.
  if (b == LineBreakClass.sy && a == LineBreakClass.hl) return _Decision.keep;
  // LB22.
  if (a == LineBreakClass.in_) return _Decision.keep;
  final letterBefore = b == LineBreakClass.al || b == LineBreakClass.hl;
  final letterAfter = a == LineBreakClass.al || a == LineBreakClass.hl;
  // LB23.
  if (letterBefore && a == LineBreakClass.nu) return _Decision.keep;
  if (b == LineBreakClass.nu && letterAfter) return _Decision.keep;
  // LB23a.
  if (b == LineBreakClass.pr &&
      (a == LineBreakClass.id ||
          a == LineBreakClass.eb ||
          a == LineBreakClass.em)) {
    return _Decision.keep;
  }
  if ((b == LineBreakClass.id ||
          b == LineBreakClass.eb ||
          b == LineBreakClass.em) &&
      a == LineBreakClass.po) {
    return _Decision.keep;
  }
  // LB24.
  if ((b == LineBreakClass.pr || b == LineBreakClass.po) && letterAfter) {
    return _Decision.keep;
  }
  if (letterBefore && (a == LineBreakClass.pr || a == LineBreakClass.po)) {
    return _Decision.keep;
  }
  // LB25.
  if (_lb25(units, i)) return _Decision.keep;
  // LB26.
  if (b == LineBreakClass.jl &&
      (a == LineBreakClass.jl ||
          a == LineBreakClass.jv ||
          a == LineBreakClass.h2 ||
          a == LineBreakClass.h3)) {
    return _Decision.keep;
  }
  if ((b == LineBreakClass.jv || b == LineBreakClass.h2) &&
      (a == LineBreakClass.jv || a == LineBreakClass.jt)) {
    return _Decision.keep;
  }
  if ((b == LineBreakClass.jt || b == LineBreakClass.h3) &&
      a == LineBreakClass.jt) {
    return _Decision.keep;
  }
  // LB27.
  if (_korean.contains(b) && a == LineBreakClass.po) return _Decision.keep;
  if (b == LineBreakClass.pr && _korean.contains(a)) return _Decision.keep;
  // LB28.
  if (letterBefore && letterAfter) return _Decision.keep;
  // LB28a.
  if (b == LineBreakClass.ap && after.aksara) return _Decision.keep;
  if (before.aksara && (a == LineBreakClass.vf || a == LineBreakClass.vi)) {
    return _Decision.keep;
  }
  if (b == LineBreakClass.vi &&
      i >= 2 &&
      units[i - 2].aksara &&
      after.aksaraOrCircle) {
    return _Decision.keep;
  }
  if (before.aksara && after.aksara && at(i + 1) == LineBreakClass.vf) {
    return _Decision.keep;
  }
  // LB29.
  if (b == LineBreakClass.is_ && letterAfter) return _Decision.keep;
  // LB30.
  if ((letterBefore || b == LineBreakClass.nu) &&
      a == LineBreakClass.op &&
      !after.eastAsian) {
    return _Decision.keep;
  }
  if (b == LineBreakClass.cp &&
      !before.eastAsian &&
      (letterAfter || a == LineBreakClass.nu)) {
    return _Decision.keep;
  }
  // LB30a: an odd number of regional indicators before.
  if (b == LineBreakClass.ri && a == LineBreakClass.ri) {
    var count = 0;
    for (var j = i - 1; j >= 0 && units[j].cls == LineBreakClass.ri; j--) {
      count++;
    }
    if (count.isOdd) return _Decision.keep;
  }
  // LB30b.
  if (a == LineBreakClass.em &&
      (b == LineBreakClass.eb || before.unassignedPictographic)) {
    return _Decision.keep;
  }
  // LB31.
  return _Decision.allow;
}

/// LB25: no break inside numbers.
bool _lb25(List<_Unit> units, int i) {
  final b = units[i - 1].cls;
  final a = units[i].cls;
  LineBreakClass? at(int index) =>
      index >= 0 && index < units.length ? units[index].cls : null;

  /// Whether `NU (SY | IS)*` ends at [end] (inclusive).
  bool number(int end) {
    var j = end;
    while (j >= 0 &&
        (units[j].cls == LineBreakClass.sy ||
            units[j].cls == LineBreakClass.is_)) {
      j--;
    }
    return j >= 0 && units[j].cls == LineBreakClass.nu;
  }

  final prefixOrPostfix = a == LineBreakClass.po || a == LineBreakClass.pr;
  // NU (SY | IS)* (CL | CP) × (PO | PR)
  if (prefixOrPostfix &&
      (b == LineBreakClass.cl || b == LineBreakClass.cp) &&
      number(i - 2)) {
    return true;
  }
  // NU (SY | IS)* × (PO | PR)
  if (prefixOrPostfix && number(i - 1)) return true;
  if (b == LineBreakClass.po || b == LineBreakClass.pr) {
    // (PO | PR) × OP NU, (PO | PR) × OP IS NU, (PO | PR) × NU
    if (a == LineBreakClass.op) {
      if (at(i + 1) == LineBreakClass.nu) return true;
      if (at(i + 1) == LineBreakClass.is_ && at(i + 2) == LineBreakClass.nu) {
        return true;
      }
    }
    if (a == LineBreakClass.nu) return true;
  }
  // HY × NU, IS × NU
  if ((b == LineBreakClass.hy || b == LineBreakClass.is_) &&
      a == LineBreakClass.nu) {
    return true;
  }
  // NU (SY | IS)* × NU
  if (a == LineBreakClass.nu && number(i - 1)) return true;
  return false;
}

const Set<LineBreakClass> _beforeInitialQuote = {
  LineBreakClass.bk,
  LineBreakClass.cr,
  LineBreakClass.lf,
  LineBreakClass.nl,
  LineBreakClass.op,
  LineBreakClass.qu,
  LineBreakClass.gl,
  LineBreakClass.sp,
  LineBreakClass.zw,
};

const Set<LineBreakClass> _afterFinalQuote = {
  LineBreakClass.sp,
  LineBreakClass.gl,
  LineBreakClass.wj,
  LineBreakClass.cl,
  LineBreakClass.qu,
  LineBreakClass.cp,
  LineBreakClass.ex,
  LineBreakClass.is_,
  LineBreakClass.sy,
  LineBreakClass.bk,
  LineBreakClass.cr,
  LineBreakClass.lf,
  LineBreakClass.nl,
  LineBreakClass.zw,
};

const Set<LineBreakClass> _beforeWordInitialHyphen = {
  LineBreakClass.bk,
  LineBreakClass.cr,
  LineBreakClass.lf,
  LineBreakClass.nl,
  LineBreakClass.sp,
  LineBreakClass.zw,
  LineBreakClass.cb,
  LineBreakClass.gl,
};

const Set<LineBreakClass> _korean = {
  LineBreakClass.jl,
  LineBreakClass.jv,
  LineBreakClass.jt,
  LineBreakClass.h2,
  LineBreakClass.h3,
};

/// MathML (Presentation markup, the elements MathML Core lays out) read
/// into a tree of [MathNode]s for the math layout.
library;

import 'package:libpdf/src/drawing/color.dart';
import 'package:libpdf/src/svg/css_color.dart';
import 'package:xml/xml.dart';

/// A node of a math formula.
sealed class MathNode {
  const new();
}

/// What a token is: an identifier (`mi`), a number (`mn`), an operator
/// (`mo`) or text (`mtext`).
enum MathTokenKind {
  /// `mi`.
  identifier,

  /// `mn`.
  number,

  /// `mo`.
  operator,

  /// `mtext`.
  text,
}

/// A token: an identifier, a number, an operator or text.
final class MathToken extends MathNode {
  /// A token of [kind] with [text].
  const new(
    this.kind,
    this.text, {
    this.variant,
    this.stretchy,
    this.largeOperator,
    this.movableLimits,
    this.fence,
    this.form,
  });

  /// Its kind.
  final MathTokenKind kind;

  /// Its text.
  final String text;

  /// Its `mathvariant` (`normal`, `bold`, `italic`...), if set.
  final String? variant;

  /// Its `stretchy`, if set (operators).
  final bool? stretchy;

  /// Its `largeop`, if set (operators).
  final bool? largeOperator;

  /// Its `movablelimits`, if set (operators).
  final bool? movableLimits;

  /// Its `fence`, if set (operators).
  final bool? fence;

  /// Its `form` (`prefix`, `infix`, `postfix`), if set (operators).
  final String? form;
}

/// Nodes in a row (`math`, `mrow`, and a single-child stand-in for any
/// element with several children).
final class MathRow extends MathNode {
  /// A row of [children].
  const new(this.children);

  /// The nodes, left to right.
  final List<MathNode> children;
}

/// A node set in another style (`mstyle`, or any element's own
/// `mathcolor`, `displaystyle` and `scriptlevel`).
final class MathStyled extends MathNode {
  /// [child] in the style set.
  const new(
    this.child, {
    this.display,
    this.scriptLevel,
    this.color,
    this.variant,
  });

  /// The node.
  final MathNode child;

  /// Display style (`displaystyle`), if set.
  final bool? display;

  /// The script level (`scriptlevel`: a number, or `+1`, `-1` relative),
  /// if set.
  final String? scriptLevel;

  /// The color (`mathcolor`), if set.
  final PdfColor? color;

  /// The tokens' `mathvariant` (`mstyle`), if set.
  final String? variant;
}

/// A base with a subscript, a superscript or both (`msub`, `msup`,
/// `msubsup`).
final class MathScripts extends MathNode {
  /// [base] with [sub] and [sup].
  const new(this.base, {this.sub, this.sup});

  /// The base.
  final MathNode base;

  /// The subscript.
  final MathNode? sub;

  /// The superscript.
  final MathNode? sup;
}

/// A base with something under it, over it or both (`munder`, `mover`,
/// `munderover`).
final class MathUnderOver extends MathNode {
  /// [base] with [under] and [over].
  const new(
    this.base, {
    this.under,
    this.over,
    this.accent = false,
    this.accentUnder = false,
  });

  /// The base.
  final MathNode base;

  /// What is under it.
  final MathNode? under;

  /// What is over it.
  final MathNode? over;

  /// Whether [over] is an accent (`accent`).
  final bool accent;

  /// Whether [under] is an accent (`accentunder`).
  final bool accentUnder;
}

/// A fraction (`mfrac`).
final class MathFraction extends MathNode {
  /// [numerator] over [denominator].
  const new(this.numerator, this.denominator, {this.lineThickness});

  /// The numerator.
  final MathNode numerator;

  /// The denominator.
  final MathNode denominator;

  /// The rule's thickness (`linethickness`: `0` for none), if set.
  final String? lineThickness;
}

/// A square root (`msqrt`) or a root with an index (`mroot`).
final class MathRadical extends MathNode {
  /// The root of [radicand], of [index] when given.
  const new(this.radicand, {this.index});

  /// What the root is of.
  final MathNode radicand;

  /// The index (`mroot`).
  final MathNode? index;
}

/// A table (`mtable`): rows of cells.
final class MathTable extends MathNode {
  /// A table of [rows].
  const new(this.rows, {this.columnAlign});

  /// The cells, row by row.
  final List<List<MathNode>> rows;

  /// The columns' alignment (`columnalign`: `left`, `center`, `right`
  /// separated by spaces), if set.
  final String? columnAlign;
}

/// A node with a notation around or through it (`menclose`).
final class MathEnclose extends MathNode {
  /// [child] with [notations].
  const new(this.child, this.notations);

  /// The node.
  final MathNode child;

  /// The notations (`box`, `roundedbox`, `circle`, `updiagonalstrike`,
  /// `downdiagonalstrike`, `horizontalstrike`, `top`, `bottom`, `left`,
  /// `right`...).
  final List<String> notations;
}

/// Space (`mspace`).
final class MathSpace extends MathNode {
  /// Space [width] wide (a length: `0.5em`, `3pt`...).
  const new(this.width);

  /// The width.
  final String? width;
}

/// A MathML document that couldn't be read.
final class MathMLException implements Exception {
  /// An exception with [message].
  const new(this.message);

  /// What is wrong.
  final String message;

  @override
  String toString() => 'MathMLException: $message';
}

/// The formula of the MathML in [text] (a `math` element, its elements
/// with or without a namespace prefix).
MathNode parseMathML(String text) {
  final XmlDocument document;
  try {
    document = XmlDocument.parse(text);
  } on XmlException catch (error) {
    throw MathMLException(error.message);
  }
  return _node(document.rootElement);
}

List<XmlElement> _children(XmlElement element) =>
    element.children.whereType<XmlElement>().toList();

MathNode _row(List<XmlElement> elements) => elements.length == 1
    ? _node(elements.single)
    : MathRow([for (final e in elements) _node(e)]);

bool? _bool(String? value) => switch (value) {
  'true' => true,
  'false' => false,
  _ => null,
};

MathNode _node(XmlElement element) {
  final name = element.name.local;
  final children = _children(element);
  MathNode child(int i) =>
      i < children.length ? _node(children[i]) : const MathRow([]);
  final node = switch (name) {
    'mi' => MathToken(
      MathTokenKind.identifier,
      element.innerText.trim(),
      variant: element.getAttribute('mathvariant'),
    ),
    'mn' => MathToken(
      MathTokenKind.number,
      element.innerText.trim(),
      variant: element.getAttribute('mathvariant'),
    ),
    'mo' => MathToken(
      MathTokenKind.operator,
      element.innerText.trim(),
      variant: element.getAttribute('mathvariant'),
      stretchy: _bool(element.getAttribute('stretchy')),
      largeOperator: _bool(element.getAttribute('largeop')),
      movableLimits: _bool(element.getAttribute('movablelimits')),
      fence: _bool(element.getAttribute('fence')),
      form: element.getAttribute('form'),
    ),
    'mtext' || 'ms' => MathToken(
      MathTokenKind.text,
      element.innerText,
      variant: element.getAttribute('mathvariant'),
    ),
    'msub' => MathScripts(child(0), sub: child(1)),
    'msup' => MathScripts(child(0), sup: child(1)),
    'msubsup' => MathScripts(child(0), sub: child(1), sup: child(2)),
    'munder' => MathUnderOver(
      child(0),
      under: child(1),
      accentUnder: _bool(element.getAttribute('accentunder')) ?? false,
    ),
    'mover' => MathUnderOver(
      child(0),
      over: child(1),
      accent: _bool(element.getAttribute('accent')) ?? false,
    ),
    'munderover' => MathUnderOver(
      child(0),
      under: child(1),
      over: child(2),
      accent: _bool(element.getAttribute('accent')) ?? false,
      accentUnder: _bool(element.getAttribute('accentunder')) ?? false,
    ),
    'mfrac' => MathFraction(
      child(0),
      child(1),
      lineThickness: element.getAttribute('linethickness'),
    ),
    'msqrt' => MathRadical(_row(children)),
    'mroot' => MathRadical(child(0), index: child(1)),
    'mtable' => MathTable([
      for (final row in children)
        if (row.name.local == 'mtr' || row.name.local == 'mlabeledtr')
          [
            for (final cell in _children(row))
              if (cell.name.local == 'mtd') _row(_children(cell)),
          ],
    ], columnAlign: element.getAttribute('columnalign')),
    'menclose' => MathEnclose(
      _row(children),
      (element.getAttribute('notation') ?? 'longdiv')
          .split(RegExp(r'\s+'))
          .where((n) => n.isNotEmpty)
          .toList(),
    ),
    'mspace' => MathSpace(element.getAttribute('width')),
    'mfenced' => MathRow([
      MathToken(
        MathTokenKind.operator,
        element.getAttribute('open') ?? '(',
        fence: true,
        stretchy: true,
      ),
      for (final (i, c) in children.indexed) ...[
        if (i > 0)
          MathToken(
            MathTokenKind.operator,
            (element.getAttribute('separators') ?? ',').trim().isEmpty
                ? ''
                : (element.getAttribute('separators') ?? ',').trim()[0],
          ),
        _node(c),
      ],
      MathToken(
        MathTokenKind.operator,
        element.getAttribute('close') ?? ')',
        fence: true,
        stretchy: true,
      ),
    ]),
    'semantics' => child(0),
    'annotation' ||
    'annotation-xml' ||
    'none' ||
    'mprescripts' => const MathRow([]),
    // math, mrow, mstyle, mpadded, mphantom, merror, and the unknown.
    _ => _row(children),
  };
  final display = switch (element.getAttribute('displaystyle')) {
    final v? => _bool(v),
    null when name == 'math' =>
      element.getAttribute('display') == 'block' ? true : null,
    null => null,
  };
  final scriptLevel = element.getAttribute('scriptlevel');
  final color = switch (parseCssColor(
    element.getAttribute('mathcolor') ?? '',
  )) {
    (:final red, :final green, :final blue, alpha: _)? => RgbColor(
      red,
      green,
      blue,
    ),
    null => null,
  };
  final variant = name == 'mstyle' ? element.getAttribute('mathvariant') : null;
  if (display == null &&
      scriptLevel == null &&
      color == null &&
      variant == null) {
    return node;
  }
  return MathStyled(
    node,
    display: display,
    scriptLevel: scriptLevel,
    color: color,
    variant: variant,
  );
}

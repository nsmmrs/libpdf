/// The CSS subset SVG documents use in `<style>` elements: rules of
/// simple selectors (type, `.class`, `#id`, `*`, compounds of them) joined
/// by descendant and child combinators, and declarations. At-rules
/// (`@media`, `@font-face`...) are skipped.
library;

import 'package:xml/xml.dart';

/// A style rule: its selector and declarations.
final class CssRule {
  /// A rule of [selector] with [declarations], [order]th in the sheet.
  const new(this.selector, this.declarations, this.order);

  /// The selector.
  final CssSelector selector;

  /// The declarations, in order.
  final List<(String, String)> declarations;

  /// The rule's position in the sheet.
  final int order;
}

/// A compound selector: an element type and classes, an id.
final class _Compound {
  const new(this.type, this.id, this.classes);

  final String? type;
  final String? id;
  final List<String> classes;

  bool matches(XmlElement element) {
    if (type != null && element.localName != type) return false;
    if (id != null && element.getAttribute('id') != id) return false;
    if (classes.isNotEmpty) {
      final have = (element.getAttribute('class') ?? '').split(RegExp(r'\s+'));
      if (!classes.every(have.contains)) return false;
    }
    return true;
  }
}

/// A selector: compounds joined by combinators (`true` for a child
/// combinator `>`, `false` for a descendant).
final class CssSelector {
  /// A selector of compounds and the combinators between them.
  const new(this._parts, this._child);

  final List<_Compound> _parts;
  final List<bool> _child;

  /// The specificity: ids, classes, types.
  (int, int, int) get specificity => (
    _parts.where((p) => p.id != null).length,
    _parts.fold(0, (n, p) => n + p.classes.length),
    _parts.where((p) => p.type != null).length,
  );

  /// Whether [element] matches.
  bool matches(XmlElement element) => _matchFrom(element, _parts.length - 1);

  bool _matchFrom(XmlElement element, int index) {
    if (!_parts[index].matches(element)) return false;
    if (index == 0) return true;
    var parent = element.parentElement;
    if (_child[index - 1]) {
      return parent != null && _matchFrom(parent, index - 1);
    }
    while (parent != null) {
      if (_matchFrom(parent, index - 1)) return true;
      parent = parent.parentElement;
    }
    return false;
  }

  /// The selector [text], or null when it uses what isn't supported.
  static CssSelector? parse(String text) {
    final parts = <_Compound>[];
    final child = <bool>[];
    final tokens = text
        .replaceAll('>', ' > ')
        .trim()
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .toList();
    var pendingChild = false;
    for (final token in tokens) {
      if (token == '>') {
        pendingChild = true;
        continue;
      }
      final match = RegExp(r'^(\*|[a-zA-Z][\w-]*)?((?:[.#][\w-]+)*)$')
          .firstMatch(token);
      if (match == null) return null;
      final type = match[1] == '*' ? null : match[1];
      String? id;
      final classes = <String>[];
      for (final m in RegExp(r'([.#])([\w-]+)').allMatches(match[2]!)) {
        if (m[1] == '#') {
          id = m[2];
        } else {
          classes.add(m[2]!);
        }
      }
      if (parts.isNotEmpty) child.add(pendingChild);
      pendingChild = false;
      parts.add(_Compound(type, id, classes));
    }
    if (parts.isEmpty) return null;
    return CssSelector(parts, child);
  }
}

/// The declarations of a `style` attribute or a rule body.
List<(String, String)> parseDeclarations(String text) => [
  for (final declaration in text.split(';'))
    if (declaration.indexOf(':') case final colon when colon > 0)
      (
        declaration.substring(0, colon).trim().toLowerCase(),
        declaration
            .substring(colon + 1)
            .replaceAll(RegExp(r'!\s*important', caseSensitive: false), '')
            .trim(),
      ),
];

/// The rules of a style sheet, and the selectors it skipped.
(List<CssRule>, List<String>) parseStyleSheet(String text) {
  final source = text.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');
  final rules = <CssRule>[];
  final skipped = <String>[];
  var at = 0;
  var order = 0;
  while (at < source.length) {
    final open = source.indexOf('{', at);
    if (open < 0) break;
    final prelude = source.substring(at, open).trim();
    // The block's end, counting nested braces (at-rules nest).
    var depth = 1;
    var close = open + 1;
    while (close < source.length && depth > 0) {
      if (source[close] == '{') depth++;
      if (source[close] == '}') depth--;
      close++;
    }
    final body = source.substring(open + 1, close - 1);
    at = close;
    if (prelude.startsWith('@')) {
      skipped.add(prelude.split(RegExp(r'\s')).first);
      continue;
    }
    final declarations = parseDeclarations(body);
    for (final selectorText in prelude.split(',')) {
      final selector = CssSelector.parse(selectorText);
      if (selector == null) {
        skipped.add(selectorText.trim());
        continue;
      }
      rules.add(CssRule(selector, declarations, order++));
    }
  }
  return (rules, skipped);
}

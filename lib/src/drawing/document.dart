/// A document of pages drawn through canvases, with links, named
/// destinations, outlines (bookmarks) and page labels, written with a
/// `PdfWriter` when saved.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:libpdf/src/drawing/canvas.dart';
import 'package:libpdf/src/drawing/color.dart';
import 'package:libpdf/src/drawing/geometry.dart';
import 'package:libpdf/src/drawing/shading.dart';
import 'package:libpdf/src/fonts/fonts.dart';
import 'package:libpdf/src/images/images.dart';
import 'package:libpdf/src/objects.dart';
import 'package:libpdf/src/writer.dart';
import 'package:meta/meta.dart';

/// A page: its boxes, its content and its links.
final class PdfPage {
  new _(
    this.mediaBox, {
    this.cropBox,
    this.bleedBox,
    this.trimBox,
    this.artBox,
    this.rotation = 0,
  });

  /// The page's extent (`MediaBox`).
  final PdfRect mediaBox;

  /// The region shown and printed (`CropBox`); the media box by default.
  final PdfRect? cropBox;

  /// The region to clip to in production, with the bleed (`BleedBox`).
  final PdfRect? bleedBox;

  /// The finished page after trimming (`TrimBox`).
  final PdfRect? trimBox;

  /// The page's meaningful content (`ArtBox`).
  final PdfRect? artBox;

  /// The clockwise rotation when shown, a multiple of 90 degrees.
  final int rotation;

  /// The page's content.
  final PdfCanvas canvas = newCanvas();

  final List<(PdfRect, LinkTarget)> _links = [];

  /// Makes [rect] a link to [target].
  void link(PdfRect rect, LinkTarget target) => _links.add((rect, target));

  /// The page's width.
  double get width => mediaBox.width;

  /// The page's height.
  double get height => mediaBox.height;
}

/// A position in the document to go to (ISO 32000-2, 12.3.2.2).
@immutable
sealed class PdfDestination {
  const new _(this.page);

  /// The point ([left], [top]) of [page] at the top left of the window,
  /// at [zoom] (each kept as it is when null).
  const factory xyz(PdfPage page, {double? left, double? top, double? zoom}) =
      XyzDestination;

  /// The whole [page] in the window.
  const factory fit(PdfPage page) = FitDestination;

  /// [page] as wide as the window, with [top] at its top.
  const factory fitWidth(PdfPage page, {double? top}) = FitWidthDestination;

  /// The page.
  final PdfPage page;

  /// The destination as an array, with [pageRef] for its page.
  PdfArray _toArray(PdfRef pageRef);
}

/// A point of a page, at a zoom.
final class XyzDestination extends PdfDestination {
  /// The point ([left], [top]) of [page] at [zoom].
  const new(super.page, {this.left, this.top, this.zoom}) : super._();

  /// The left edge of the window, or null to keep it.
  final double? left;

  /// The top edge of the window, or null to keep it.
  final double? top;

  /// The zoom (1 is 100%), or null to keep it.
  final double? zoom;

  @override
  PdfArray _toArray(PdfRef pageRef) => PdfArray([
    pageRef,
    const PdfName('XYZ'),
    _number(left),
    _number(top),
    _number(zoom),
  ]);
}

/// A whole page.
final class FitDestination extends PdfDestination {
  /// The whole of [page].
  const new(super.page) : super._();

  @override
  PdfArray _toArray(PdfRef pageRef) =>
      PdfArray([pageRef, const PdfName('Fit')]);
}

/// A page as wide as the window.
final class FitWidthDestination extends PdfDestination {
  /// [page] as wide as the window, [top] at the top.
  const new(super.page, {this.top}) : super._();

  /// The top edge of the window, or null to keep it.
  final double? top;

  @override
  PdfArray _toArray(PdfRef pageRef) =>
      PdfArray([pageRef, const PdfName('FitH'), _number(top)]);
}

PdfObject _number(double? value) => switch (value) {
  null => const PdfNull(),
  final v when v == v.roundToDouble() && v.abs() < 1e15 => PdfInt(v.toInt()),
  final v => PdfReal(v),
};

/// Where a link or an outline item goes.
@immutable
sealed class LinkTarget {
  const new _();

  /// The web address [uri].
  const factory uri(String uri) = UriTarget;

  /// The named destination [name].
  const factory named(String name) = NamedTarget;

  /// The [destination].
  const factory destination(PdfDestination destination) = DestinationTarget;
}

/// A web address.
final class UriTarget extends LinkTarget {
  /// A link to [uri].
  const new(this.uri) : super._();

  /// The address.
  final String uri;
}

/// A named destination.
final class NamedTarget extends LinkTarget {
  /// A link to the destination [name].
  const new(this.name) : super._();

  /// The destination's name.
  final String name;
}

/// An explicit destination.
final class DestinationTarget extends LinkTarget {
  /// A link to [destination].
  const new(this.destination) : super._();

  /// The destination.
  final PdfDestination destination;
}

/// An item of the document outline (a bookmark), with its children.
final class PdfOutlineItem {
  /// An item titled [title] going to [target]; [open] shows its children.
  new(
    this.title,
    this.target, {
    this.open = false,
    this.bold = false,
    this.italic = false,
    this.color,
  });

  /// The title.
  final String title;

  /// Where the item goes.
  final LinkTarget? target;

  /// Whether the children are shown.
  final bool open;

  /// Whether the title is bold.
  final bool bold;

  /// Whether the title is italic.
  final bool italic;

  /// The title's color.
  final RgbColor? color;

  /// The children.
  final List<PdfOutlineItem> children = [];

  /// Adds a child titled [title] going to [target]; returns it.
  PdfOutlineItem add(
    String title,
    LinkTarget? target, {
    bool open = false,
    bool bold = false,
    bool italic = false,
    RgbColor? color,
  }) {
    final item = PdfOutlineItem(
      title,
      target,
      open: open,
      bold: bold,
      italic: italic,
      color: color,
    );
    children.add(item);
    return item;
  }

  /// The number of descendants shown when the item is shown.
  int get _visible => open
      ? children.length + children.fold<int>(0, (sum, c) => sum + c._visible)
      : 0;
}

/// How page numbers are written (ISO 32000-2, 12.4.2).
enum PageNumberStyle {
  /// 1, 2, 3...
  decimal('D'),

  /// I, II, III...
  upperRoman('R'),

  /// i, ii, iii...
  lowerRoman('r'),

  /// A, B, ... Z, AA...
  upperLetters('A'),

  /// a, b, ... z, aa...
  lowerLetters('a'),

  /// No number (the prefix only).
  none(null);

  new(this.pdfName);

  /// The style's PDF name, or null for none.
  final String? pdfName;
}

/// The labels of a range of pages: a [prefix], then the page number
/// from [start] in [style].
@immutable
final class PageLabel {
  /// Labels in [style] starting at [start], after [prefix].
  const new({
    this.style = PageNumberStyle.decimal,
    this.prefix,
    this.start = 1,
  });

  /// The numbering style.
  final PageNumberStyle style;

  /// The text before the number.
  final String? prefix;

  /// The number of the range's first page.
  final int start;
}

/// How a viewer shows the document when it opens.
enum PageMode {
  /// Neither outline nor thumbnails.
  useNone('UseNone'),

  /// With the outline.
  useOutlines('UseOutlines'),

  /// With page thumbnails.
  useThumbs('UseThumbs'),

  /// Full screen.
  fullScreen('FullScreen');

  new(this.pdfName);

  /// The mode's PDF name.
  final String pdfName;
}

/// A PDF document.
final class PdfDocument {
  /// An empty document with [info]; [language] is its natural language
  /// (`en-US`), [pageMode] how it opens, [displayTitle] whether viewers
  /// show the title rather than the file name.
  new({
    this.info = const PdfInfo(),
    this.language,
    this.pageMode,
    this.displayTitle = false,
  });

  /// The document information.
  final PdfInfo info;

  /// The natural language.
  final String? language;

  /// How the document opens.
  final PageMode? pageMode;

  /// Whether viewers show the title in the window's title bar.
  final bool displayTitle;

  final List<PdfPage> _pages = [];

  /// The pages, in order.
  List<PdfPage> get pages => List.unmodifiable(_pages);

  /// The outline's top-level items.
  final List<PdfOutlineItem> outline = [];

  final Map<String, PdfDestination> _destinations = {};

  final Map<int, PageLabel> _labels = {};

  /// Adds a page of [mediaBox] (with the other boxes) and returns it.
  PdfPage addPage(
    PdfRect mediaBox, {
    PdfRect? cropBox,
    PdfRect? bleedBox,
    PdfRect? trimBox,
    PdfRect? artBox,
    int rotation = 0,
  }) {
    if (rotation % 90 != 0) {
      throw ArgumentError.value(rotation, 'rotation', 'not a multiple of 90');
    }
    final page = PdfPage._(
      mediaBox,
      cropBox: cropBox,
      bleedBox: bleedBox,
      trimBox: trimBox,
      artBox: artBox,
      rotation: rotation,
    );
    _pages.add(page);
    return page;
  }

  /// Adds an outline item titled [title] going to [target]; returns it.
  PdfOutlineItem addOutline(
    String title,
    LinkTarget? target, {
    bool open = false,
    bool bold = false,
    bool italic = false,
    RgbColor? color,
  }) {
    final item = PdfOutlineItem(
      title,
      target,
      open: open,
      bold: bold,
      italic: italic,
      color: color,
    );
    outline.add(item);
    return item;
  }

  /// Names [destination] [name], for links and outline items (and for
  /// links from other documents, `file.pdf#name`).
  void addDestination(String name, PdfDestination destination) =>
      _destinations[name] = destination;

  /// Labels the pages from [pageIndex] (0-based) on, up to the next
  /// labeled index, with [label].
  void labelPages(int pageIndex, PageLabel label) => _labels[pageIndex] = label;

  /// The document as PDF bytes.
  Uint8List save({PdfWriterOptions options = const PdfWriterOptions()}) {
    final out = BytesBuilder(copy: false);
    saveTo(out.add, options: options);
    return out.takeBytes();
  }

  /// Writes the document to [sink].
  void saveTo(
    void Function(List<int> bytes) sink, {
    PdfWriterOptions options = const PdfWriterOptions(),
  }) {
    for (final (i, page) in _pages.indexed) {
      if (canvasUnbalanced(page.canvas) case final problem?) {
        throw StateError('page ${i + 1}: $problem');
      }
    }
    _Saver(this, PdfWriter(sink, options: options, version: _version)).save();
  }

  /// The lowest PDF version with every feature the document uses:
  /// transparency, `Lang` and `DisplayDocTitle` need 1.4, 16-bit images
  /// 1.5 (as do the object streams the writer raises the version for).
  String get _version {
    final seen = <PdfForm>{};
    bool deep(PdfCanvas canvas) => canvasResources(canvas).values.any(
      (entries) => entries.values.any(
        (resource) => switch (resource) {
          ImageResource(image: PngImage(bitDepth: 16)) => true,
          FormResource(:final form) => seen.add(form) && deep(formCanvas(form)),
          _ => false,
        },
      ),
    );
    return _pages.any((page) => deep(page.canvas)) ? '1.5' : '1.4';
  }
}

/// Writes a document's objects.
final class _Saver {
  new(this.document, this.writer);

  final PdfDocument document;
  final PdfWriter writer;
  final Map<PdfPage, PdfRef> _pageRefs = {};
  final Map<PdfForm, PdfRef> _formRefs = {};
  final List<PdfForm> _formQueue = [];
  final Set<PdfFont> _fonts = {};
  final Set<PdfImage> _images = {};
  final Map<(String, CmykColor), PdfArray> _separations = {};
  final Map<PdfShading, PdfRef> _shadings = Map.identity();

  void save() {
    final catalog = writer.reserve();
    final pages = writer.reserve();
    for (final page in document._pages) {
      _pageRefs[page] = writer.reserve();
    }
    for (final page in document._pages) {
      _writePage(page, pages);
    }
    // Forms can use forms: write until none is left.
    while (_formQueue.isNotEmpty) {
      final form = _formQueue.removeAt(0);
      _writeForm(form);
    }
    for (final font in _fonts) {
      font.writeTo(writer);
    }
    for (final image in _images) {
      image.writeTo(writer);
    }
    writer.write(
      PdfDict({
        'Type': const PdfName('Pages'),
        'Kids': PdfArray([
          for (final page in document._pages) _pageRefs[page]!,
        ]),
        'Count': PdfInt(document._pages.length),
      }),
      pages,
    );
    final info = writer.writeInfo(document.info);
    writer
      ..write(
        PdfDict({
          'Type': const PdfName('Catalog'),
          'Pages': pages,
          'Metadata': info.metadata,
          'Outlines': ?_writeOutline(),
          if (document._destinations.isNotEmpty)
            'Names': PdfDict({'Dests': _destinationTree()}),
          if (document._labels.isNotEmpty) 'PageLabels': _pageLabels(),
          if (document.pageMode case final mode?)
            'PageMode': PdfName(mode.pdfName),
          if (document.language case final language?)
            'Lang': PdfString.text(language),
          if (document.displayTitle)
            'ViewerPreferences': PdfDict({
              'DisplayDocTitle': const PdfBool(true),
            }),
        }),
        catalog,
      )
      ..close(root: catalog, info: info.info);
  }

  void _writePage(PdfPage page, PdfRef parent) {
    final content = writer.write(PdfStream(canvasContent(page.canvas)));
    final annotations = [
      for (final (rect, target) in page._links)
        writer.write(
          PdfDict({
            'Type': const PdfName('Annot'),
            'Subtype': const PdfName('Link'),
            'Rect': rect.toArray(),
            'Border': PdfArray.numbers([0, 0, 0]),
            ..._linkEntries(target),
          }),
        ),
    ];
    writer.write(
      PdfDict({
        'Type': const PdfName('Page'),
        'Parent': parent,
        'MediaBox': page.mediaBox.toArray(),
        'CropBox': ?page.cropBox?.toArray(),
        'BleedBox': ?page.bleedBox?.toArray(),
        'TrimBox': ?page.trimBox?.toArray(),
        'ArtBox': ?page.artBox?.toArray(),
        if (page.rotation % 360 != 0) 'Rotate': PdfInt(page.rotation % 360),
        'Resources': _resources(page.canvas),
        'Contents': content,
        if (annotations.isNotEmpty) 'Annots': PdfArray(annotations),
        if (canvasUsesTransparency(page.canvas)) 'Group': _group(null),
      }),
      _pageRefs[page],
    );
  }

  /// The `Dest` or `A` (action) entry for [target].
  Map<String, PdfObject> _linkEntries(LinkTarget target) => switch (target) {
    UriTarget(:final uri) => {
      'A': PdfDict({
        'S': const PdfName('URI'),
        'URI': PdfString(_asciiUri(uri)),
      }),
    },
    NamedTarget(:final name) => {'Dest': PdfString(utf8.encode(name))},
    DestinationTarget(:final destination) => {
      'Dest': destination._toArray(_pageRef(destination.page)),
    },
  };

  PdfRef _pageRef(PdfPage page) =>
      _pageRefs[page] ??
      (throw ArgumentError('a destination is on a page of another document'));

  /// [uri] in 7-bit ASCII, as PDF wants URIs: other characters as UTF-8
  /// percent escapes.
  static List<int> _asciiUri(String uri) => [
    for (final byte in utf8.encode(uri))
      if (byte < 0x80)
        byte
      else
        ...ascii.encode('%${byte.toRadixString(16).toUpperCase()}'),
  ];

  PdfDict _resources(PdfCanvas canvas) => PdfDict({
    for (final MapEntry(key: category, value: entries) in canvasResources(
      canvas,
    ).entries)
      category: PdfDict({
        for (final MapEntry(key: name, value: resource) in entries.entries)
          name: _resource(resource),
      }),
  });

  PdfObject _resource(Resource resource) {
    switch (resource) {
      case FontResource(:final font):
        _fonts.add(font);
        return font.reference(writer);
      case ImageResource(:final image):
        _images.add(image);
        return image.reference(writer);
      case FormResource(:final form):
        return _formRef(form);
      case ShadingResource(:final shading):
        return _shadings[shading] ??= writer.write(shadingDict(shading));
      case SeparationResource(:final name, :final alternate):
        return _separations[(name, alternate)] ??= PdfArray([
          const PdfName('Separation'),
          PdfName(name),
          const PdfName('DeviceCMYK'),
          PdfDict({
            'FunctionType': const PdfInt(2),
            'Domain': PdfArray.numbers([0, 1]),
            'C0': PdfArray.numbers([0, 0, 0, 0]),
            'C1': PdfArray.numbers(alternate.components),
            'N': const PdfInt(1),
          }),
        ]);
      case GraphicsStateResource(
        :final fillOpacity,
        :final strokeOpacity,
        :final blendMode,
        :final softMask,
        :final clearSoftMask,
      ):
        return PdfDict({
          'Type': const PdfName('ExtGState'),
          if (fillOpacity != null) 'ca': PdfReal(fillOpacity),
          if (strokeOpacity != null) 'CA': PdfReal(strokeOpacity),
          if (blendMode != null) 'BM': PdfName(blendMode.pdfName),
          if (softMask case (final form, final kind))
            'SMask': PdfDict({
              'Type': const PdfName('Mask'),
              'S': PdfName(kind.pdfName),
              'G': _formRef(form),
            }),
          if (clearSoftMask) 'SMask': const PdfName('None'),
        });
    }
  }

  PdfRef _formRef(PdfForm form) => _formRefs[form] ??= () {
    _formQueue.add(form);
    return writer.reserve();
  }();

  void _writeForm(PdfForm form) {
    writer.write(
      PdfStream(
        canvasContent(formCanvas(form)),
        dict: PdfDict({
          'Type': const PdfName('XObject'),
          'Subtype': const PdfName('Form'),
          'BBox': form.bbox.toArray(),
          'Matrix': ?form.matrix?.toArray(),
          'Resources': _resources(formCanvas(form)),
          if (form.group case final group?) 'Group': _group(group),
        }),
      ),
      _formRefs[form],
    );
  }

  PdfDict _group(TransparencyGroup? group) => PdfDict({
    'Type': const PdfName('Group'),
    'S': const PdfName('Transparency'),
    'CS': const PdfName('DeviceRGB'),
    if (group?.isolated ?? false) 'I': const PdfBool(true),
    if (group?.knockout ?? false) 'K': const PdfBool(true),
  });

  PdfRef? _writeOutline() {
    if (document.outline.isEmpty) return null;
    final root = writer.reserve();
    final (first, last) = _writeItems(document.outline, root);
    final visible =
        document.outline.length +
        document.outline.fold<int>(0, (sum, item) => sum + item._visible);
    writer.write(
      PdfDict({
        'Type': const PdfName('Outlines'),
        'First': first,
        'Last': last,
        'Count': PdfInt(visible),
      }),
      root,
    );
    return root;
  }

  /// Writes [items] under [parent]; returns the first and last.
  (PdfRef, PdfRef) _writeItems(List<PdfOutlineItem> items, PdfRef parent) {
    final refs = [for (final _ in items) writer.reserve()];
    for (final (i, item) in items.indexed) {
      final children = item.children.isEmpty
          ? null
          : _writeItems(item.children, refs[i]);
      final count = item.open ? item._visible : -item.children.length;
      final flags = (item.italic ? 1 : 0) | (item.bold ? 2 : 0);
      writer.write(
        PdfDict({
          'Title': PdfString.text(item.title),
          'Parent': parent,
          if (i > 0) 'Prev': refs[i - 1],
          if (i < items.length - 1) 'Next': refs[i + 1],
          if (children case (final first, final last)) ...{
            'First': first,
            'Last': last,
            'Count': PdfInt(count),
          },
          if (item.target case final target?) ..._linkEntries(target),
          if (item.color case final color?)
            'C': PdfArray.numbers(color.components),
          if (flags != 0) 'F': PdfInt(flags),
        }),
        refs[i],
      );
    }
    return (refs.first, refs.last);
  }

  /// The name tree of named destinations: one node, names in byte order.
  PdfDict _destinationTree() {
    final names = document._destinations.keys.toList()
      ..sort((a, b) => _compareBytes(utf8.encode(a), utf8.encode(b)));
    return PdfDict({
      'Names': PdfArray([
        for (final name in names) ...[
          PdfString(utf8.encode(name)),
          document._destinations[name]!._toArray(
            _pageRef(document._destinations[name]!.page),
          ),
        ],
      ]),
    });
  }

  static int _compareBytes(List<int> a, List<int> b) {
    for (var i = 0; i < a.length && i < b.length; i++) {
      if (a[i] != b[i]) return a[i] - b[i];
    }
    return a.length - b.length;
  }

  PdfDict _pageLabels() {
    final indices = document._labels.keys.toList()..sort();
    return PdfDict({
      'Nums': PdfArray([
        for (final index in indices) ...[
          PdfInt(index),
          () {
            final label = document._labels[index]!;
            return PdfDict({
              'Type': const PdfName('PageLabel'),
              if (label.style.pdfName case final style?) 'S': PdfName(style),
              if (label.prefix case final prefix?) 'P': PdfString.text(prefix),
              if (label.start != 1) 'St': PdfInt(label.start),
            });
          }(),
        ],
      ]),
    });
  }
}

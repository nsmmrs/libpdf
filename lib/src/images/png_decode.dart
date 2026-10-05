/// PNG scanline filtering (ISO/IEC 15948, 9) and Adam7 interlacing (8.2):
/// from the inflated image data to packed rows, and from packed rows back
/// to filtered data for a FlateDecode stream with a PNG predictor.
library;

import 'dart:typed_data';

/// The geometry of a PNG image's samples.
final class PngLayout {
  /// An image [width] by [height] pixels of [channels] samples, each
  /// [bitDepth] bits.
  const new(this.width, this.height, this.channels, this.bitDepth);

  /// The width, in pixels.
  final int width;

  /// The height, in pixels.
  final int height;

  /// The samples per pixel.
  final int channels;

  /// The bits per sample.
  final int bitDepth;

  /// The bytes of a packed row of [pixels] pixels.
  int rowBytes(int pixels) => (pixels * channels * bitDepth + 7) >> 3;

  /// The bytes per complete pixel (at least 1), the distance filters
  /// look back.
  int get pixelBytes => (channels * bitDepth + 7) >> 3;
}

/// The packed rows (no filter bytes) of an image laid out as [layout],
/// from its inflated, filtered [data].
Uint8List unfilterImage(
  Uint8List data,
  PngLayout layout, {
  required bool interlaced,
}) {
  if (!interlaced) {
    return _unfilter(
      data,
      0,
      layout.rowBytes(layout.width),
      layout.height,
      layout.pixelBytes,
    ).$1;
  }
  final stride = layout.rowBytes(layout.width);
  final image = Uint8List(stride * layout.height);
  var offset = 0;
  for (final (x0, y0, dx, dy) in _adam7) {
    final columns = (layout.width - x0 + dx - 1) ~/ dx;
    final rows = (layout.height - y0 + dy - 1) ~/ dy;
    if (columns <= 0 || rows <= 0) continue;
    final passStride = layout.rowBytes(columns);
    final (pass, end) = _unfilter(
      data,
      offset,
      passStride,
      rows,
      layout.pixelBytes,
    );
    offset = end;
    for (var r = 0; r < rows; r++) {
      final y = y0 + r * dy;
      for (var c = 0; c < columns; c++) {
        _copyPixel(
          pass,
          r * passStride,
          c,
          image,
          y * stride,
          x0 + c * dx,
          layout,
        );
      }
    }
  }
  return image;
}

/// The seven Adam7 passes: first column, first row, column step, row
/// step.
const List<(int, int, int, int)> _adam7 = [
  (0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), //
  (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2),
];

void _copyPixel(
  Uint8List from,
  int fromRow,
  int fromX,
  Uint8List to,
  int toRow,
  int toX,
  PngLayout layout,
) {
  final bits = layout.channels * layout.bitDepth;
  if (bits >= 8) {
    final bytes = bits >> 3;
    to.setRange(
      toRow + toX * bytes,
      toRow + (toX + 1) * bytes,
      from,
      fromRow + fromX * bytes,
    );
    return;
  }
  // 1, 2 or 4 bits per pixel (one channel): move the sample's bits.
  final mask = (1 << bits) - 1;
  final fromBit = fromX * bits;
  final sample =
      (from[fromRow + (fromBit >> 3)] >> (8 - bits - (fromBit & 7))) & mask;
  final toBit = toX * bits;
  final shift = 8 - bits - (toBit & 7);
  final index = toRow + (toBit >> 3);
  to[index] = (to[index] & ~(mask << shift)) | (sample << shift);
}

/// Unfilters [rows] rows of [stride] bytes starting at [offset] in
/// [data]; returns the packed rows and the offset after them.
(Uint8List, int) _unfilter(
  Uint8List data,
  int offset,
  int stride,
  int rows,
  int bpp,
) {
  final out = Uint8List(stride * rows);
  var at = offset;
  for (var r = 0; r < rows; r++) {
    if (at + 1 + stride > data.length) {
      throw const FormatException('PNG image data is truncated');
    }
    final filter = data[at];
    final row = r * stride;
    final previous = row - stride;
    for (var i = 0; i < stride; i++) {
      final raw = data[at + 1 + i];
      final left = i >= bpp ? out[row + i - bpp] : 0;
      final up = r > 0 ? out[previous + i] : 0;
      final upLeft = r > 0 && i >= bpp ? out[previous + i - bpp] : 0;
      out[row + i] = switch (filter) {
        0 => raw,
        1 => raw + left,
        2 => raw + up,
        3 => raw + ((left + up) >> 1),
        4 => raw + _paeth(left, up, upLeft),
        _ => throw FormatException('PNG filter type $filter is not defined'),
      };
    }
    at += 1 + stride;
  }
  return (out, at);
}

int _paeth(int a, int b, int c) {
  final p = a + b - c;
  final pa = (p - a).abs();
  final pb = (p - b).abs();
  final pc = (p - c).abs();
  if (pa <= pb && pa <= pc) return a;
  if (pb <= pc) return b;
  return c;
}

/// [image]'s packed rows of [stride] bytes filtered again, each row with
/// the filter that leaves the smallest sum of absolute differences (the
/// heuristic of the PNG specification, 12.8), for a FlateDecode stream
/// with predictor 15.
Uint8List filterImage(Uint8List image, int stride, int bpp) {
  final rows = stride == 0 ? 0 : image.length ~/ stride;
  final out = Uint8List(rows * (stride + 1));
  final candidate = Uint8List(stride);
  final best = Uint8List(stride);
  for (var r = 0; r < rows; r++) {
    final row = r * stride;
    var bestFilter = 0;
    var bestScore = -1;
    for (var filter = 0; filter <= 4; filter++) {
      var score = 0;
      for (var i = 0; i < stride; i++) {
        final left = i >= bpp ? image[row + i - bpp] : 0;
        final up = r > 0 ? image[row - stride + i] : 0;
        final upLeft = r > 0 && i >= bpp ? image[row - stride + i - bpp] : 0;
        final value =
            (image[row + i] -
                switch (filter) {
                  1 => left,
                  2 => up,
                  3 => (left + up) >> 1,
                  4 => _paeth(left, up, upLeft),
                  _ => 0,
                }) &
            0xff;
        candidate[i] = value;
        score += value < 128 ? value : 256 - value;
      }
      if (bestScore < 0 || score < bestScore) {
        bestScore = score;
        bestFilter = filter;
        best.setAll(0, candidate);
      }
    }
    final at = r * (stride + 1);
    out[at] = bestFilter;
    out.setRange(at + 1, at + 1 + stride, best);
  }
  return out;
}

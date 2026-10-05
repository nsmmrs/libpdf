/// Raster images as PDF image XObjects (ISO 32000-2, 8.9.5): JPEG files
/// pass through as DCTDecode streams; PNG files pass through as
/// FlateDecode streams with a PNG predictor when PDF can show them as
/// they are, and are decoded otherwise (alpha becomes a soft mask,
/// interlaced images are de-interlaced).
library;

import 'dart:typed_data';

import 'package:libpdf/src/flate.dart';
import 'package:libpdf/src/images/exif.dart';
import 'package:libpdf/src/images/png_decode.dart';
import 'package:libpdf/src/objects.dart';
import 'package:libpdf/src/writer.dart';

/// An image file libpdf can't read.
final class ImageFormatException implements Exception {
  /// An exception with [message].
  const new(this.message);

  /// What is wrong with the image.
  final String message;

  @override
  String toString() => 'ImageFormatException: $message';
}

/// A raster image, drawn as an image XObject.
sealed class PdfImage {
  new _();

  /// The JPEG or PNG image in [bytes], told apart by their signatures.
  factory parse(Uint8List bytes) {
    if (bytes.length >= 3 && bytes[0] == 0xff && bytes[1] == 0xd8) {
      return JpegImage.parse(bytes);
    }
    if (_startsWith(bytes, _pngSignature)) return PngImage.parse(bytes);
    throw const ImageFormatException('not a JPEG or PNG image');
  }

  /// The width, in pixels.
  int get width;

  /// The height, in pixels.
  int get height;

  /// The EXIF orientation (1–8; 1 is upright). It is reported, not
  /// applied: placing the image is up to the caller.
  int get orientation;

  /// The reference the image is written under, reserved from [writer].
  PdfRef reference(PdfWriter writer) =>
      _references[writer] ??= writer.reserve();

  final Expando<PdfRef> _references = Expando<PdfRef>();

  /// Writes the image's objects to [writer].
  void writeTo(PdfWriter writer);
}

/// A JPEG image, embedded as it is (DCTDecode).
final class JpegImage extends PdfImage {
  new _(
    this.bytes, {
    required this.width,
    required this.height,
    required this.components,
    required this.bitsPerComponent,
    required this.progressive,
    required this.adobe,
    required this.orientation,
  }) : super._();

  /// The JPEG image in [bytes].
  factory parse(Uint8List bytes) {
    if (bytes.length < 4 || bytes[0] != 0xff || bytes[1] != 0xd8) {
      throw const ImageFormatException('not a JPEG image');
    }
    final view = ByteData.sublistView(bytes);
    var adobe = false;
    var orientation = 1;
    var at = 2;
    while (at + 4 <= bytes.length) {
      if (bytes[at] != 0xff) {
        throw ImageFormatException('JPEG marker expected at byte $at');
      }
      final marker = bytes[at + 1];
      if (marker == 0xff) {
        at += 1; // fill byte
        continue;
      }
      at += 2;
      if (marker == 0x01 || (marker >= 0xd0 && marker <= 0xd8)) continue;
      if (marker == 0xd9 || marker == 0xda) break;
      final length = view.getUint16(at);
      final end = at + length;
      if (length < 2 || end > bytes.length) break;
      final segment = Uint8List.sublistView(bytes, at + 2, end);
      if (_isStartOfFrame(marker)) {
        if (segment.length < 6) break;
        final height = view.getUint16(at + 3);
        if (height == 0) {
          throw const ImageFormatException(
            'JPEG images whose height is set by a DNL marker are not '
            'supported',
          );
        }
        return JpegImage._(
          bytes,
          width: view.getUint16(at + 5),
          height: height,
          components: segment[5],
          bitsPerComponent: segment[0],
          progressive: marker & 0x03 == 0x02,
          adobe: adobe,
          orientation: orientation,
        );
      }
      if (marker == 0xee && _startsWith(segment, _adobe)) adobe = true;
      if (marker == 0xe1 && _startsWith(segment, _exif)) {
        orientation = exifOrientation(Uint8List.sublistView(segment, 6));
      }
      at = end;
    }
    throw const ImageFormatException('JPEG image has no frame header');
  }

  /// The file.
  final Uint8List bytes;

  @override
  final int width;

  @override
  final int height;

  /// The color components: 1 (gray), 3 (RGB) or 4 (CMYK).
  final int components;

  /// The bits per component (8, or 12 in extended JPEG).
  final int bitsPerComponent;

  /// Whether the image is progressive.
  final bool progressive;

  /// Whether the file has an Adobe (APP14) segment, whose CMYK data is
  /// stored inverted.
  final bool adobe;

  @override
  final int orientation;

  @override
  void writeTo(PdfWriter writer) {
    writer.write(
      PdfStream(
        bytes,
        dict: PdfDict({
          'Type': const PdfName('XObject'),
          'Subtype': const PdfName('Image'),
          'Width': PdfInt(width),
          'Height': PdfInt(height),
          'ColorSpace': switch (components) {
            1 => const PdfName('DeviceGray'),
            3 => const PdfName('DeviceRGB'),
            4 => const PdfName('DeviceCMYK'),
            _ => throw ImageFormatException(
              'JPEG images with $components components are not supported',
            ),
          },
          'BitsPerComponent': PdfInt(bitsPerComponent),
          'Filter': const PdfName('DCTDecode'),
          if (components == 4 && adobe)
            'Decode': PdfArray([
              for (var i = 0; i < 4; i++) ...[const PdfInt(1), const PdfInt(0)],
            ]),
        }),
        compress: false,
      ),
      reference(writer),
    );
  }

  static bool _isStartOfFrame(int marker) =>
      marker >= 0xc0 &&
      marker <= 0xcf &&
      marker != 0xc4 &&
      marker != 0xc8 &&
      marker != 0xcc;

  static final List<int> _adobe = 'Adobe'.codeUnits;
  static final List<int> _exif = [0x45, 0x78, 0x69, 0x66, 0, 0];
}

/// The color type of a PNG image (ISO/IEC 15948, 11.2.2).
enum PngColorType {
  /// Gray samples.
  gray(0, 1),

  /// Red, green and blue samples.
  rgb(2, 3),

  /// Palette indices.
  palette(3, 1),

  /// Gray and alpha samples.
  grayAlpha(4, 2),

  /// Red, green, blue and alpha samples.
  rgba(6, 4);

  new(this.code, this.channels);

  /// The color type's code in the file.
  final int code;

  /// The samples per pixel.
  final int channels;

  /// Whether pixels carry an alpha sample.
  bool get hasAlpha => this == grayAlpha || this == rgba;

  /// The bit depths the color type allows.
  List<int> get bitDepths => switch (this) {
    gray => const [1, 2, 4, 8, 16],
    palette => const [1, 2, 4, 8],
    rgb || grayAlpha || rgba => const [8, 16],
  };
}

/// A PNG image.
final class PngImage extends PdfImage {
  new _({
    required this.width,
    required this.height,
    required this.bitDepth,
    required this.colorType,
    required this.interlaced,
    required this.data,
    required this.palette,
    required this.transparency,
    required this.iccProfile,
    required this.orientation,
  }) : super._();

  /// The PNG image in [bytes].
  factory parse(Uint8List bytes) {
    if (!_startsWith(bytes, _pngSignature)) {
      throw const ImageFormatException('not a PNG image');
    }
    final view = ByteData.sublistView(bytes);
    ByteData? header;
    Uint8List? palette;
    Uint8List? transparency;
    Uint8List? iccProfile;
    var orientation = 1;
    final data = BytesBuilder(copy: false);
    var at = 8;
    while (at + 12 <= bytes.length) {
      final length = view.getUint32(at);
      final type = String.fromCharCodes(bytes, at + 4, at + 8);
      final start = at + 8;
      final end = start + length;
      if (end + 4 > bytes.length) {
        throw ImageFormatException('PNG chunk $type is truncated');
      }
      final chunk = Uint8List.sublistView(bytes, start, end);
      // A critical chunk must be intact; ancillary ones are only hints.
      if (_critical.contains(type) &&
          _crc32(bytes, at + 4, end) != view.getUint32(end)) {
        throw ImageFormatException('PNG chunk $type is damaged (CRC mismatch)');
      }
      switch (type) {
        case 'IHDR' when length >= 13:
          header = ByteData.sublistView(chunk);
        case 'PLTE':
          palette = chunk;
        case 'tRNS':
          transparency = chunk;
        case 'iCCP':
          final nameEnd = chunk.indexOf(0);
          if (nameEnd > 0 && nameEnd + 2 <= chunk.length) {
            try {
              iccProfile = zlibDecode(chunk.sublist(nameEnd + 2));
            } on FormatException {
              // A damaged profile: fall back to the device color space.
            }
          }
        case 'eXIf':
          orientation = exifOrientation(chunk);
        case 'IDAT':
          data.add(chunk);
        case 'IEND':
          at = bytes.length;
          continue;
      }
      at = end + 4;
    }
    if (header == null) {
      throw const ImageFormatException('PNG image has no IHDR chunk');
    }
    if (data.isEmpty) {
      throw const ImageFormatException('PNG image has no IDAT chunk');
    }
    final width = header.getUint32(0);
    final height = header.getUint32(4);
    final bitDepth = header.getUint8(8);
    final code = header.getUint8(9);
    final colorType = PngColorType.values
        .where((t) => t.code == code)
        .firstOrNull;
    if (colorType == null) {
      throw ImageFormatException('PNG color type $code is not defined');
    }
    if (!colorType.bitDepths.contains(bitDepth)) {
      throw ImageFormatException(
        'PNG bit depth $bitDepth is not allowed for color type $code',
      );
    }
    if (width == 0 || height == 0) {
      throw const ImageFormatException('PNG image is empty');
    }
    if (colorType == PngColorType.palette && palette == null) {
      throw const ImageFormatException('PNG palette image has no palette');
    }
    final interlace = header.getUint8(12);
    if (interlace > 1) {
      throw ImageFormatException(
        'PNG interlace method $interlace is not '
        'defined',
      );
    }
    return PngImage._(
      width: width,
      height: height,
      bitDepth: bitDepth,
      colorType: colorType,
      interlaced: interlace == 1,
      data: data.takeBytes(),
      palette: colorType == PngColorType.palette ? palette : null,
      transparency: colorType.hasAlpha ? null : transparency,
      iccProfile: iccProfile,
      orientation: orientation,
    );
  }

  @override
  final int width;

  @override
  final int height;

  /// The bits per sample.
  final int bitDepth;

  /// The color type.
  final PngColorType colorType;

  /// Whether the image is interlaced (Adam7).
  final bool interlaced;

  /// The image data (the IDAT chunks, a zlib stream).
  final Uint8List data;

  /// The palette (`PLTE`) of a palette image: RGB triples.
  final Uint8List? palette;

  /// The `tRNS` chunk: palette alpha, or the transparent color.
  final Uint8List? transparency;

  /// The embedded ICC profile (`iCCP`), decompressed.
  final Uint8List? iccProfile;

  @override
  final int orientation;

  /// Whether PDF can show the image data as it is: not interlaced, and no
  /// alpha to split out.
  bool get _passThrough =>
      !interlaced &&
      !colorType.hasAlpha &&
      !(colorType == PngColorType.palette && transparency != null);

  @override
  void writeTo(PdfWriter writer) {
    final colorChannels = colorType.hasAlpha
        ? colorType.channels - 1
        : colorType.channels;
    final colorSpace = _colorSpace(writer, colorChannels);
    final mask = _colorKey;
    if (_passThrough) {
      writer.write(
        _image(
          data,
          colorSpace,
          bitDepth,
          predictor: (colorChannels, bitDepth),
          mask: mask,
        ),
        reference(writer),
      );
      return;
    }
    final layout = PngLayout(width, height, colorType.channels, bitDepth);
    final pixels = unfilterImage(
      zlibDecode(data),
      layout,
      interlaced: interlaced,
    );
    final Uint8List color;
    final Uint8List? alpha;
    final int alphaDepth;
    if (colorType.hasAlpha) {
      (color, alpha) = _splitAlpha(pixels, colorChannels);
      alphaDepth = bitDepth;
    } else if (colorType == PngColorType.palette && transparency != null) {
      color = pixels;
      alpha = _paletteAlpha(pixels, layout.rowBytes(width));
      alphaDepth = 8;
    } else {
      color = pixels;
      alpha = null;
      alphaDepth = 8;
    }
    final softMask = alpha == null || alpha.every((b) => b == 0xff)
        ? null
        : writer.write(
            _encoded(
              writer,
              alpha,
              const PdfName('DeviceGray'),
              alphaDepth,
              channels: 1,
            ),
          );
    writer.write(
      _encoded(
        writer,
        color,
        colorSpace,
        bitDepth,
        channels: colorChannels,
        mask: mask,
        softMask: softMask,
      ),
      reference(writer),
    );
  }

  /// The image's color space: device gray or RGB (ICC-based with an
  /// embedded profile), or indexed over RGB for a palette image.
  PdfObject _colorSpace(PdfWriter writer, int channels) {
    final device = PdfName(
      colorType == PngColorType.gray || colorType == PngColorType.grayAlpha
          ? 'DeviceGray'
          : 'DeviceRGB',
    );
    final base = switch (iccProfile) {
      final profile? => PdfArray([
        const PdfName('ICCBased'),
        writer.write(
          PdfStream(
            profile,
            dict: PdfDict({
              'N': PdfInt(device.value == 'DeviceGray' ? 1 : 3),
              'Alternate': device,
            }),
          ),
        ),
      ]),
      null => device,
    };
    final palette = this.palette;
    if (palette == null) return base;
    final entries = palette.length ~/ 3;
    return PdfArray([
      const PdfName('Indexed'),
      base,
      PdfInt(entries - 1),
      PdfString(palette.sublist(0, entries * 3), hex: true),
    ]);
  }

  /// The color-key mask of a gray or RGB image with a transparent color.
  PdfArray? get _colorKey {
    final transparency = this.transparency;
    if (transparency == null || colorType == PngColorType.palette) {
      return null;
    }
    final view = ByteData.sublistView(transparency);
    final samples = colorType.channels;
    if (transparency.length < 2 * samples) return null;
    final limit = (1 << bitDepth) - 1;
    return PdfArray([
      for (var i = 0; i < samples; i++) ...[
        PdfInt(view.getUint16(2 * i) & limit),
        PdfInt(view.getUint16(2 * i) & limit),
      ],
    ]);
  }

  /// [pixels] split into color samples and alpha samples.
  (Uint8List, Uint8List) _splitAlpha(Uint8List pixels, int colorChannels) {
    final sample = bitDepth >> 3;
    final pixel = (colorChannels + 1) * sample;
    final count = width * height;
    final color = Uint8List(count * colorChannels * sample);
    final alpha = Uint8List(count * sample);
    for (var p = 0; p < count; p++) {
      final from = p * pixel;
      final colorBytes = colorChannels * sample;
      color.setRange(p * colorBytes, (p + 1) * colorBytes, pixels, from);
      alpha.setRange(p * sample, (p + 1) * sample, pixels, from + colorBytes);
    }
    return (color, alpha);
  }

  /// The alpha of each pixel of a palette image, from the palette's alpha
  /// in `tRNS` (opaque past its end).
  Uint8List _paletteAlpha(Uint8List pixels, int stride) {
    final table = transparency!;
    final alpha = Uint8List(width * height);
    final mask = (1 << bitDepth) - 1;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final bit = x * bitDepth;
        final index =
            (pixels[y * stride + (bit >> 3)] >> (8 - bitDepth - (bit & 7))) &
            mask;
        alpha[y * width + x] = index < table.length ? table[index] : 0xff;
      }
    }
    return alpha;
  }

  /// Decoded [samples] as an image stream: filtered and compressed (with
  /// a PNG predictor) when the writer compresses.
  PdfStream _encoded(
    PdfWriter writer,
    Uint8List samples,
    PdfObject colorSpace,
    int depth, {
    required int channels,
    PdfArray? mask,
    PdfRef? softMask,
  }) {
    if (!writer.options.compress) {
      return _image(
        samples,
        colorSpace,
        depth,
        mask: mask,
        softMask: softMask,
        compress: false,
      );
    }
    final layout = PngLayout(width, height, channels, depth);
    final filtered = filterImage(
      samples,
      layout.rowBytes(width),
      layout.pixelBytes,
    );
    return _image(
      zlibEncode(filtered, level: writer.options.compressionLevel),
      colorSpace,
      depth,
      predictor: (channels, depth),
      mask: mask,
      softMask: softMask,
    );
  }

  /// An image XObject of [data] (Flate-compressed with a PNG predictor
  /// for samples of [predictor]'s channels and depth, if given).
  PdfStream _image(
    Uint8List data,
    PdfObject colorSpace,
    int depth, {
    (int channels, int depth)? predictor,
    PdfArray? mask,
    PdfRef? softMask,
    bool compress = true,
  }) => PdfStream(
    data,
    dict: PdfDict({
      'Type': const PdfName('XObject'),
      'Subtype': const PdfName('Image'),
      'Width': PdfInt(width),
      'Height': PdfInt(height),
      'ColorSpace': colorSpace,
      'BitsPerComponent': PdfInt(depth),
      if (predictor case (final channels, final depth)) ...{
        'Filter': const PdfName('FlateDecode'),
        'DecodeParms': PdfDict({
          'Predictor': const PdfInt(15),
          'Colors': PdfInt(channels),
          'BitsPerComponent': PdfInt(depth),
          'Columns': PdfInt(width),
        }),
      },
      'Mask': ?mask,
      'SMask': ?softMask,
    }),
    compress: compress && predictor == null,
  );
}

final List<int> _pngSignature = [
  0x89,
  0x50,
  0x4e,
  0x47,
  0x0d,
  0x0a,
  0x1a,
  0x0a,
];

const Set<String> _critical = {'IHDR', 'PLTE', 'IDAT', 'IEND'};

/// The CRC-32 (ISO 3309) of [bytes] from [start] to [end].
int _crc32(List<int> bytes, int start, int end) {
  var crc = 0xffffffff;
  for (var i = start; i < end; i++) {
    crc = _crcTable[(crc ^ bytes[i]) & 0xff] ^ (crc >>> 8);
  }
  return crc ^ 0xffffffff;
}

final Uint32List _crcTable = Uint32List.fromList([
  for (var n = 0; n < 256; n++)
    () {
      var c = n;
      for (var k = 0; k < 8; k++) {
        c = c & 1 != 0 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
      }
      return c;
    }(),
]);

bool _startsWith(List<int> bytes, List<int> prefix) {
  if (bytes.length < prefix.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (bytes[i] != prefix[i]) return false;
  }
  return true;
}

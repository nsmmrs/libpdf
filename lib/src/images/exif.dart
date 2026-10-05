/// The orientation tag of EXIF metadata (a TIFF structure), which JPEG
/// files carry in an APP1 segment and PNG files in an `eXIf` chunk.
library;

import 'dart:typed_data';

/// The EXIF orientation (1–8) in [tiff], or 1 when it has none or is
/// malformed.
int exifOrientation(Uint8List tiff) {
  if (tiff.length < 8) return 1;
  final view = ByteData.sublistView(tiff);
  final Endian endian;
  switch ((tiff[0], tiff[1])) {
    case (0x49, 0x49):
      endian = Endian.little;
    case (0x4d, 0x4d):
      endian = Endian.big;
    case _:
      return 1;
  }
  if (view.getUint16(2, endian) != 42) return 1;
  final ifd = view.getUint32(4, endian);
  if (ifd + 2 > tiff.length) return 1;
  final count = view.getUint16(ifd, endian);
  for (var i = 0; i < count; i++) {
    final entry = ifd + 2 + 12 * i;
    if (entry + 12 > tiff.length) break;
    if (view.getUint16(entry, endian) == 0x0112) {
      final value = view.getUint16(entry + 8, endian);
      return value >= 1 && value <= 8 ? value : 1;
    }
  }
  return 1;
}

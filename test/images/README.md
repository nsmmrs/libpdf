# Test images

- `pngsuite/`: PngSuite (2017-07-19) by Willem van Schaik, the PNG
  conformance suite: every color type, bit depth, interlacing, palettes,
  transparency, ancillary chunks and damaged files (`x*.png`). Its terms
  are in `pngsuite/PngSuite.LICENSE` ("Permission to use, copy, modify and
  distribute these images for any purpose and without fee is hereby
  granted"); http://www.schaik.com/pngsuite/.
- `jpeg/`: made for these tests with ImageMagick 7 from a generated
  gradient (`magick -size 48x32 gradient:red-blue ...`): gray, baseline
  and progressive RGB, 4:2:0 chroma subsampling, CMYK (with an Adobe
  segment), and `exif-orientation-6.jpg`, the baseline file with an EXIF
  segment (orientation 6) inserted after the start-of-image marker.

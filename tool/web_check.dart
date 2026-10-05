// Compiles the library to JavaScript in CI, so nothing in it depends on
// dart:io or other VM-only libraries.
import 'package:libpdf/libpdf.dart';

void main() {
  // The program only has to compile; printing keeps the import used.
  // ignore: avoid_print
  print(libpdfVersion);
}

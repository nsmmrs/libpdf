import 'package:libpdf/libpdf.dart';
import 'package:test/test.dart';

void main() {
  test('the version is set', () {
    expect(libpdfVersion, isNotEmpty);
  });
}

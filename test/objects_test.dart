import 'package:libpdf/libpdf.dart';
import 'package:test/test.dart';

void main() {
  test('basic objects', () {
    expect('${const PdfNull()}', 'null');
    expect('${const PdfBool(true)}', 'true');
    expect('${const PdfInt(-12)}', '-12');
    expect('${const PdfReal(3.14159265)}', '3.14159');
    expect('${const PdfReal(2.5000)}', '2.5');
    expect('${const PdfReal(-0.000001)}', '0');
    expect('${const PdfReal(10)}', '10');
    expect('${const PdfRef(5)}', '5 0 R');
  });

  test('numbers have no exponent', () {
    expect(formatNumber(0.00001), '0.00001');
    expect(formatNumber(123456789.25), '123456789.25');
    expect(() => formatNumber(double.nan), throwsArgumentError);
  });

  test('names escape delimiters, # and non-ASCII', () {
    expect('${const PdfName('Type')}', '/Type');
    expect('${const PdfName('A B#(c)')}', '/A#20B#23#28c#29');
    expect(String.fromCharCodes(const PdfName('é').toBytes()), '/#C3#A9');
  });

  test('strings escape parentheses, backslashes and carriage returns', () {
    expect('${PdfString('a(b)c\\d\re'.codeUnits)}', r'(a\(b\)c\\d\re)');
    expect('${PdfString(const [0, 255], hex: true)}', '<00FF>');
  });

  test('text strings use PDFDocEncoding or UTF-16BE', () {
    expect(PdfString.text('Café — “ok”').bytes, [
      ...'Caf'.codeUnits,
      0xe9,
      0x20,
      0x84,
      0x20,
      0x8d,
      0x6f,
      0x6b,
      0x8e,
    ]);
    expect(PdfString.text('日本').bytes, [0xfe, 0xff, 0x65, 0xe5, 0x67, 0x2c]);
  });

  test('arrays and dictionaries', () {
    expect('${PdfArray.numbers([1, 2.5, 0])}', '[1 2.5 0]');
    expect(
      '${PdfDict({'Type': const PdfName('Page'), 'Count': const PdfInt(2)})}',
      '<< /Type /Page /Count 2 >>',
    );
  });
}

// The examples run and write valid PDF files.
@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

import '../example/booklet.dart' as booklet;
import '../example/libpdf_example.dart' as hello;
import '../example/report.dart' as report;
import '../example/svg_chart.dart' as chart;

void main() {
  late Directory dir;
  setUpAll(() => dir = Directory.systemTemp.createTempSync('libpdf.'));
  tearDownAll(() => dir.deleteSync(recursive: true));

  for (final (name, run) in [
    ('hello', hello.main),
    ('report', report.main),
    ('svg_chart', chart.main),
    ('booklet', booklet.main),
  ]) {
    test(name, () {
      final path = '${dir.path}/$name.pdf';
      run([path]);
      final bytes = File(path).readAsBytesSync();
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
      if (Process.runSync('which', ['qpdf']).exitCode == 0) {
        final check = Process.runSync('qpdf', ['--check', path]);
        expect(check.exitCode, 0, reason: '${check.stdout}');
      }
    });
  }
}

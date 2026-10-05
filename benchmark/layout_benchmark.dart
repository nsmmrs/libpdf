// Lays out and writes the sample document (test/sample_document.dart) at
// growing sizes and prints pages per second.
//
//   dart run benchmark/layout_benchmark.dart
import 'package:libpdf/libpdf.dart';

import '../test/sample_document.dart';

void main() {
  // Warm up.
  _run(4);
  for (final chapters in [10, 40, 160]) {
    final watch = Stopwatch()..start();
    final (pages, bytes) = _run(chapters);
    final seconds = watch.elapsedMicroseconds / 1e6;
    // The benchmark's output is the report.
    // ignore: avoid_print
    print(
      '$chapters chapters: $pages pages, ${bytes ~/ 1024} KiB in '
      '${seconds.toStringAsFixed(2)} s '
      '(${(pages / seconds).toStringAsFixed(0)} pages/s)',
    );
  }
}

(int, int) _run(int chapters) {
  final result = sampleLayout().layout(sampleContent(chapters: chapters));
  final document = PdfDocument();
  result.render(document);
  return (result.pageCount, document.save().length);
}

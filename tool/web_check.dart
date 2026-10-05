// Compiles the library to JavaScript in CI and writes a deterministic PDF
// (text, shapes, transparency, PNG images decoded and compressed again,
// a link, an outline and page labels):
// nothing in the library may depend on dart:io, and the output must be
// the same bytes on the VM and on JavaScript (the CI job compares the
// digest it prints with the VM's).
import 'dart:convert';

import 'package:libpdf/libpdf.dart';

void main() {
  final document = PdfDocument(info: const PdfInfo(title: 'web'));
  final page = document.addPage(const PdfRect(0, 0, 612, 792));
  final style = PdfTextStyle(StandardFont.helvetica, 12, wordSpacing: 1);
  page.canvas
    ..text('web ' * 40, 72, 720, style)
    ..setFillColor(const SpotColor('Spot', CmykColor(0, 1, 1, 0)))
    ..roundedRect(const PdfRect(72, 500, 100, 50), 8)
    ..fill()
    ..saved(() {
      page.canvas
        ..opacity(fill: 0.5)
        ..rotate(15)
        ..circle(300, 500, 40)
        ..fill();
    });
  for (final (i, png) in [_rgba16Interlaced, _paletteAlpha].indexed) {
    page.canvas.image(
      PdfImage.parse(base64.decode(png)),
      PdfRect(72 + 48.0 * i, 600, 32, 32),
    );
  }
  page.link(
    const PdfRect(72, 715, 100, 15),
    const LinkTarget.uri('https://example.org/'),
  );
  document
    ..addOutline('web', LinkTarget.destination(PdfDestination.fit(page)))
    ..labelPages(0, const PageLabel(style: PageNumberStyle.lowerRoman));
  final pdf = document.save(
    options: const PdfWriterOptions(deterministic: true),
  );
  final digest = [for (final b in md5(pdf)) b.toRadixString(16).padLeft(2, '0')]
      .join();
  // The digest is the program's output.
  // ignore: avoid_print
  print('${pdf.length} $digest');
}

/// PngSuite's `basi6a16.png`.
const String _rgba16Interlaced =
    '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'
    'fwAZC+9JQJpSCQAAAABJRU5ErkJggg==';

/// PngSuite's `tp1n3p08.png`.
const String _paletteAlpha =
    'iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAMAAABEpIrGAAAABGdBTUEAAYagMeiWXwAAAt9Q'
    'TFRF////gFZWtbW4qEJCn5+fsSAgixUVnZ2dGxtZm5ubAACEmZmZj6ePl5eXlZWVk5OTKSlW'
    'kZGRAACbj4+Pi5WLLi6njY2NgAAAi4uLuQAAiYmJDAzVeHV1h4eHAACyhYWFpQAA3gAAgYGB'
    'f39/AACefX19AADJe3t7eXl5NzdWd3d3dXV1c3NzSKlIjgAAAgJkAABiVolWKCh8U4tTiYmP'
    'Z2dnZWVlXW1dE+UThiYmby0tRJFEYWFhO507RIlEPZM9AACkAPMAAPEAWVlZV1dXVVVVU1NT'
    'NIU0UVFRJJckT09POjpBEBC6sg8PAMcAAMUA/Pz8AMMABASXAMEALXct+vr6AL8AAABoAL0A'
    '2tTUEBB7Ca0J+Pj4ALkAALcAnJyh9vb2DKEMALMAALEAEJEQAKsA8vLyAKkAAKcA7u7u7Ozs'
    'AJcA6urqAABrAI0AAIsAAIkAAIcAMTExGRkqBwdAEhKuCQnu09bTzMzMkwAAoyoqxsbGxMTE'
    'zAAA0woKgWtreD4+AwNtAACfCgpWRkZIQUFNc11dUQcHqKio7e3voKCgnp6enJycAAC5mpqa'
    'sgAAmJiY6wAAlpaWngAAlJSUExMckpKSkJCQjo6OAACRioqKiIiIdqJ2hYiFhoaGhISEeA8P'
    'goKCfoJ+fn5+fHx8enp6SsBKdnZ2dHR0cnJycHBwmAAAbm5uanBqemZmampqhAAARKJES5ZL'
    'YWRhYmJiAPQAOJg4XFxcWlpaAOYAAgJdQnhCVlZWAADwLpQuR2hHMTFgANgAUlJSUFBQAM4A'
    'IZghFBRtAMgATExM/f39AMYAAACdb2tr6g4OSEhIALwANGY0AgL1U1NgALAAAK4AtwAAAKQA'
    '7+/vAKIAj09PlTQ0AJgAAJYAAJIA5+fnAIwA4+PjAIAAkgYGAQFvZFZZAABkTk5rz8/P3d3g'
    'AAB7ycnJFhZBISFZV1dZRER4v7+/693dLS1UCgpgAAD/v319DyW3rQAAAAF0Uk5TAEDm2GYA'
    'AAKKSURBVDiNY2CgMnjwKg2P7D2mxWZPLJm/fMAqm/leyrStgU1vg/iG1VVfIgNQZdNq+Fae'
    'abCsnFwpvsCqvb19w6N1Xc9jYLIxr/qW67RZPpqs0F9bK6nAZrlAfLXekzU6yzlrMsEKKpSX'
    'a2vfkuy/6nvrJqui4sSJirWS4me0gWB9H1jBC/nZ89UZfVlvymhpadUz1509W1fFCGSu2n7o'
    'PVhBznyluTOklDVQwfItrodP3IO4YZHnNVsRfuH56jCwdKnGepfDJ845Q105K+mU47JpfLxT'
    'ZJdAwcrtRkFRAi0LoQqmRUdstRCcwsvNyS2hvHixqtaWSz5qM8PDBTqgCqYkJu3cOodfZKMu'
    'T3fPjMXrd7yV3tu0q8SAoxyqoONo6vGty6bpnk/fx87StXSHs+hntV3FU5s1YcHJtO/GlZ1O'
    'IhuP397W082ywvnZxb2N3udeC6yEBWW1e3LeEcdNtn637TnZu9cADXB40xrVNDMepiByd/LD'
    'WKcU21PZ9n2c7KZvy/Y2HghSefmpGqYgZ/eVwsSDGZ6Bd+wn9PXYvPvcy/H6ZW4uRwJMQcD+'
    '9Dshwf53g+9u4uXu2yF6ketjsf5joWeI2F577dr+xIP5YXmb+HgnuZTuDW8tOiaXa4JQIHbj'
    '8gW749nn71vz8wnv8enVbzngcLq5GqEglMd9s1n0ldh8Y0F+KdfS058OBMlxMKEkqedrzPYl'
    'xRUYCgsquUZx6XPNPPYcLUlmzTO/nFRgLCa81PVj41MDoxcM6CCg4+jlQkMJsRVu3sUl7zox'
    '5IGgfFvIotkSaw55FWmFYpNnYLjeNX/ebFOPw10nscsDwXv5eTaHmHBKA8GL6WYV+OQZGBIe'
    '4JfHBAANrv+RnZXbwAAAAABJRU5ErkJggg==';

import 'dart:io';
import 'dart:typed_data';

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

class CaptchaService {
  /// Tries multiple preprocessing variants in order; returns the first result
  /// whose length is in the valid captcha range (4–9 chars).
  static Future<String> solve(Uint8List imageBytes) async {
    // Each tuple: (darkThreshold, dilate, scale, minConfidence)
    const configs = [
      (80, true,  4, 0.4),  // original
      (80, false, 4, 0.4),  // no dilation (cleaner thin fonts)
      (60, true,  4, 0.4),  // stricter colour filter
      (100, true, 4, 0.4),  // looser colour filter
      (80, true,  6, 0.4),  // larger scale
      (80, true,  4, 0.0),  // no confidence gate (last resort)
      (80, false, 4, 0.0),  // no dilation + no confidence gate
    ];

    String fallback = '';
    for (final (thresh, dilate, scale, minConf) in configs) {
      final processed = _preprocess(imageBytes,
          threshold: thresh, dilate: dilate, scale: scale);
      final text = await _ocr(processed, minConf: minConf);
      final clean = text.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').trim();
      if (clean.length == 6) return clean;
      if (fallback.isEmpty && clean.isNotEmpty) fallback = clean;
    }
    return fallback;
  }

  static Uint8List _preprocess(
    Uint8List bytes, {
    required int threshold,
    required bool dilate,
    required int scale,
  }) {
    var src = img.decodeImage(bytes);
    if (src == null) return bytes;

    // Step 1: flatten alpha onto white background
    if (src.numChannels == 4) {
      final white = img.Image(width: src.width, height: src.height);
      img.fill(white, color: img.ColorRgb8(255, 255, 255));
      img.compositeImage(white, src);
      src = white;
    }

    // Step 2: colour filter — characters are black, noise is coloured
    final filtered = img.Image(width: src.width, height: src.height);
    for (int y = 0; y < src.height; y++) {
      for (int x = 0; x < src.width; x++) {
        final p = src.getPixel(x, y);
        if (p.r.toInt() < threshold &&
            p.g.toInt() < threshold &&
            p.b.toInt() < threshold) {
          filtered.setPixel(x, y, img.ColorRgb8(0, 0, 0));
        } else {
          filtered.setPixel(x, y, img.ColorRgb8(255, 255, 255));
        }
      }
    }

    // Step 3: optional dilation — thickens thin/broken strokes
    final base = dilate ? _dilate(filtered) : filtered;

    // Step 4: 10 px white padding — avoids edge-clipping by OCR
    const pad = 10;
    final padded = img.Image(
      width: base.width + pad * 2,
      height: base.height + pad * 2,
    );
    img.fill(padded, color: img.ColorRgb8(255, 255, 255));
    img.compositeImage(padded, base, dstX: pad, dstY: pad);

    // Step 5: scale up so ML Kit has more pixels per character
    final scaled = img.copyResize(
      padded,
      width: padded.width * scale,
      height: padded.height * scale,
      interpolation: img.Interpolation.cubic,
    );

    return Uint8List.fromList(img.encodePng(scaled));
  }

  static img.Image _dilate(img.Image src) {
    final dst = img.Image(width: src.width, height: src.height);
    img.fill(dst, color: img.ColorRgb8(255, 255, 255));
    for (int y = 0; y < src.height; y++) {
      for (int x = 0; x < src.width; x++) {
        if (src.getPixel(x, y).r.toInt() < 128) {
          for (int dy = -1; dy <= 1; dy++) {
            for (int dx = -1; dx <= 1; dx++) {
              final nx = x + dx, ny = y + dy;
              if (nx >= 0 && nx < src.width && ny >= 0 && ny < src.height) {
                dst.setPixel(nx, ny, img.ColorRgb8(0, 0, 0));
              }
            }
          }
        }
      }
    }
    return dst;
  }

  static Future<String> _ocr(Uint8List pngBytes,
      {required double minConf}) async {
    final dir = await getTemporaryDirectory();
    final file = File(
        '${dir.path}/captcha_${DateTime.now().millisecondsSinceEpoch}.png');
    await file.writeAsBytes(pngBytes);

    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    try {
      final result = await recognizer.processImage(InputImage.fromFile(file));

      final elements = [
        for (final block in result.blocks)
          for (final line in block.lines)
            for (final el in line.elements) el,
      ];
      elements.sort(
          (a, b) => (a.boundingBox.left).compareTo(b.boundingBox.left));

      final confident = elements
          .where((e) => (e.confidence ?? 1.0) >= minConf)
          .map((e) => e.text)
          .join('');

      return confident.isNotEmpty ? confident : result.text;
    } finally {
      recognizer.close();
      await file.delete();
    }
  }
}

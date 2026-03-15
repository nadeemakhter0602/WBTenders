import 'dart:io';
import 'dart:typed_data';

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

class CaptchaService {
  static Future<String> solve(Uint8List imageBytes) async {
    final processed = _preprocess(imageBytes);
    final text = await _ocr(processed);
    return text.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').trim();
  }

  /// Matches the Python script pipeline:
  ///   1. Flatten RGBA onto white background
  ///   2. Color-filter: keep only near-black pixels (chars are black, noise is coloured)
  ///   3. Convert to grayscale
  ///   4. Scale up 4× (cubic ≈ Lanczos4 used in Python)
  static Uint8List _preprocess(Uint8List bytes) {
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
        if (p.r.toInt() < 80 && p.g.toInt() < 80 && p.b.toInt() < 80) {
          filtered.setPixel(x, y, img.ColorRgb8(0, 0, 0));
        } else {
          filtered.setPixel(x, y, img.ColorRgb8(255, 255, 255));
        }
      }
    }

    // Step 3: convert to grayscale
    final gray = img.grayscale(filtered);

    // Step 4: scale up 4×
    final scaled = img.copyResize(
      gray,
      width: gray.width * 4,
      height: gray.height * 4,
      interpolation: img.Interpolation.cubic,
    );

    return Uint8List.fromList(img.encodePng(scaled));
  }

  static Future<String> _ocr(Uint8List pngBytes) async {
    final dir = await getTemporaryDirectory();
    final file = File(
        '${dir.path}/captcha_${DateTime.now().millisecondsSinceEpoch}.png');
    await file.writeAsBytes(pngBytes);

    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    try {
      final result = await recognizer.processImage(InputImage.fromFile(file));

      // Flatten all elements, sort by horizontal position (ML Kit may split
      // a single captcha word across multiple blocks).
      final elements = [
        for (final block in result.blocks)
          for (final line in block.lines)
            for (final el in line.elements) el,
      ];
      elements.sort(
          (a, b) => a.boundingBox.left.compareTo(b.boundingBox.left));

      final confident = elements
          .where((e) => (e.confidence ?? 1.0) >= 0.4)
          .map((e) => e.text)
          .join('');

      return confident.isNotEmpty ? confident : result.text;
    } finally {
      recognizer.close();
      await file.delete();
    }
  }
}

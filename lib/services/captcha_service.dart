import 'dart:io';
import 'dart:typed_data';

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

class CaptchaService {
  static Future<String> solve(Uint8List imageBytes) async {
    final cleaned = _preprocess(imageBytes);
    final text = await _ocr(cleaned);
    return text.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').trim();
  }

  /// Preprocessing pipeline:
  ///   1. Composite RGBA onto white background
  ///   2. Color-filter: keep only near-black pixels (chars are black, noise is coloured)
  ///   3. Morphological dilation (1 px) to fill thin/broken strokes
  ///   4. Add 10 px white padding on all sides (prevents OCR edge-clipping)
  ///   5. Scale up 4× with cubic interpolation so ML Kit has more pixels to work with
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

    // Step 2: color filter — characters are black, noise is coloured
    final filtered = img.Image(width: src.width, height: src.height);
    for (int y = 0; y < src.height; y++) {
      for (int x = 0; x < src.width; x++) {
        final p = src.getPixel(x, y);
        final r = p.r.toInt();
        final g = p.g.toInt();
        final b = p.b.toInt();
        if (r < 80 && g < 80 && b < 80) {
          filtered.setPixel(x, y, img.ColorRgb8(0, 0, 0));
        } else {
          filtered.setPixel(x, y, img.ColorRgb8(255, 255, 255));
        }
      }
    }

    // Step 3: dilation (3×3 kernel) — thickens thin/broken character strokes
    final dilated = _dilate(filtered);

    // Step 4: add 10 px white padding on all sides — avoids edge-clipping by OCR
    const pad = 10;
    final padded = img.Image(
      width: dilated.width + pad * 2,
      height: dilated.height + pad * 2,
    );
    img.fill(padded, color: img.ColorRgb8(255, 255, 255));
    img.compositeImage(padded, dilated, dstX: pad, dstY: pad);

    // Step 5: scale up 4× so ML Kit has more pixels per character
    final scaled = img.copyResize(
      padded,
      width: padded.width * 4,
      height: padded.height * 4,
      interpolation: img.Interpolation.cubic,
    );

    return Uint8List.fromList(img.encodePng(scaled));
  }

  /// Binary morphological dilation with a 3×3 structuring element.
  /// Each black pixel spreads to its 8 neighbours, thickening strokes by 1 px.
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

  static Future<String> _ocr(Uint8List pngBytes) async {
    final dir = await getTemporaryDirectory();
    final file = File(
        '${dir.path}/captcha_clean_${DateTime.now().millisecondsSinceEpoch}.png');
    await file.writeAsBytes(pngBytes);

    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    try {
      final result = await recognizer.processImage(InputImage.fromFile(file));

      // Flatten all elements across blocks/lines, then sort by horizontal position.
      // ML Kit may split a single captcha word into multiple blocks; sorting by
      // bounding-box left edge restores the correct left-to-right reading order.
      final elements = [
        for (final block in result.blocks)
          for (final line in block.lines)
            for (final el in line.elements) el,
      ];
      elements.sort((a, b) =>
          (a.boundingBox.left).compareTo(b.boundingBox.left));

      // Keep only elements with sufficient confidence, then join into one string.
      final confident = elements
          .where((e) => (e.confidence ?? 1.0) >= 0.4)
          .map((e) => e.text)
          .join('');

      // Fall back to raw result.text if element-level extraction yields nothing
      return confident.isNotEmpty ? confident : result.text;
    } finally {
      recognizer.close();
      await file.delete();
    }
  }
}

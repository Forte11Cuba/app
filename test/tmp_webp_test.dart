import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _assets = [
  'assets/images/wt-1.webp',
  'assets/images/wt-2.webp',
  'assets/images/wt-3.webp',
  'assets/images/wt-4.webp',
  'assets/images/wt-5.webp',
  'assets/images/wt-6.webp',
  'assets/images/mostro_logo.webp',
  'assets/images/mostro_logo_beta.webp',
];

/// Feeds every bundled asset through the platform image codec and reports the
/// decoded pixel size, failing if any of them cannot be decoded.
void main() {
  testWidgets('every webp asset decodes', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));

    for (final path in _assets) {
      await tester.runAsync(() async {
        final data = await rootBundle.load(path);
        final codec = await ui.instantiateImageCodec(
          data.buffer.asUint8List(),
        );
        final frame = await codec.getNextFrame();
        debugPrint(
          'OK $path -> ${frame.image.width}x${frame.image.height} '
          '(${data.lengthInBytes} B)',
        );
        expect(frame.image.width, greaterThan(0), reason: path);
        expect(frame.image.height, greaterThan(0), reason: path);
      });
    }
  });
}

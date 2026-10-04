import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mostro/core/app_theme.dart';
import 'package:mostro/shared/widgets/input_source_action.dart';

Future<void> _pump(WidgetTester tester, {required VoidCallback? onTap}) {
  return tester.pumpWidget(
    MaterialApp(
      theme: buildDarkTheme(),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 160,
            child: InputSourceAction(
              icon: Icons.content_paste_outlined,
              label: 'Paste',
              onTap: onTap,
              accent: true,
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('InputSourceAction', () {
    // DS-CMP-6: a 13 sp label and its padding came to 46 dp on their own.
    testWidgets('an enabled action is a 48 dp tap target', (tester) async {
      await _pump(tester, onTap: () {});

      expect(
        tester.getSize(find.byType(InkWell)).height,
        greaterThanOrEqualTo(48),
      );
    });

    testWidgets('a disabled action keeps the same height', (tester) async {
      await _pump(tester, onTap: null);

      expect(
        tester.getSize(find.byType(InkWell)).height,
        greaterThanOrEqualTo(48),
      );
    });
  });
}

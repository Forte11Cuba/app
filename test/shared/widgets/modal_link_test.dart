import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mostro/core/app_theme.dart';
import 'package:mostro/shared/widgets/mostro_modal.dart';

Widget _footer(List<ModalLink> links) => MaterialApp(
  theme: buildDarkTheme(),
  home: Scaffold(body: ModalFooter(links: links)),
);

void main() {
  testWidgets('a disabled link says why in its tooltip', (tester) async {
    // Arrange
    await tester.pumpWidget(
      _footer(const [
        ModalLink(
          label: 'Scan QR',
          onPressed: null,
          tooltip: 'Not available on this device',
        ),
      ]),
    );

    // Act
    await tester.longPress(find.text('Scan QR'));
    await tester.pumpAndSettle();

    // Assert
    expect(find.text('Not available on this device'), findsOneWidget);
  });

  testWidgets('a link without a tooltip gets none', (tester) async {
    // Arrange / Act
    await tester.pumpWidget(
      _footer([ModalLink(label: 'Paste', onPressed: () {})]),
    );

    // Assert
    expect(find.byType(Tooltip), findsNothing);
  });
}

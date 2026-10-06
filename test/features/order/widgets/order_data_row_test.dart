import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mostro/core/app_theme.dart';
import 'package:mostro/features/order/widgets/order_detail_cards.dart';

/// DS-CMP-24: a data row's icon and padding are on their scales — a 16-dp
/// icon (DS-ICO-3) and 14 above and below (DS-SPC-2).
void main() {
  testWidgets('a data row sits on the icon and spacing scales', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme(),
        home: const Scaffold(
          body: OrderDataRow(
            icon: Icons.payments_outlined,
            label: 'Recibes',
            value: OrderDataValue('312 ARS', figures: true),
          ),
        ),
      ),
    );

    final icon = tester.widget<Icon>(find.byIcon(Icons.payments_outlined));
    expect(icon.size, 16);

    final padding = tester.widget<Padding>(
      find
          .descendant(
            of: find.byType(OrderDataRow),
            matching: find.byType(Padding),
          )
          .first,
    );
    expect(padding.padding, const EdgeInsets.symmetric(vertical: 14));
  });
}

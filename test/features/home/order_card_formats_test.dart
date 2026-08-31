import 'package:flutter_test/flutter_test.dart';
import 'package:mostro/features/home/widgets/order_list_item.dart';

void main() {
  group('OrderCardFormats', () {
    test('reuses one set of formatters per locale', () {
      // Constructing a NumberFormat parses its pattern and loads locale data.
      // The card needs four of them, so building them per row per rebuild is
      // the single most repeated allocation in a list of thousands of orders.
      expect(
        identical(OrderCardFormats.of('es'), OrderCardFormats.of('es')),
        isTrue,
      );
    });

    test('keeps locales apart', () {
      final es = OrderCardFormats.of('es');
      final en = OrderCardFormats.of('en');

      expect(identical(es, en), isFalse);
      expect(es.decimal.format(1234), isNot(en.decimal.format(1234)));
    });

    test('formats the premium with an explicit sign', () {
      final formats = OrderCardFormats.of('en');

      expect(formats.premium.format(2.5), '+2.5');
      expect(formats.premium.format(-2.5), '-2.5');
    });
  });
}

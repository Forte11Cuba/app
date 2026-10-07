import 'package:flutter_test/flutter_test.dart';
import 'package:mostro/features/home/providers/home_order_providers.dart';

import '../../support/fake_orders.dart';
import '../../support/order_book_harness.dart';

void main() {
  group('filteredOrdersProvider', () {
    test('BUY tab shows only pending sell orders', () async {
      final helper = await bookWith([
        fakeOrder(id: 'sell', kind: 'sell'),
        fakeOrder(id: 'buy', kind: 'buy'),
      ]);
      helper.setTab(OrderType.buy);

      expect(helper.ids(), ['sell']);
    });

    test('SELL tab shows only pending buy orders', () async {
      final helper = await bookWith([
        fakeOrder(id: 'sell', kind: 'sell'),
        fakeOrder(id: 'buy', kind: 'buy'),
      ]);
      helper.setTab(OrderType.sell);

      expect(helper.ids(), ['buy']);
    });

    test('own orders follow the same tab split as everyone else', () async {
      // Issue #290: own orders used to show in both tabs, which read as
      // duplication. A sell order lives in BUY BTC, a buy order in SELL
      // BTC — same as third-party orders.
      final helper = await bookWith([
        fakeOrder(id: 'mine-buy', kind: 'buy', isMine: true),
        fakeOrder(id: 'mine-sell', kind: 'sell', isMine: true),
        fakeOrder(id: 'other-sell', kind: 'sell'),
      ]);

      helper.setTab(OrderType.buy); // targets sell orders
      expect(helper.ids(), ['mine-sell', 'other-sell']);

      helper.setTab(OrderType.sell); // targets buy orders
      expect(helper.ids(), ['mine-buy']);
    });

    test('non-pending orders are excluded', () async {
      final helper = await bookWith([
        fakeOrder(id: 'pending', kind: 'sell'),
        fakeOrder(id: 'active', kind: 'sell', status: OrderStatus.active),
      ]);
      helper.setTab(OrderType.buy);

      expect(helper.ids(), ['pending']);
    });

    test('currency filter keeps only selected fiat codes', () async {
      final helper = await bookWith([
        fakeOrder(id: 'usd', kind: 'sell', fiatCode: 'USD'),
        fakeOrder(id: 'eur', kind: 'sell', fiatCode: 'EUR'),
      ]);
      helper.setTab(OrderType.buy);
      await helper.filter(const OrderFilters(currencies: ['EUR']));

      expect(helper.ids(), ['eur']);
    });

    test('payment method filter matches any comma-separated token', () async {
      final helper = await bookWith([
        fakeOrder(id: 'multi', kind: 'sell', paymentMethod: 'Wire, Revolut'),
        fakeOrder(id: 'cash', kind: 'sell', paymentMethod: 'Cash'),
      ]);
      helper.setTab(OrderType.buy);
      await helper.filter(const OrderFilters(paymentMethods: ['revolut']));

      expect(helper.ids(), ['multi']);
    });

    test('payment method filter ignores case and padding', () async {
      // Arrange
      final helper = await bookWith([
        fakeOrder(id: 'padded', kind: 'sell', paymentMethod: ' wire ,Revolut'),
        fakeOrder(id: 'cash', kind: 'sell', paymentMethod: 'Cash'),
      ]);

      // Act
      await helper.filter(const OrderFilters(paymentMethods: ['WIRE']));

      // Assert
      expect(helper.ids(), ['padded']);
    });

    test('a method the book offers finds its orders', () async {
      // The EUR order form offers "SEPA instant"; the old fixed chip "SEPA"
      // matched none of those orders.
      final helper = await bookWith([
        fakeOrder(id: 'sepa', kind: 'sell', paymentMethod: 'SEPA instant'),
        fakeOrder(id: 'wise', kind: 'sell', paymentMethod: 'Wise'),
      ]);
      helper.setTab(OrderType.buy);
      final offered = helper.container.read(bookPaymentMethodsProvider);
      await helper.filter(OrderFilters(paymentMethods: [offered.first]));

      expect(offered, ['SEPA instant', 'Wise']);
      expect(helper.ids(), ['sepa']);
    });

    test('an order splits its payment methods once, not per filter pass', () {
      // Arrange
      final order = fakeOrder(
        id: 'multi',
        kind: 'sell',
        paymentMethod: 'Wire, Revolut',
      );

      // Act / Assert: the filter runs over the whole book on every emission
      // and every filter change; the tokens of an order never change.
      expect(order.paymentTokens, {'wire', 'revolut'});
      expect(identical(order.paymentTokens, order.paymentTokens), isTrue);
    });

    test('rating range excludes orders outside the bounds', () async {
      final helper = await bookWith([
        fakeOrder(id: 'low', kind: 'sell', rating: 2.0),
        fakeOrder(id: 'high', kind: 'sell', rating: 4.5),
      ]);
      helper.setTab(OrderType.buy);
      await helper.filter(const OrderFilters(rating: (min: 4.0, max: 5.0)));

      expect(helper.ids(), ['high']);
    });

    test('premium range excludes orders outside the bounds', () async {
      final helper = await bookWith([
        fakeOrder(id: 'cheap', kind: 'sell', premium: -5.0),
        fakeOrder(id: 'pricey', kind: 'sell', premium: 8.0),
      ]);
      helper.setTab(OrderType.buy);
      await helper.filter(const OrderFilters(premium: (min: 5.0, max: 10.0)));

      expect(helper.ids(), ['pricey']);
    });

    test('results are sorted newest-first by createdAt', () async {
      final helper = await bookWith([
        fakeOrder(id: 'older', kind: 'sell', minutesAgo: 30),
        fakeOrder(id: 'newer', kind: 'sell', minutesAgo: 5),
      ]);
      helper.setTab(OrderType.buy);

      expect(helper.ids(), ['newer', 'older']);
    });

    test('default rating range does not filter out unrated orders', () async {
      final helper = await bookWith([
        fakeOrder(id: 'unrated', kind: 'sell', rating: 0.0),
      ]);
      helper.setTab(OrderType.buy);

      expect(helper.ids(), ['unrated']);
    });

    test('range orders pass through the filters', () async {
      final helper = await bookWith([
        fakeOrder(
          id: 'range',
          kind: 'sell',
          fiatAmount: null,
          fiatAmountMin: 50,
          fiatAmountMax: 150,
        ),
      ]);
      helper.setTab(OrderType.buy);

      expect(helper.ids(), ['range']);
    });
  });

  group('bookPaymentMethodsProvider', () {
    test('offers each method once, as first spelled, sorted', () async {
      final helper = await bookWith([
        fakeOrder(id: 'a', kind: 'sell', paymentMethod: 'Wire, Revolut'),
        fakeOrder(id: 'b', kind: 'sell', paymentMethod: ' revolut ,bizum'),
      ]);
      helper.setTab(OrderType.buy);

      expect(helper.container.read(bookPaymentMethodsProvider), [
        'bizum',
        'Revolut',
        'Wire',
      ]);
    });

    test('only the active tab\'s pending orders count', () async {
      final helper = await bookWith([
        fakeOrder(id: 'listed', kind: 'sell', paymentMethod: 'Wise'),
        fakeOrder(id: 'other-tab', kind: 'buy', paymentMethod: 'Zelle'),
        fakeOrder(
          id: 'taken',
          kind: 'sell',
          paymentMethod: 'Cash',
          status: OrderStatus.active,
        ),
      ]);
      helper.setTab(OrderType.buy);

      expect(helper.container.read(bookPaymentMethodsProvider), ['Wise']);
    });

    test('skips empty entries of a sloppy tag', () async {
      final helper = await bookWith([
        fakeOrder(id: 'a', kind: 'sell', paymentMethod: 'Wise,, '),
      ]);
      helper.setTab(OrderType.buy);

      expect(helper.container.read(bookPaymentMethodsProvider), ['Wise']);
    });

    test('only the picked currencies\' orders offer their methods', () async {
      final helper = await bookWith([
        fakeOrder(
          id: 'eur',
          kind: 'sell',
          fiatCode: 'EUR',
          paymentMethod: 'SEPA instant',
        ),
        fakeOrder(
          id: 'ars',
          kind: 'sell',
          fiatCode: 'ARS',
          paymentMethod: 'Efectivo',
        ),
      ]);
      helper.setTab(OrderType.buy);
      expect(helper.container.read(bookPaymentMethodsProvider), [
        'Efectivo',
        'SEPA instant',
      ]);

      await helper.filter(const OrderFilters(currencies: ['EUR']));

      expect(helper.container.read(bookPaymentMethodsProvider), [
        'SEPA instant',
      ]);
    });

    test(
      'every method the book offers finds the orders that carry it',
      () async {
        final helper = await bookWith([
          fakeOrder(
            id: 'a',
            kind: 'sell',
            paymentMethod: ' Wise , sepa instant',
          ),
          fakeOrder(
            id: 'b',
            kind: 'sell',
            paymentMethod: 'SEPA Instant,,Bizum',
          ),
          fakeOrder(id: 'c', kind: 'sell', paymentMethod: 'Pix;Zelle'),
        ]);
        helper.setTab(OrderType.buy);

        for (final method in helper.container.read(
          bookPaymentMethodsProvider,
        )) {
          await helper.filter(OrderFilters(paymentMethods: [method]));

          expect(
            helper.ids(),
            isNotEmpty,
            reason: '"$method" is offered but finds no order',
          );
        }
      },
    );
  });
}

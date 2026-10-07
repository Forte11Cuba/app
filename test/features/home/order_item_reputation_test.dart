import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mostro/features/home/providers/home_order_providers.dart';
import 'package:mostro/src/rust/api/types.dart';

OrderInfo _info({
  double rating = 0,
  int totalReviews = 0,
  int daysActive = 0,
  int? makerSince,
}) {
  return OrderInfo(
    id: 'order-1',
    kind: OrderKind.sell,
    status: OrderStatus.pending,
    fiatAmount: 100,
    fiatCode: 'USD',
    paymentMethod: 'Wire',
    premium: 1.5,
    creatorPubkey: 'node-pubkey',
    createdAt: 1000,
    isMine: false,
    rating: rating,
    totalReviews: totalReviews,
    daysActive: daysActive,
    makerSince: makerSince,
  );
}

void main() {
  group('OrderItem.fromInfo reputation mapping', () {
    test('maps rating, totalReviews, and daysActive from the bridge', () {
      // Arrange
      final info = _info(rating: 4.9, totalReviews: 47, daysActive: 312);

      // Act
      final item = OrderItem.fromInfo(info);

      // Assert
      expect(item.rating, 4.9);
      expect(item.tradeCount, 47);
      expect(item.daysActive, 312);
    });

    test('keeps zeros for makers with no reputation (full privacy)', () {
      // Arrange
      final info = _info();

      // Act
      final item = OrderItem.fromInfo(info);

      // Assert
      expect(item.rating, 0.0);
      expect(item.tradeCount, 0);
      expect(item.daysActive, 0);
      expect(item.makerSince, isNull);
    });

    test('maps makerSince from Unix seconds to a UTC date', () {
      // Arrange — 2023-11-14 00:00:00 UTC.
      final info = _info(daysActive: 10, makerSince: 1699920000);

      // Act
      final item = OrderItem.fromInfo(info);

      // Assert
      expect(item.makerSince, DateTime.utc(2023, 11, 14));
      expect(item.daysActive, 10);
    });
  });

  group('OrderItem.makerDaysOnMostro', () {
    test('computes the age from makerSince instead of the stale count', () {
      // Arrange
      final item = OrderItem.fromInfo(
        _info(daysActive: 10, makerSince: 1699920000),
      );

      // Act
      final days = withClock(
        Clock.fixed(DateTime.utc(2024, 11, 13, 18)),
        () => item.makerDaysOnMostro,
      );

      // Assert — 2024 is a leap year: 365 whole days since 2023-11-14.
      expect(days, 365);
    });

    test('falls back to daysActive from a daemon without since', () {
      // Arrange
      final item = OrderItem.fromInfo(_info(daysActive: 10));

      // Act
      final days = item.makerDaysOnMostro;

      // Assert
      expect(days, 10);
    });

    test('an order with since differs from one without it', () {
      // Arrange
      final withSince = OrderItem.fromInfo(_info(makerSince: 1699920000));
      final without = OrderItem.fromInfo(_info());

      // Assert — makerSince is part of value equality.
      expect(withSince == without, isFalse);
      expect(withSince, OrderItem.fromInfo(_info(makerSince: 1699920000)));
    });
  });
}

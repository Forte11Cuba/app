import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mostro/shared/utils/reputation_age.dart';

import '../../support/fake_trades.dart';

/// 2023-11-14 00:00:00 UTC, a day start as the daemon publishes `since`.
const _since = 1699920000;
final _sinceDate = DateTime.utc(2023, 11, 14);

/// 64 whole days and a half after [_sinceDate].
final _now = DateTime.utc(2024, 1, 17, 12);

void main() {
  group('reputationSince', () {
    test('converts Unix seconds to a UTC date', () {
      // Act
      final since = reputationSince(_since);

      // Assert
      expect(since, _sinceDate);
      expect(since!.isUtc, isTrue);
    });

    test('accepts the BigInt the bridge hands over on web', () {
      expect(reputationSince(BigInt.from(_since)), _sinceDate);
    });

    test('returns null when the daemon sent no since', () {
      expect(reputationSince(null), isNull);
    });
  });

  group('daysOnMostro', () {
    test('counts whole days elapsed since the first trade', () {
      // Act
      final days = withClock(
        Clock.fixed(_now),
        () => daysOnMostro(_sinceDate, fallbackDays: 10),
      );

      // Assert — the stale fallback is ignored when since is present.
      expect(days, 64);
    });

    test('is zero on the day of the first trade', () {
      final days = withClock(
        Clock.fixed(_sinceDate.add(const Duration(hours: 23))),
        () => daysOnMostro(_sinceDate, fallbackDays: 10),
      );

      expect(days, 0);
    });

    test('falls back to the day count when since is absent', () {
      final days = withClock(
        Clock.fixed(_now),
        () => daysOnMostro(null, fallbackDays: 10),
      );

      expect(days, 10);
    });

    test('clamps a since in the future to zero', () {
      final days = withClock(
        Clock.fixed(_sinceDate.subtract(const Duration(days: 3))),
        () => daysOnMostro(_sinceDate, fallbackDays: 10),
      );

      expect(days, 0);
    });
  });

  group('TradeInfo.peerDaysOnMostro', () {
    test('prefers peerSince over the stale peerDays', () {
      // Arrange
      final trade = fakeTrade(peerDays: 10, peerSince: _since);

      // Act
      final days = withClock(Clock.fixed(_now), () => trade.peerDaysOnMostro);

      // Assert
      expect(days, 64);
    });

    test('falls back to peerDays from a daemon without since', () {
      final trade = fakeTrade(peerDays: 10);

      expect(trade.peerDaysOnMostro, 10);
    });

    test('is zero when the trade carries no reputation at all', () {
      expect(fakeTrade().peerDaysOnMostro, 0);
    });
  });
}

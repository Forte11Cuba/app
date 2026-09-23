import 'package:clock/clock.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mostro/features/about/providers/mostro_node_provider.dart';
import 'package:mostro/features/order/providers/invoice_providers.dart';
import 'package:mostro/features/trades/providers/trades_providers.dart';
import 'package:mostro/src/rust/api/types.dart';

import '../../../support/fake_trades.dart';

const _started = 1757678400;

Future<int?> _deadline({
  required TradeInfo? trade,
  required int? stepStart,
  required int now,
}) {
  // The whole read runs under the fixed clock: the provider body executes
  // on first listen, not on the `.future` await.
  return withClock(Clock.fixed(DateTime.fromMillisecondsSinceEpoch(now * 1000)), () async {
    final container = ProviderContainer(
      overrides: [
        tradeInfoProvider.overrideWith((ref, id) async => trade),
        mostroNodeProvider.overrideWith((ref) async => null),
        invoiceStepStartLookupProvider.overrideWithValue((id) async => stepStart),
      ],
    );
    addTearDown(container.dispose);
    final sub = container.listen(invoiceDeadlineProvider('order-1'), (_, _) {});
    addTearDown(sub.close);
    return container.read(invoiceDeadlineProvider('order-1').future);
  });
}

void main() {
  test('a recorded step start plus the node window is the deadline', () async {
    final deadline = await _deadline(
      trade: fakeTrade(isMine: true, startedAt: 1),
      stepStart: _started,
      now: _started + 10,
    );
    expect(deadline, _started + kDefaultInvoiceStepSeconds);
  });

  test(
    'a taker without a recorded step start counts from the take, not a fixed 900 s timeout',
    () async {
      // The taker's first reply is consumed by take_order before any status
      // cursor is written (PR #438 review).
      final deadline = await _deadline(
        trade: fakeTrade(isMine: false, startedAt: _started),
        stepStart: null,
        now: _started + 10,
      );
      expect(deadline, _started + kDefaultInvoiceStepSeconds);
    },
  );

  test('a maker without a recorded step start has no deadline', () async {
    // Their started_at is when the order was created, not when it was taken.
    final deadline = await _deadline(
      trade: fakeTrade(isMine: true, startedAt: _started),
      stepStart: null,
      now: _started + 10,
    );
    expect(deadline, isNull);
  });

  test('a fallback guess already in the past is answered as null', () async {
    // The stand-in is a guess; publishing an expired one as a fact painted
    // "time is up" over a step that had just opened (#568). Restored rows
    // date the trade by its order, hours before any step existed.
    final deadline = await _deadline(
      trade: fakeTrade(isMine: false, startedAt: _started),
      stepStart: null,
      now: _started + kDefaultInvoiceStepSeconds + 1,
    );
    expect(deadline, isNull);
  });

  test(
    'a recorded step start in the past still resolves to its real, past deadline',
    () async {
      // The gate is for the guess only: a recorded start is the truth, and
      // a genuinely expired step must keep reporting as expired.
      final deadline = await _deadline(
        trade: fakeTrade(isMine: false, startedAt: _started),
        stepStart: _started,
        now: _started + kDefaultInvoiceStepSeconds + 3600,
      );
      expect(deadline, _started + kDefaultInvoiceStepSeconds);
    },
  );
}

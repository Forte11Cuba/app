import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mostro/core/app_theme.dart';
import 'package:mostro/features/about/models/mostro_instance.dart';
import 'package:mostro/features/about/providers/mostro_node_provider.dart';
import 'package:mostro/features/home/providers/home_order_providers.dart';
import 'package:mostro/features/order/providers/invoice_providers.dart';
import 'package:mostro/features/order/providers/trade_state_provider.dart';
import 'package:mostro/features/trades/providers/trades_providers.dart';
import 'package:mostro/features/trades/screens/trade_detail_screen.dart';
import 'package:mostro/features/trades/widgets/trade_countdown.dart';
import 'package:mostro/l10n/app_localizations.dart';

import '../../support/fake_trades.dart';
import '../../support/provider_harness.dart';

const _orderId = 'order-countdown';

/// The window the node advertises for a waiting step.
const _stepWindow = 60;
final _now = DateTime.utc(2026, 9, 22, 12);

MostroInstance _node() =>
    const MostroInstance(pubKey: 'node', expirationSeconds: _stepWindow);

/// Pumps the screen for a seller waiting to pay, with [deadline] as what the
/// invoice step resolves to (null = not recorded).
Future<void> _pumpWaitingPayment(
  WidgetTester tester, {
  required int? deadline,
}) async {
  final trade = fakeTrade(
    id: _orderId,
    orderId: _orderId,
    status: OrderStatus.waitingPayment,
    amountSats: BigInt.from(11612),
  );
  final container = createContainer(
    overrides: [
      tradeRoleProvider.overrideWith((ref) => {_orderId: false}),
      tradeStatusProvider(
        _orderId,
      ).overrideWith((ref) => Stream.value(OrderStatus.waitingPayment)),
      orderBookProvider.overrideWith((ref) => Stream.value(const [])),
      rawTradesProvider.overrideWith((ref) async => [trade]),
      mostroNodeProvider.overrideWith((ref) async => _node()),
      invoiceDeadlineProvider(_orderId).overrideWith((ref) async => deadline),
    ],
  );

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildDarkTheme(),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: const TradeDetailScreen(orderId: _orderId),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  testWidgets('a waiting step counts to the node deadline, not to expires_at', (
    tester,
  ) async {
    await withClock(Clock.fixed(_now), () async {
      final deadline = _now.add(const Duration(seconds: 45));
      await _pumpWaitingPayment(
        tester,
        deadline: deadline.millisecondsSinceEpoch ~/ 1000,
      );

      final countdown = tester.widget<TradeCountdown>(
        find.byType(TradeCountdown),
      );
      // 45 s left of the node's 60 s window. Counting to `expires_at` would
      // have shown the event's retention instead: ~336 hours.
      expect(countdown.remaining, const Duration(seconds: 45));
      expect(countdown.total, const Duration(seconds: _stepWindow));
    });
  });

  testWidgets('no deadline, no countdown', (tester) async {
    await withClock(Clock.fixed(_now), () async {
      // What a maker gets: the reply that opened the step was consumed by the
      // take, so nothing recorded when it started.
      await _pumpWaitingPayment(tester, deadline: null);

      expect(find.byType(TradeCountdown), findsNothing);
    });
  });
}

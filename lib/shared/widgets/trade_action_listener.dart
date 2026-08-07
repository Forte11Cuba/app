import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mostro/core/app_routes.dart';
import 'package:mostro/features/order/providers/trade_state_provider.dart';
import 'package:mostro/src/rust/api/orders.dart' as orders_api;
import 'package:mostro/src/rust/api/types.dart';

/// Auto-opens the invoice screens when the daemon requests action.
///
/// Both `add-invoice` and `pay-invoice` carry expiration timeouts, so the
/// user must learn about them no matter which screen is open. This widget
/// wraps the app root and listens to [tradeUpdatesProvider] (pushed by the
/// Rust ingest after book and DB are synced): `WaitingBuyerInvoice` sends
/// the buyer to the add-invoice screen, `WaitingPayment` sends the seller
/// to the pay-invoice screen.
///
/// Only makers ever reach this path — a taker's first reply is consumed by
/// the take waiter in Rust and produces no emission (TakeOrderScreen
/// navigates locally instead).
class TradeActionListener extends ConsumerStatefulWidget {
  const TradeActionListener({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<TradeActionListener> createState() =>
      _TradeActionListenerState();
}

class _TradeActionListenerState extends ConsumerState<TradeActionListener> {
  /// Updates whose role lookup is still in flight, keyed by
  /// `orderId/status`, so a burst of identical emissions navigates once.
  final Set<String> _inFlight = {};

  Future<void> _handle(TradeUpdate update) async {
    final destination = switch (update.status) {
      OrderStatus.waitingBuyerInvoice =>
        AppRoute.addInvoicePath(update.orderId),
      OrderStatus.waitingPayment => AppRoute.payInvoicePath(update.orderId),
      _ => null,
    };
    if (destination == null) return;

    final key = '${update.orderId}/${update.status}';
    if (!_inFlight.add(key)) return;
    try {
      final role = await orders_api.getTradeRole(orderId: update.orderId);
      // The daemon addresses add-invoice to the buyer and pay-invoice to
      // the seller, but the same statuses also reach the counterparty as
      // informational syncs (waiting-seller-to-pay persists WaitingPayment
      // on the buyer side too) — those must not navigate.
      final actionable = switch (update.status) {
        OrderStatus.waitingBuyerInvoice => role == TradeRole.buyer,
        OrderStatus.waitingPayment => role == TradeRole.seller,
        _ => false,
      };
      if (!actionable || !mounted) return;
      final current =
          appRouter.routerDelegate.currentConfiguration.uri.toString();
      if (current == destination) return;
      // Screens expect their role in this map before being navigated to
      // (see tradeRoleProvider docs).
      ref.read(tradeRoleProvider.notifier).state = {
        ...ref.read(tradeRoleProvider),
        update.orderId: role == TradeRole.buyer,
      };
      appRouter.push(destination);
    } catch (e, st) {
      debugPrint(
          '[TradeActionListener] failed to handle ${update.orderId}: $e\n$st');
    } finally {
      _inFlight.remove(key);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<TradeUpdate>>(tradeUpdatesProvider, (prev, next) {
      final update = next.valueOrNull;
      if (update != null) _handle(update);
    });
    return widget.child;
  }
}

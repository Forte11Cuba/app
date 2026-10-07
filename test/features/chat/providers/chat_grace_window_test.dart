import 'package:clock/clock.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mostro/features/chat/models/chat_list_rules.dart';
import 'package:mostro/features/chat/providers/chat_list_provider.dart';
import 'package:mostro/features/chat/providers/chat_providers.dart';
import 'package:mostro/features/trades/models/trades_list_rules.dart';
import 'package:mostro/features/trades/providers/trade_rows_provider.dart';
import 'package:mostro/src/rust/api/types.dart'
    show OrderStatus, TradeInfo, TradeRole;

import '../../../support/fake_trades.dart';
import '../../../support/trade_rows_harness.dart';

const _orderId = 'order-grace';

int _nowSeconds() => clock.now().millisecondsSinceEpoch ~/ 1000;

TradeRow _completed(int completedAt) => TradeRow(
  orderId: _orderId,
  status: OrderStatus.success,
  rowStatus: OrderStatus.success,
  state: TradeRowState.of(
    status: OrderStatus.success,
    isBuyer: true,
    ratedByMe: false,
    canRate: true,
  ),
  isSelling: false,
  isMaker: false,
  fiatAmount: 100,
  fiatAmountMin: null,
  fiatAmountMax: null,
  fiatCode: 'USD',
  premium: 0,
  amountSats: 1000,
  paymentMethod: 'bank',
  startedAt: 0,
  peerHandle: null,
  completedAt: completedAt,
);

/// A seller's trade whose row is still at the release: the book's `success`
/// reaches the seller before the row's own, and before the completion time
/// that comes with it.
TradeInfo _releasedSeller() => fakeTrade(
  id: 'released',
  status: OrderStatus.settledHoldInvoice,
  role: TradeRole.seller,
);

/// A container with [trade] as the only trade, its order's live status
/// [live] (the row's own when null), and its rows loaded.
Future<ProviderContainer> _loaded(TradeInfo trade, {OrderStatus? live}) async {
  final container = tradeRowsContainer(
    [trade],
    live: {if (live != null) trade.order.id: live},
  );
  await loadTradeRows(container);
  return container;
}

/// The room's state for [trade], through the real trade rows.
Future<ChatRowState> _roomOf(TradeInfo trade, {OrderStatus? live}) async {
  final container = await _loaded(trade, live: live);
  return container.read(chatRowStateProvider(trade.order.id));
}

void main() {
  // #642: nothing rings when the hour is over, so the provider must close
  // the conversation by the clock alone.
  testWidgets('a completed trade\'s room turns read-only when its hour ends', (
    tester,
  ) async {
    final now = _nowSeconds();
    final container = ProviderContainer(
      overrides: [
        tradeRowsProvider.overrideWithValue(AsyncData([_completed(now - 60)])),
      ],
    );
    addTearDown(container.dispose);
    final sub = container.listen(chatRowStateProvider(_orderId), (_, _) {});
    addTearDown(sub.close);

    expect(sub.read().canCompose, isTrue);

    await tester.pump(const Duration(seconds: kPeerChatGraceSeconds - 61));
    expect(sub.read().canCompose, isTrue);

    await tester.pump(const Duration(seconds: 2));
    expect(sub.read().isReadOnly, isTrue);
  });

  // The trades list shows the live status, which can run ahead of the
  // persisted row. Rust keeps the chat, and takes a send, for as long as the
  // row is live (`chat_still_relevant_at`); a room that followed the book
  // swapped the composer out, and the draft with it, until the row caught
  // up.
  group('the conversation follows the persisted trade row', () {
    test('a live success ahead of its row keeps the composer', () async {
      final room = await _roomOf(_releasedSeller(), live: OrderStatus.success);
      expect(room.canCompose, isTrue);
      expect(room.isReadOnly, isFalse);
    });

    test('a completed row inside its hour keeps the composer', () async {
      final room = await _roomOf(
        fakeTrade(
          id: 'done',
          status: OrderStatus.success,
          completedAt: _nowSeconds() - 60,
        ),
      );
      expect(room.canCompose, isTrue);
    });

    test('a completed row with no completion time is read-only', () async {
      final room = await _roomOf(
        fakeTrade(id: 'done', status: OrderStatus.success),
      );
      expect(room.isReadOnly, isTrue);
    });

    test('a cancelled row is read-only', () async {
      final room = await _roomOf(
        fakeTrade(id: 'gone', status: OrderStatus.canceled),
      );
      expect(room.isReadOnly, isTrue);
    });

    test('the chat list keeps it among the open conversations', () async {
      final trade = _releasedSeller();
      final container = await _loaded(trade, live: OrderStatus.success);
      container.read(chatRoomsNotifierProvider.notifier).setRooms([
        ChatRoomState(
          orderId: trade.order.id,
          peerPubkey: trade.counterpartyPubkey,
          peerHandle: 'peer',
          peerIconIndex: 0,
          peerColorHue: 0,
          isSelling: true,
        ),
      ]);

      final groups = container.read(groupedChatRowsProvider);
      expect(groups.map((g) => g.group), [ChatGroup.active]);
    });
  });
}

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mostro/features/chat/models/chat_list_rules.dart';
import 'package:mostro/features/chat/providers/chat_providers.dart';
import 'package:mostro/features/trades/providers/trade_rows_provider.dart';

/// One conversation of the chat list: the room and the trade it belongs to.
@immutable
class ChatListRow {
  const ChatListRow({
    required this.room,
    required this.trade,
    required this.state,
  });

  final ChatRoomState room;

  /// Null while the trades have not loaded. The context line is composed
  /// from this model — direction, amount, currency, status — never from a
  /// text stored with the chat.
  final TradeRow? trade;
  final ChatRowState state;
}

Map<String, TradeRow> _tradesById(Ref ref) => {
  for (final t
      in ref.watch(tradeRowsProvider).valueOrNull ?? const <TradeRow>[])
    t.orderId: t,
};

int _nowSeconds() => clock.now().millisecondsSinceEpoch ~/ 1000;

/// The state of the conversation about [trade] at [now] (Unix seconds).
///
/// Whether it is still open is decided on the persisted row
/// ([TradeRow.rowStatus] and its [TradeRow.completedAt]), not on the status
/// the trades list shows: Rust keeps the chat live, and takes a send, for as
/// long as the row is (`chat_still_relevant_at`), and the book's status can
/// run ahead of it. Decided on the shown status, a `success` in the book
/// ahead of the row's own — and of the completion time the row gets with it
/// — would close the room until the row caught up, and the draft would go
/// with the composer. The avatar's tone still follows the shown status
/// ([TradeRow.state]).
ChatRowState _stateOf(TradeRow? trade, int now) => ChatRowState.of(
  status: trade?.rowStatus,
  trade: trade?.state,
  completedAt: trade?.completedAt,
  now: now,
);

/// Rebuild the provider when the first of [trades]' grace windows still
/// running at [now] ends (#642): nothing else rings when a conversation
/// closes by the clock alone. Dated from the persisted row, as [_stateOf]
/// decides.
void _rebuildWhenAGraceWindowEnds(
  Ref ref,
  Iterable<TradeRow?> trades,
  int now,
) {
  final ends = [
    for (final trade in trades)
      if (trade != null)
        if (chatGraceEndsAt(
              status: trade.rowStatus,
              completedAt: trade.completedAt,
            )
            case final end? when end > now)
          end,
  ];
  if (ends.isEmpty) return;
  final first = ends.reduce((a, b) => a < b ? a : b);
  final timer = Timer(Duration(seconds: first - now), ref.invalidateSelf);
  ref.onDispose(timer.cancel);
}

/// The conversations as grouped for the Messages segment.
final groupedChatRowsProvider = Provider<List<ChatRowGroup<ChatListRow>>>((
  ref,
) {
  final trades = _tradesById(ref);
  final now = _nowSeconds();
  final rows = [
    for (final room in ref.watch(chatRoomsNotifierProvider))
      ChatListRow(
        room: room,
        trade: trades[room.orderId],
        state: _stateOf(trades[room.orderId], now),
      ),
  ];
  _rebuildWhenAGraceWindowEnds(ref, rows.map((r) => r.trade), now);
  return groupChatRows(
    rows,
    groupOf: (r) => r.state.group,
    lastMessageAt: (r) => r.room.lastMessageAt,
  );
});

/// The state of one conversation, for the chat room: whether it may compose
/// yet, and whether it is read-only — both from the persisted trade row, as
/// Rust decides ([_stateOf]). A failed trades load reads as open — a read
/// error must not take the composer away from a live trade.
final chatRowStateProvider = Provider.family<ChatRowState, String>((
  ref,
  orderId,
) {
  final trades = ref.watch(tradeRowsProvider);
  if (trades.isLoading && !trades.hasValue) return ChatRowState.resolving;
  final trade = _tradesById(ref)[orderId];
  final now = _nowSeconds();
  // The room turns read-only on its own when a completed trade's window ends.
  _rebuildWhenAGraceWindowEnds(ref, [trade], now);
  return _stateOf(trade, now);
});

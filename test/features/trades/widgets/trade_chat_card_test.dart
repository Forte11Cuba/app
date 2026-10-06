import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mostro/core/app_routes.dart';
import 'package:mostro/core/app_theme.dart';
import 'package:mostro/features/chat/providers/chat_providers.dart';
import 'package:mostro/features/trades/widgets/trade_chat_card.dart';
import 'package:mostro/l10n/app_localizations.dart';
import 'package:mostro/shared/widgets/tab_app_bar.dart' show CountBadge;

const _orderId = 'order-chat';

/// The card alone, under a router whose chat route says which room opened.
Future<void> _pump(
  WidgetTester tester, {
  required bool closed,
  int unread = 0,
}) async {
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder:
            (_, __) => Scaffold(
              body: TradeChatCard(orderId: _orderId, closed: closed),
            ),
      ),
      GoRoute(
        path: AppRoute.chatRoom,
        builder:
            (_, state) =>
                Scaffold(body: Text('room ${state.pathParameters['orderId']}')),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        chatRoomsNotifierProvider.overrideWith(
          (ref) =>
              ChatRoomsNotifier()..setRooms([
                ChatRoomState(
                  orderId: _orderId,
                  peerPubkey: 'peer',
                  peerHandle: 'bright-fox-41',
                  peerIconIndex: 3,
                  peerColorHue: 120,
                  isSelling: false,
                  unreadCount: unread,
                ),
              ]),
        ),
      ],
      child: MaterialApp.router(
        theme: buildDarkTheme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final closed in [false, true]) {
    testWidgets('a tap opens the room (closed: $closed)', (tester) async {
      await _pump(tester, closed: closed);
      await tester.tap(find.byType(TradeChatCard));
      await tester.pumpAndSettle();
      expect(find.text('room $_orderId'), findsOneWidget);
    });
  }

  testWidgets('the unread count reads as it is up to 99', (tester) async {
    await _pump(tester, closed: false, unread: 7);
    expect(find.text('7'), findsOneWidget);
    // The ringed badge keeps the 16 dp the hand-drawn one had.
    final badge = find.ancestor(
      of: find.byType(CountBadge),
      matching: find.byType(Container),
    );
    expect(tester.getSize(badge.first).height, 16);
  });

  testWidgets('past 99 unread messages the count reads 99+', (tester) async {
    await _pump(tester, closed: false, unread: 150);
    expect(find.text('99+'), findsOneWidget);
    expect(find.text('150'), findsNothing);
  });
}

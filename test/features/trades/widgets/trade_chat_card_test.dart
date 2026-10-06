import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mostro/core/app_routes.dart';
import 'package:mostro/core/app_theme.dart';
import 'package:mostro/features/trades/widgets/trade_chat_card.dart';
import 'package:mostro/l10n/app_localizations.dart';

const _orderId = 'order-chat';

/// The card alone, under a router whose chat route says which room opened.
Future<void> _pump(WidgetTester tester, {required bool closed}) async {
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
}

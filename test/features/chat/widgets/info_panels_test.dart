import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:mostro/core/app_theme.dart';
import 'package:mostro/features/chat/providers/chat_providers.dart';
import 'package:mostro/features/chat/screens/chat_room_screen.dart';
import 'package:mostro/features/chat/widgets/info_panels.dart';
import 'package:mostro/features/chat/widgets/trade_state_header.dart';
import 'package:mostro/features/home/providers/home_order_providers.dart';
import 'package:mostro/features/order/models/order_detail_rules.dart'
    show shortOrderId;
import 'package:mostro/features/order/providers/trade_state_provider.dart';
import 'package:mostro/features/trades/providers/trades_providers.dart';
import 'package:mostro/l10n/app_localizations.dart';
import 'package:mostro/l10n/app_localizations_en.dart';
import 'package:mostro/shared/widgets/counterpart_reputation_row.dart';
import 'package:mostro/shared/widgets/nym_avatar.dart';
import 'package:mostro/src/rust/api/types.dart' as rust_types;

import '../../../support/fake_orders.dart';
import '../../../support/fake_trades.dart';
import '../../../support/load_app_fonts.dart';
import '../../../support/provider_harness.dart';

const _orderId = 'order-info';
const _peerPubkey =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _peerHandle = 'vivid-bird';

/// 2026-07-16, when the order was published.
const _createdAt = 1784207520;

final _en = AppLocalizationsEn();

/// The trade row as Rust persists it: a sell of 17,122 sats for 23,478 ARS
/// paid through Mercado Pago, the case the issue was reported on.
rust_types.TradeInfo _trade({
  rust_types.OrderStatus status = rust_types.OrderStatus.success,
  rust_types.TradeRole role = rust_types.TradeRole.seller,
  bool isMine = false,
  BigInt? amountSats,
  double? fiatAmount = 23478,
  double? fiatAmountMin,
  double? fiatAmountMax,
  String fiatCode = 'ARS',
  String paymentMethod = 'Mercado Pago',
  double? peerRating,
  int? peerReviews,
  int? peerDays,
}) => fakeTrade(
  id: 'row-info',
  orderId: _orderId,
  status: status,
  role: role,
  isMine: isMine,
  startedAt: _createdAt,
  amountSats: amountSats ?? BigInt.from(17122),
  fiatAmount: fiatAmount,
  fiatAmountMin: fiatAmountMin,
  fiatAmountMax: fiatAmountMax,
  fiatCode: fiatCode,
  paymentMethod: paymentMethod,
  peerRating: peerRating,
  peerReviews: peerReviews,
  peerDays: peerDays,
);

/// The room the chat header renders: alias and avatar of this order's peer.
const _room = ChatRoomState(
  orderId: _orderId,
  peerPubkey: _peerPubkey,
  peerHandle: _peerHandle,
  peerIconIndex: 7,
  peerColorHue: 120,
  isSelling: true,
);

/// Pumps [ChatRoomScreen] bridge-free, as `chat_room_hydration_test.dart`
/// does. [trades] is the persisted trade list, [book] the order the sticky
/// header resolves, and [live] the polled status; an absent one stays
/// unresolved. The room is seeded so the header shows [_peerHandle].
Future<void> _pumpChatRoom(
  WidgetTester tester, {
  List<rust_types.TradeInfo> trades = const [],
  OrderItem? book,
  rust_types.OrderStatus? live,
  Locale? locale,
  double textScale = 1,
  Size size = const Size(400, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final container = createContainer(
    overrides: [
      incomingMessageProvider(
        _orderId,
      ).overrideWith((ref) => const Stream.empty()),
      chatTradeOrderProvider(_orderId).overrideWith((ref) async => book),
      orderBookNotificationCountProvider.overrideWith((ref) => 0),
      rawTradesProvider.overrideWith((ref) async => trades),
      tradeStatusProvider(_orderId).overrideWith(
        (ref) =>
            live == null
                ? const Stream<rust_types.OrderStatus>.empty()
                : Stream.value(live),
      ),
    ],
  );
  container.read(chatRoomsNotifierProvider.notifier).upsertRoom(_room);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildDarkTheme(),
        locale: locale,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        builder:
            (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
        home: const ChatRoomScreen(orderId: _orderId),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

/// Opens a panel the way a user does: through its app-bar icon.
Future<void> _open(WidgetTester tester, String tooltip) async {
  await tester.tap(find.byTooltip(tooltip));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _openTradeInfo(WidgetTester tester) =>
    _open(tester, _en.exchangeInfoTooltip);

Future<void> _openUserInfo(WidgetTester tester) =>
    _open(tester, _en.userInfoTooltip);

Finder _inPanel<T>(Finder finder) =>
    find.descendant(of: find.byType(T), matching: finder);

/// What a panel must never show again: the placeholder dash, the phase
/// notes, and the peer keys the user tab used to carry.
void _expectNoPlaceholders<T>() {
  expect(_inPanel<T>(find.text('—')), findsNothing);
  expect(_inPanel<T>(find.textContaining('Phase 10')), findsNothing);
  expect(_inPanel<T>(find.textContaining('Fase 10')), findsNothing);
}

String _created(int seconds) => DateFormat.yMMMd(
  'en',
).add_Hm().format(DateTime.fromMillisecondsSinceEpoch(seconds * 1000));

void main() {
  group('Trade information panel', () {
    testWidgets('opens from the info icon with the trade row\'s figures', (
      tester,
    ) async {
      await _pumpChatRoom(
        tester,
        trades: [_trade()],
        book: fakeOrder(id: _orderId, status: rust_types.OrderStatus.active),
        live: rust_types.OrderStatus.success,
      );
      expect(find.byType(TradeInformationTab), findsNothing);

      await _openTradeInfo(tester);

      expect(find.byType(TradeInformationTab), findsOneWidget);
      const panel = _inPanel<TradeInformationTab>;
      expect(panel(find.text(_en.tradeInformationTitle)), findsOneWidget);
      expect(panel(find.text(_en.satsAmount('17,122'))), findsOneWidget);
      expect(panel(find.text('23,478 ARS')), findsOneWidget);
      expect(panel(find.text('Mercado Pago')), findsOneWidget);
      expect(panel(find.text(_created(_createdAt))), findsOneWidget);
      expect(panel(find.text(shortOrderId(_orderId))), findsOneWidget);
      _expectNoPlaceholders<TradeInformationTab>();
    });

    testWidgets('shows the status the trade header shows, not "Active"', (
      tester,
    ) async {
      // The book entry still reads `active`; the live status says the
      // trade succeeded, and the header goes with the live status.
      await _pumpChatRoom(
        tester,
        trades: [_trade()],
        book: fakeOrder(id: _orderId, status: rust_types.OrderStatus.active),
        live: rust_types.OrderStatus.success,
      );

      await _openTradeInfo(tester);

      final success = _en.tradeFilterSuccess;
      expect(
        find.descendant(
          of: find.byType(TradeStateHeader),
          matching: find.text(success),
        ),
        findsOneWidget,
        reason: 'the header this panel must agree with',
      );
      const panel = _inPanel<TradeInformationTab>;
      expect(panel(find.text(success.toUpperCase())), findsOneWidget);
      expect(panel(find.text(_en.tradeFilterActive)), findsNothing);
      expect(
        panel(find.text(_en.tradeFilterActive.toUpperCase())),
        findsNothing,
      );
    });

    testWidgets('falls back to the order the header resolves', (tester) async {
      await _pumpChatRoom(
        tester,
        book: fakeOrder(
          id: _orderId,
          fiatAmount: 1225,
          fiatCode: 'ARS',
          amountSats: BigInt.from(1117),
          paymentMethod: 'Mercado Pago',
          status: rust_types.OrderStatus.active,
        ),
      );

      await _openTradeInfo(tester);

      const panel = _inPanel<TradeInformationTab>;
      expect(panel(find.text('1,225 ARS')), findsOneWidget);
      expect(panel(find.text(_en.satsAmount('1,117'))), findsOneWidget);
      expect(
        panel(find.text(_en.tradeFilterActive.toUpperCase())),
        findsOneWidget,
      );
      expect(panel(find.text('Mercado Pago')), findsOneWidget);
      _expectNoPlaceholders<TradeInformationTab>();
    });

    testWidgets('leaves out the rows the trade does not carry', (tester) async {
      // No payment method, sats not priced yet, no book entry, and no live
      // status: the row's own status and fiat are all there is.
      await _pumpChatRoom(
        tester,
        trades: [
          _trade(
            status: rust_types.OrderStatus.active,
            amountSats: BigInt.zero,
            paymentMethod: '',
          ),
        ],
      );

      await _openTradeInfo(tester);

      const panel = _inPanel<TradeInformationTab>;
      expect(panel(find.text('23,478 ARS')), findsOneWidget);
      expect(
        panel(find.text(_en.tradeFilterActive.toUpperCase())),
        findsOneWidget,
      );
      expect(panel(find.text(_en.satsAmountLabel)), findsNothing);
      expect(panel(find.text(_en.paymentMethodLabel)), findsNothing);
      _expectNoPlaceholders<TradeInformationTab>();
    });

    testWidgets('a range order taken for one amount shows that amount', (
      tester,
    ) async {
      await _pumpChatRoom(
        tester,
        trades: [
          _trade(
            fiatAmount: 150,
            fiatAmountMin: 100,
            fiatAmountMax: 500,
            fiatCode: 'USD',
          ),
        ],
      );

      await _openTradeInfo(tester);

      const panel = _inPanel<TradeInformationTab>;
      expect(panel(find.text('150 USD')), findsOneWidget);
      expect(panel(find.textContaining('100 – 500')), findsNothing);
    });
  });

  group('User information panel', () {
    testWidgets('opens from the user icon with the peer\'s alias and avatar', (
      tester,
    ) async {
      await _pumpChatRoom(
        tester,
        trades: [_trade()],
        book: fakeOrder(
          id: _orderId,
          rating: 4.8,
          tradeCount: 12,
          daysActive: 186,
        ),
      );
      expect(find.byType(UserInformationTab), findsNothing);

      await _openUserInfo(tester);

      expect(find.byType(UserInformationTab), findsOneWidget);
      const panel = _inPanel<UserInformationTab>;
      expect(panel(find.text(_en.userInformationTitle)), findsOneWidget);
      expect(panel(find.text(_peerHandle)), findsOneWidget);
      final avatar = tester.widget<NymAvatar>(panel(find.byType(NymAvatar)));
      expect(avatar.pseudonym, _peerHandle);
      expect(avatar.iconIndex, _room.peerIconIndex);
      expect(avatar.colorHue, _room.peerColorHue);
    });

    testWidgets('a taker sees the maker\'s reputation from the order', (
      tester,
    ) async {
      await _pumpChatRoom(
        tester,
        trades: [_trade(role: rust_types.TradeRole.buyer)],
        book: fakeOrder(
          id: _orderId,
          rating: 4.8,
          tradeCount: 12,
          daysActive: 186,
        ),
      );

      await _openUserInfo(tester);

      final row = tester.widget<CounterpartReputationRow>(
        _inPanel<UserInformationTab>(find.byType(CounterpartReputationRow)),
      );
      expect(row.rating, 4.8);
      expect(row.reviews, 12);
      expect(row.days, 186);
      expect(row.counterpartIsBuyer, isFalse, reason: 'the maker sells');
    });

    testWidgets('a maker sees the taker\'s reputation snapshot', (
      tester,
    ) async {
      await _pumpChatRoom(
        tester,
        trades: [
          _trade(isMine: true, peerRating: 4.4, peerReviews: 4, peerDays: 64),
        ],
        // The book's rating tag is the maker's own: never the peer's.
        book: fakeOrder(id: _orderId, isMine: true, rating: 5, tradeCount: 99),
      );

      await _openUserInfo(tester);

      final row = tester.widget<CounterpartReputationRow>(
        _inPanel<UserInformationTab>(find.byType(CounterpartReputationRow)),
      );
      expect(row.rating, 4.4);
      expect(row.reviews, 4);
      expect(row.days, 64);
      expect(row.counterpartIsBuyer, isTrue, reason: 'this maker sells');
    });

    testWidgets('says so when the peer\'s reputation is not known', (
      tester,
    ) async {
      // A maker whose taker shared no reputation (full privacy).
      await _pumpChatRoom(
        tester,
        trades: [_trade(isMine: true)],
        book: fakeOrder(id: _orderId, isMine: true, rating: 5),
      );

      await _openUserInfo(tester);

      const panel = _inPanel<UserInformationTab>;
      expect(panel(find.byType(CounterpartReputationRow)), findsNothing);
      expect(panel(find.text(_en.peerReputationUnavailable)), findsOneWidget);
    });

    testWidgets('shows no peer key, shared key or copy button', (tester) async {
      await _pumpChatRoom(
        tester,
        trades: [_trade()],
        book: fakeOrder(id: _orderId, rating: 4.8, tradeCount: 12),
      );

      await _openUserInfo(tester);

      const panel = _inPanel<UserInformationTab>;
      expect(panel(find.textContaining(_peerPubkey)), findsNothing);
      expect(panel(find.textContaining('Public Key')), findsNothing);
      expect(panel(find.textContaining('Shared Key')), findsNothing);
      expect(panel(find.textContaining('shared key')), findsNothing);
      expect(panel(find.byIcon(Icons.copy)), findsNothing);
      expect(panel(find.byIcon(Icons.copy_rounded)), findsNothing);
      expect(panel(find.byIcon(Icons.copy_outlined)), findsNothing);
      expect(panel(find.byType(GestureDetector)), findsNothing);
      _expectNoPlaceholders<UserInformationTab>();
    });
  });

  group('at large text', () {
    // Real glyph widths: the test font draws every glyph a full em wide.
    setUpAll(loadAppFonts);

    testWidgets('both panels open at 2x text in German on a phone', (
      tester,
    ) async {
      // The size of the order screens' 2x test (order_detail_golden_test).
      await _pumpChatRoom(
        tester,
        trades: [_trade(peerRating: 4.4, peerReviews: 4, peerDays: 64)],
        book: fakeOrder(id: _orderId, rating: 4.8, tradeCount: 12),
        live: rust_types.OrderStatus.success,
        locale: const Locale('de'),
        textScale: 2,
        size: const Size(360, 760),
      );
      final de = lookupAppLocalizations(const Locale('de'));

      await _open(tester, de.exchangeInfoTooltip);
      expect(find.byType(TradeInformationTab), findsOneWidget);
      expect(tester.takeException(), isNull);

      await _open(tester, de.userInfoTooltip);
      expect(find.byType(UserInformationTab), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    // The chat screen around the panels does not fit 320 dp at 2x yet (its
    // app-bar title overflows before any panel opens), so the panels are
    // held to that width on their own.
    for (final panel in ['trade', 'user']) {
      testWidgets('the $panel panel fits 320 dp in German at 2x text', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final container = createContainer(
          overrides: [
            chatTradeOrderProvider(
              _orderId,
            ).overrideWith((ref) async => fakeOrder(id: _orderId, rating: 4.8)),
            rawTradesProvider.overrideWith(
              (ref) async => [
                _trade(peerRating: 4.4, peerReviews: 4, peerDays: 64),
              ],
            ),
            tradeStatusProvider(_orderId).overrideWith(
              (ref) => Stream.value(rust_types.OrderStatus.fiatSent),
            ),
          ],
        );
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: buildDarkTheme(),
              locale: const Locale('de'),
              localizationsDelegates: const [
                AppLocalizations.delegate,
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              supportedLocales: AppLocalizations.supportedLocales,
              builder:
                  (context, child) => MediaQuery(
                    data: MediaQuery.of(
                      context,
                    ).copyWith(textScaler: const TextScaler.linear(2)),
                    child: child!,
                  ),
              home: Scaffold(
                body: Column(
                  children: [
                    panel == 'trade'
                        ? const TradeInformationTab(orderId: _orderId)
                        : const UserInformationTab(room: _room),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(tester.takeException(), isNull);
      });
    }
  });
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mostro/core/app_theme.dart';
import 'package:mostro/features/about/models/mostro_instance.dart';
import 'package:mostro/features/about/providers/mostro_node_provider.dart';
import 'package:mostro/features/order/models/invoice_rules.dart';
import 'package:mostro/features/order/providers/invoice_providers.dart';
import 'package:mostro/features/order/providers/trade_state_provider.dart';
import 'package:mostro/features/order/screens/add_lightning_invoice_screen.dart';
import 'package:mostro/features/settings/providers/nwc_provider.dart';
import 'package:mostro/features/trades/providers/trades_providers.dart';
import 'package:mostro/l10n/app_localizations.dart';
import 'package:mostro/src/rust/api/types.dart' show TradeUpdate;

Finder _semantics(String identifier) => find.byWidgetPredicate(
  (widget) => widget is Semantics && widget.properties.identifier == identifier,
);

/// The node's `invoice_expiration_window` rule reaches the row: an invoice
/// that is live but expires inside the window is refused with the minutes
/// the node needs, and submission stays shut.
void main() {
  testWidgets('an invoice expiring inside the node window is refused', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final submissions = <String>[];
    try {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            isWalletConnectedProvider.overrideWithValue(false),
            tradeAmountProvider.overrideWith(
              (ref, orderId) => Stream.value(BigInt.from(250)),
            ),
            tradeUpdatesProvider.overrideWith(
              (ref) => const Stream<TradeUpdate>.empty(),
            ),
            tradeInfoProvider.overrideWith((ref, orderId) async => null),
            mostroNodeProvider.overrideWith((ref) async => null),
            invoiceCheckerProvider.overrideWithValue(
              (request) async => const InvoiceCheckError(
                InvoiceProblem.expiresTooSoon,
                minRemainingSecs: 3600,
              ),
            ),
          ],
          child: MaterialApp(
            theme: buildDarkTheme(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('en'),
            home: AddLightningInvoiceScreen(
              orderId: 'order-1',
              submitInvoice: (orderId, invoice, sats) async {
                submissions.add(invoice);
              },
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'lnbc2500u1soon');
      // Past the validation debounce and the checker's reply.
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();

      expect(find.textContaining('60 minutes'), findsOneWidget);

      await tester.tap(_semantics('invoice.submit'), warnIfMissed: false);
      await tester.pump();
      await tester.pump();
      expect(submissions, isEmpty, reason: 'a refused invoice is never sent');
    } finally {
      semantics.dispose();
    }
  });

  // The window is two of the four rules away from being testable while the
  // node's Kind 38385 event is still in flight, and the screen watches an
  // `autoDispose` provider, so on a cold entry that fetch is only starting.
  // Calling such an invoice `valid` on `invoice.check` would hand automation
  // a pass for a rule that never ran — and `expires-too-soon` is exactly what
  // it turns into once the event lands.
  testWidgets('no verdict is claimed while the node facts are in flight', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final node = Completer<MostroInstance?>();
    try {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            isWalletConnectedProvider.overrideWithValue(false),
            tradeAmountProvider.overrideWith(
              (ref, orderId) => Stream.value(BigInt.from(250)),
            ),
            tradeUpdatesProvider.overrideWith(
              (ref) => const Stream<TradeUpdate>.empty(),
            ),
            tradeInfoProvider.overrideWith((ref, orderId) async => null),
            mostroNodeProvider.overrideWith((ref) => node.future),
            // The core can only pass what it was given: without the window,
            // an invoice that expires inside it looks valid.
            invoiceCheckerProvider.overrideWithValue(
              (request) async => const InvoiceCheckValid(250),
            ),
          ],
          child: MaterialApp(
            theme: buildDarkTheme(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('en'),
            home: const AddLightningInvoiceScreen(orderId: 'order-1'),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'lnbc2500u1soon');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();

      expect(
        _semantics('invoice.check'),
        findsNothing,
        reason: 'a pass the node facts could not test is not a verdict',
      );

      // Settling with no instance at all still settles it: the node publishes
      // no window, so there is nothing left to wait for and the local pass is
      // the whole answer. Note the context key is unchanged by this — what
      // moved is only whether the fetch is done.
      node.complete(null);
      await tester.pump();
      await tester.pump();

      expect(_semantics('invoice.check'), findsOneWidget);
    } finally {
      semantics.dispose();
    }
  });

  // A node switch recomputes the capabilities while this screen is open, and
  // Riverpod hands out the *previous* node's facts during that refetch. The
  // verdict standing on screen was judged against the node being replaced, so
  // it has to be withdrawn until the new facts land — otherwise automation
  // reads, and the buyer acts on, a window and a network that no longer apply.
  testWidgets('a node refresh withdraws the verdict until it settles again', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final fetches = <Completer<MostroInstance?>>[
      Completer<MostroInstance?>(),
      Completer<MostroInstance?>(),
    ];
    var served = 0;
    try {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            isWalletConnectedProvider.overrideWithValue(false),
            tradeAmountProvider.overrideWith(
              (ref, orderId) => Stream.value(BigInt.from(250)),
            ),
            tradeUpdatesProvider.overrideWith(
              (ref) => const Stream<TradeUpdate>.empty(),
            ),
            tradeInfoProvider.overrideWith((ref, orderId) async => null),
            mostroNodeProvider.overrideWith((ref) => fetches[served++].future),
            invoiceCheckerProvider.overrideWithValue(
              (request) async => const InvoiceCheckValid(250),
            ),
          ],
          child: MaterialApp(
            theme: buildDarkTheme(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('en'),
            home: const AddLightningInvoiceScreen(orderId: 'order-1'),
          ),
        ),
      );
      await tester.pump();

      fetches[0].complete(
        const MostroInstance(
          pubKey: 'node-a',
          lndNetworks: 'mainnet',
          invoiceExpirationWindow: 3600,
        ),
      );
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'lnbc2500u1ok');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();

      expect(
        _semantics('invoice.check'),
        findsOneWidget,
        reason: 'settled facts, so the verdict stands',
      );

      // The switch. The second fetch never answers, so the screen stays in
      // the refetch for the rest of the test.
      ProviderScope.containerOf(
        tester.element(find.byType(AddLightningInvoiceScreen)),
      ).invalidate(mostroNodeProvider);
      await tester.pump();
      await tester.pump();

      expect(
        _semantics('invoice.check'),
        findsNothing,
        reason: 'the verdict belonged to the node being replaced',
      );
      expect(served, 2, reason: 'the refetch really started');
    } finally {
      semantics.dispose();
    }
  });

  // The same withdrawal, for the direction that costs the buyer rather than
  // the daemon: a refusal judged against the replaced node's window would
  // keep `invoice.submit` shut on an invoice the new node may well accept.
  // A stale refusal is not degraded the way a stale pass is — only dropping
  // the retained facts changes the context key and forces the re-judge.
  testWidgets('a refusal from the replaced node is withdrawn too', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final fetches = <Completer<MostroInstance?>>[
      Completer<MostroInstance?>(),
      Completer<MostroInstance?>(),
    ];
    var served = 0;
    try {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            isWalletConnectedProvider.overrideWithValue(false),
            tradeAmountProvider.overrideWith(
              (ref, orderId) => Stream.value(BigInt.from(250)),
            ),
            tradeUpdatesProvider.overrideWith(
              (ref) => const Stream<TradeUpdate>.empty(),
            ),
            tradeInfoProvider.overrideWith((ref, orderId) async => null),
            mostroNodeProvider.overrideWith((ref) => fetches[served++].future),
            invoiceCheckerProvider.overrideWithValue(
              (request) async => const InvoiceCheckError(
                InvoiceProblem.expiresTooSoon,
                minRemainingSecs: 3600,
              ),
            ),
          ],
          child: MaterialApp(
            theme: buildDarkTheme(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('en'),
            home: const AddLightningInvoiceScreen(orderId: 'order-1'),
          ),
        ),
      );
      await tester.pump();

      fetches[0].complete(
        const MostroInstance(
          pubKey: 'node-a',
          lndNetworks: 'mainnet',
          invoiceExpirationWindow: 3600,
        ),
      );
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'lnbc2500u1soon');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();

      expect(_semantics('invoice.check'), findsOneWidget);
      expect(find.textContaining('60 minutes'), findsOneWidget);

      ProviderScope.containerOf(
        tester.element(find.byType(AddLightningInvoiceScreen)),
      ).invalidate(mostroNodeProvider);
      await tester.pump();
      await tester.pump();

      expect(
        _semantics('invoice.check'),
        findsNothing,
        reason: 'the window it was refused against is being replaced',
      );
      expect(served, 2, reason: 'the refetch really started');
    } finally {
      semantics.dispose();
    }
  });
}

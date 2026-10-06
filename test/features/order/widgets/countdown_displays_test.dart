import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mostro/core/app_theme.dart';
import 'package:mostro/core/invoice_palette.dart';
import 'package:mostro/core/trade_palette.dart';
import 'package:mostro/features/order/widgets/bond_widgets.dart';
import 'package:mostro/features/order/widgets/invoice_widgets.dart';
import 'package:mostro/features/trades/widgets/trade_countdown.dart';
import 'package:mostro/l10n/app_localizations.dart';

const _invoice = InvoicePalette.dark;
const _trade = TradePalette.dark;

Future<void> _pump(WidgetTester tester, Widget child) => tester.pumpWidget(
  MaterialApp(
    theme: buildDarkTheme(),
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: Center(child: child)),
  ),
);

String _hours(String h, String m) => '$h h $m';

Color? _bandFill(WidgetTester tester) {
  final box =
      tester
              .widget<Container>(
                find
                    .descendant(
                      of: find.byType(InvoiceTimeBand),
                      matching: find.byType(Container),
                    )
                    .first,
              )
              .decoration!
          as BoxDecoration;
  return box.color;
}

Color? _figureColor(WidgetTester tester, String text) =>
    tester.widget<Text>(find.text(text)).style?.color;

/// DS-CMP-21 (#723): one formatter, one set of tones, and every countdown
/// labeled.
void main() {
  group('TradeCountdown', () {
    testWidgets('reads hours as h mm, never h:mm', (tester) async {
      await _pump(
        tester,
        const TradeCountdown(
          remaining: Duration(hours: 1, minutes: 5),
          total: Duration(hours: 2),
          label: 'You have',
          isWaiting: false,
        ),
      );

      expect(find.text('1 h 05'), findsOneWidget);
      expect(find.text('1:05'), findsNothing);
    });

    testWidgets('in a 15-minute step, stays amber at three minutes', (
      tester,
    ) async {
      await _pump(
        tester,
        const TradeCountdown(
          remaining: Duration(minutes: 3),
          total: Duration(minutes: 15),
          label: 'You have',
          isWaiting: false,
        ),
      );

      expect(_figureColor(tester, '03:00'), _trade.timerWait);
    });

    testWidgets('turns coral and is announced once urgent', (tester) async {
      final semantics = tester.ensureSemantics();
      await _pump(
        tester,
        const TradeCountdown(
          remaining: Duration(seconds: 30),
          total: Duration(minutes: 15),
          label: 'You have',
          isWaiting: false,
        ),
      );

      expect(_figureColor(tester, '00:30'), _trade.timerUrgent);
      expect(
        tester.getSemantics(find.text('00:30')),
        isSemantics(isLiveRegion: true),
      );
      semantics.dispose();
    });
  });

  group('InvoiceTimeBand', () {
    testWidgets('in a long window, turns urgent at five minutes', (
      tester,
    ) async {
      await _pump(
        tester,
        InvoiceTimeBand(
          remaining: const Duration(minutes: 3),
          window: const Duration(hours: 2),
          sentence: (t) => 'The order is dropped in $t',
          hours: _hours,
        ),
      );

      expect(_bandFill(tester), _invoice.errorFill);
    });

    testWidgets('in an invoice window, waits for the last minute', (
      tester,
    ) async {
      await _pump(
        tester,
        InvoiceTimeBand(
          remaining: const Duration(minutes: 3),
          window: const Duration(minutes: 15),
          sentence: (t) => 'The invoice expires in $t',
          hours: _hours,
        ),
      );

      expect(_bandFill(tester), _invoice.timeFill);
    });
  });

  group('BondAmountRow', () {
    testWidgets('labels its time pill', (tester) async {
      await _pump(
        tester,
        const BondAmountRow(
          label: 'Refundable bond',
          sats: 1500,
          remaining: Duration(minutes: 10),
          window: Duration(minutes: 15),
          timeLabel: 'Pay within',
          hours: _hours,
          unit: 'sats',
        ),
      );

      expect(find.text('Pay within'), findsOneWidget);
      expect(find.text('10:00'), findsOneWidget);
    });
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mostro/core/app_theme.dart';
import 'package:mostro/features/order/widgets/range_amount_modal.dart';
import 'package:mostro/l10n/app_localizations.dart';

/// Opens the range dialog in [locale] and returns a reader for its result.
Future<double? Function()> _open(
  WidgetTester tester, {
  required Locale locale,
}) async {
  double? result;
  await tester.pumpWidget(
    MaterialApp(
      theme: buildDarkTheme(),
      locale: locale,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder:
            (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await showRangeAmountModal(
                    context: context,
                    min: 2000,
                    max: 998000,
                    currencyCode: 'ARS',
                  );
                },
                child: const Text('open'),
              ),
            ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return () => result;
}

void main() {
  // Issue #720: the dialog printed its bounds by hand (`2000 – 998000`)
  // right under a card that groups them (`2.000 – 998.000`).
  testWidgets("shows the bounds with the locale's grouping", (tester) async {
    await _open(tester, locale: const Locale('es'));

    expect(find.text('Mín: 2.000 – Máx: 998.000 ARS'), findsOneWidget);
  });

  testWidgets('groups the typed amount and returns its value', (tester) async {
    final result = await _open(tester, locale: const Locale('es'));

    await tester.enterText(find.byType(TextField), '25000');
    await tester.pump();
    expect(find.text('25.000'), findsOneWidget);

    await tester.tap(find.text('Enviar'));
    await tester.pumpAndSettle();
    expect(result(), 25000);
  });

  testWidgets("reads the locale's decimal separator", (tester) async {
    final result = await _open(tester, locale: const Locale('es'));

    await tester.enterText(find.byType(TextField), '2500,5');
    await tester.pump();
    await tester.tap(find.text('Enviar'));
    await tester.pumpAndSettle();

    expect(result(), 2500.5);
  });

  testWidgets('words the range error with grouped bounds', (tester) async {
    await _open(tester, locale: const Locale('en'));

    await tester.enterText(find.byType(TextField), '1000');
    await tester.pump();

    expect(
      find.text('Amount must be between 2,000 and 998,000'),
      findsOneWidget,
    );
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mostro/core/app_theme.dart';
import 'package:mostro/features/order/widgets/price_section.dart';
import 'package:mostro/l10n/app_localizations.dart';
import '../../../support/provider_harness.dart';

/// Pump [PriceSection] in Market mode with the premium provider seeded to
/// [premium]. A tall surface keeps the layout from overflowing the viewport.
Future<ProviderContainer> _pump(
  WidgetTester tester, {
  required double premium,
}) async {
  tester.view.physicalSize = const Size(1200, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final container = createContainer(
    overrides: [premiumValueProvider.overrideWith((ref) => premium)],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildDarkTheme(),
        locale: const Locale('en'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(
          resizeToAvoidBottomInset: false,
          body: PriceSection(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  group('PriceSection premium slider', () {
    double sliderMax(WidgetTester tester) =>
        tester.widget<Slider>(find.byType(Slider)).max;

    testWidgets(
      'expands to fit a value entered above the default range',
      (tester) async {
        await _pump(tester, premium: 20.0);
        // Slider grows to the entered value instead of clamping to +10%.
        expect(sliderMax(tester), 20.0);
      },
    );

    testWidgets(
      'accepts a whole-percent value typed into the field',
      (tester) async {
        final container = await _pump(tester, premium: 0.0);
        await tester.enterText(find.byType(TextField), '7');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();
        expect(container.read(premiumValueProvider), 7.0);
      },
    );

    testWidgets(
      'rejects a decimal typed into the field',
      (tester) async {
        final container = await _pump(tester, premium: 3.0);
        // The formatter drops '.' / ',', so a decimal never reaches state and
        // the premium stays a whole number.
        await tester.enterText(find.byType(TextField), '5.5');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();
        final value = container.read(premiumValueProvider);
        expect(value, value.roundToDouble());
        expect(value, isNot(5.5));
      },
    );

    testWidgets(
      'keeps expanded bounds stable while dragging 20 toward 0',
      (tester) async {
        final container = await _pump(tester, premium: 20.0);
        expect(sliderMax(tester), 20.0);

        // Grab the thumb near the right edge (value == max == 20) and drag left.
        final rect = tester.getRect(find.byType(Slider));
        final gesture = await tester.startGesture(
          Offset(rect.right - 24, rect.center.dy),
        );
        await tester.pump();

        // Drag toward zero in steps; the frozen max must not shrink under the
        // finger on any intermediate rebuild (the regression this guards). The
        // total distance is enough to cross back into the default range.
        for (var i = 0; i < 12; i++) {
          await gesture.moveBy(const Offset(-60, 0));
          await tester.pump();
          expect(
            sliderMax(tester),
            20.0,
            reason: 'max must stay frozen during the drag',
          );
        }

        // The value actually moved down while dragging (thumb is not pinned).
        expect(container.read(premiumValueProvider), lessThan(20.0));

        await gesture.up();
        await tester.pumpAndSettle();

        // Once the gesture ends the bounds recompute; the value landed inside
        // the default range, so the slider collapses back to +10%.
        expect(container.read(premiumValueProvider), lessThanOrEqualTo(10.0));
        expect(sliderMax(tester), kPremiumSliderDefault);
      },
    );
  });
}

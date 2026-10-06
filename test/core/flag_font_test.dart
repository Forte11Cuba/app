import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mostro/core/app_theme.dart';
import 'package:mostro/features/order/widgets/order_detail_cards.dart';

/// The family `pubspec.yaml` registers for the bundled flags (DS-TYP-8).
const _flags = 'NotoFlags';

const _argentina = '🇦🇷';

/// The fallback list the engine gets for the paragraph that draws [text].
List<String>? _fallbackOf(WidgetTester tester, String text) {
  final paragraph = tester.renderObject<RenderParagraph>(
    find.text(text, findRichText: true),
  );
  return paragraph.text.style?.fontFamilyFallback;
}

Widget _app(ThemeData theme, Widget child) =>
    MaterialApp(theme: theme, home: Scaffold(body: Center(child: child)));

void main() {
  group('the bundled flags font (DS-TYP-8)', () {
    test('is registered in pubspec.yaml, with its file and licence', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      final entry = RegExp(
        r'- family: NotoFlags\s+fonts:\s+- asset: (\S+)',
      ).firstMatch(pubspec);
      expect(entry, isNotNull, reason: 'no NotoFlags family in pubspec.yaml');
      final font = File(entry!.group(1)!);
      expect(font.existsSync(), isTrue, reason: '${font.path} is missing');
      expect(File('${font.parent.path}/LICENSE.txt').existsSync(), isTrue);
    });

    for (final (name, theme) in [
      ('dark', buildDarkTheme),
      ('light', buildLightTheme),
    ]) {
      testWidgets('a currency chip draws its flag from it ($name)', (
        tester,
      ) async {
        await tester.pumpWidget(
          _app(theme(), const OrderCurrencyChip(flag: _argentina, code: 'ARS')),
        );
        expect(_fallbackOf(tester, _argentina), contains(_flags));
      });

      testWidgets('a flag inside figures text still reaches it ($name)', (
        tester,
      ) async {
        // A node's name carries its region flag, and figures set their own
        // family: the fallback has to survive both.
        await tester.pumpWidget(
          _app(
            theme(),
            const Text(
              'Mostro $_argentina',
              style: TextStyle(
                fontFamily: AppFonts.figures,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        );
        expect(_fallbackOf(tester, 'Mostro $_argentina'), contains(_flags));
      });
    }

    test('is the fallback everywhere but native iOS and macOS', () {
      expect(AppFonts.flags, _flags);
      for (final platform in TargetPlatform.values) {
        final apple =
            platform == TargetPlatform.iOS || platform == TargetPlatform.macOS;
        // Core Text cannot draw CBDT; Apple's own emoji font has every flag.
        expect(
          flagFontFallback(platform, web: false),
          apple ? isNull : [_flags],
          reason: '$platform',
        );
        // The web engine draws with its own FreeType on every device.
        expect(flagFontFallback(platform, web: true), [_flags]);
      }
    });
  });
}

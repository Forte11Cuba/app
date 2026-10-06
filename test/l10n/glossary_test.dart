import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// DS-L10N-4: one word per concept, and no protocol jargon shown as a term.
/// Reads the ARB sources, so a new string that drifts fails here before a
/// screen shows it.
void main() {
  const locales = ['en', 'es', 'fr', 'de', 'it', 'nl'];

  Map<String, String> arb(String locale) {
    final raw =
        jsonDecode(File('lib/l10n/app_$locale.arb').readAsStringSync())
            as Map<String, dynamic>;
    return {
      for (final e in raw.entries)
        if (!e.key.startsWith('@') && e.value is String)
          e.key: e.value as String,
    };
  }

  // The glossary's retired verbs for ticking a payment method.
  final chosen = RegExp(
    r'\b(chosen|elegid[oa]s?|choisi[es]?|scelt[oi]|gekozen|gewählt)\b',
    caseSensitive: false,
  );

  for (final locale in locales) {
    test('$locale: payment methods are "selected", never "chosen"', () {
      final drift = {
        for (final e in arb(locale).entries)
          if (e.key.startsWith('paymentMethod') && chosen.hasMatch(e.value))
            e.key: e.value,
      };
      expect(drift, isEmpty);
    });

    test('$locale: the hold invoice is explained, not named as a term', () {
      final strings = arb(locale);
      for (final key in ['invoiceHoldNote', 'bondWhyHold']) {
        final value = strings[key];
        expect(value, isNotNull, reason: key);
        expect(value, isNot(contains('{hold}')), reason: key);
        expect(
          RegExp(r'\bhold\b', caseSensitive: false).hasMatch(value!),
          isFalse,
          reason: '$key: $value',
        );
      }
    });
  }
}

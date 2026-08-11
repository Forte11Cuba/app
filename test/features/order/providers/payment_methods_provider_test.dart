import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

Map<String, List<String>> _loadShipped() {
  final raw = File('assets/data/payment_methods.json').readAsStringSync();
  final decoded = jsonDecode(raw) as Map<String, dynamic>;
  return decoded.map(
    (k, v) => MapEntry(k, (v as List<dynamic>).cast<String>()),
  );
}

List<String> _forCurrency(Map<String, List<String>> data, String code) =>
    data[code] ?? data['default'] ?? const ['Bank Transfer', 'Cash in person'];

void main() {
  late Map<String, List<String>> data;
  setUpAll(() => data = _loadShipped());

  group('payment_methods.json currency contract', () {
    test('ships a default fallback plus many currencies', () {
      expect(data.containsKey('default'), isTrue);
      expect(data.length, greaterThan(20));
    });
    test('known currency resolves to its list', () {
      final ars = _forCurrency(data, 'ARS');
      expect(ars, contains('Mercado Pago'));
      expect(ars, contains('CVU'));
      expect(ars, isNot(contains('Zelle')));
    });
    test('African currencies present', () {
      expect(_forCurrency(data, 'MWK'), contains('Airtel Money'));
      expect(_forCurrency(data, 'KES'), contains('M-PESA'));
    });
    test('unknown currency falls back to default', () {
      final unknown = _forCurrency(data, 'XXX');
      expect(unknown, contains('Bank Transfer'));
      expect(unknown, contains('Cash in person'));
    });
  });
}

@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mostro/l10n/app_localizations.dart';
import 'package:mostro/shared/widgets/nym_avatar.dart';

/// The avatar draws the animal of a pseudonym, and four places have to agree
/// on which animal is which: the noun pool in Rust, the list in Dart, the
/// source SVGs and the glyphs of the NymAnimals font. Nothing in the build
/// ties them together, so an animal renamed in one place would silently draw
/// another animal, or the fallback icon.
void main() {
  group('the animal list', () {
    test('matches NOUNS in rust/src/crypto/nym.rs, in order', () {
      // Arrange
      final source = File('rust/src/crypto/nym.rs').readAsStringSync();
      final block =
          source.split('const NOUNS: [&str; 64] = [')[1].split('];').first;

      // Act
      final nouns =
          RegExp(r'"([a-z]+)"').allMatches(block).map((m) => m[1]!).toList();

      // Assert
      expect(kNymAnimals, nouns);
    });

    test('has one source SVG per animal and no other', () {
      final svgs =
          Directory('tool/nym_animals/svg')
              .listSync()
              .map((f) => f.uri.pathSegments.last)
              .where((name) => name.endsWith('.svg'))
              .map((name) => name.substring(0, name.length - 4))
              .toSet();

      expect(svgs, kNymAnimals.toSet());
    });

    test('the font holds one glyph per animal, after .notdef', () {
      final font = File('assets/fonts/nym_animals/NymAnimals.ttf');

      expect(_glyphCount(font.readAsBytesSync()), kNymAnimals.length + 1);
    });

    test('every glyph stays where its SVG drew it', () {
      // TrueType puts a glyph's origin at xMin - lsb. A left side bearing
      // other than xMin draws the animal shifted in its advance, so off
      // centre in the avatar (FreeType: Android, Linux and web).
      final font = File('assets/fonts/nym_animals/NymAnimals.ttf');

      expect(_misplacedGlyphs(font.readAsBytesSync()), isEmpty);
    });

    test('pubspec bundles the font and its licence', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();

      expect(pubspec, contains('- family: NymAnimals'));
      expect(
        pubspec,
        contains('- asset: assets/fonts/nym_animals/NymAnimals.ttf'),
      );
      expect(pubspec, contains('- assets/fonts/nym_animals/LICENSE.txt'));
    });
  });

  group('nymAnimalIcon', () {
    test('picks the glyph of the last word of the pseudonym', () {
      final icon = nymAnimalIcon('lazy-fox');

      expect(icon?.codePoint, 0xE000 + kNymAnimals.indexOf('fox'));
      expect(icon?.fontFamily, 'NymAnimals');
    });

    test('is null for a pseudonym that names no animal', () {
      expect(nymAnimalIcon('Trader 1a2b3c'), isNull);
      expect(nymAnimalIcon('lazy-urial'), isNull);
    });
  });

  group('NymAvatar', () {
    testWidgets('draws the animal of the pseudonym in white', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const NymAvatar(pseudonym: 'calm-panda', iconIndex: 3, colorHue: 120),
        ),
      );

      final icon = tester.widget<Icon>(find.byType(Icon));
      expect(icon.icon, nymAnimalIcon('calm-panda'));
      expect(icon.color, Colors.white);
    });

    testWidgets('falls back to the icon index without an animal', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          const NymAvatar(
            pseudonym: 'Trader 1a2b3c',
            iconIndex: 0,
            colorHue: 0,
          ),
        ),
      );

      expect(tester.widget<Icon>(find.byType(Icon)).icon, Icons.pets);
    });
  });
}

Widget _wrap(Widget child) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: Center(child: child)),
);

/// `numGlyphs` of the font's `maxp` table.
int _glyphCount(Uint8List bytes) =>
    ByteData.sublistView(bytes).getUint16(_tableOffset(bytes, 'maxp') + 4);

/// The outlined glyphs whose left side bearing (`hmtx`) is not their `xMin`
/// (`glyf`), by glyph index, as `(lsb, xMin)`.
Map<int, (int, int)> _misplacedGlyphs(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  final longLoca = data.getInt16(_tableOffset(bytes, 'head') + 50) == 1;
  final loca = _tableOffset(bytes, 'loca');
  final glyf = _tableOffset(bytes, 'glyf');
  final hmtx = _tableOffset(bytes, 'hmtx');
  final hMetrics = data.getUint16(_tableOffset(bytes, 'hhea') + 34);
  int glyphStart(int i) =>
      longLoca
          ? data.getUint32(loca + i * 4)
          : data.getUint16(loca + i * 2) * 2;
  int lsbOf(int i) =>
      i < hMetrics
          ? data.getInt16(hmtx + i * 4 + 2)
          : data.getInt16(hmtx + hMetrics * 4 + (i - hMetrics) * 2);
  final misplaced = <int, (int, int)>{};
  for (var i = 0; i < _glyphCount(bytes); i++) {
    if (glyphStart(i + 1) == glyphStart(i)) continue; // no outline
    final lsb = lsbOf(i);
    final xMin = data.getInt16(glyf + glyphStart(i) + 2);
    if (lsb != xMin) misplaced[i] = (lsb, xMin);
  }
  return misplaced;
}

/// Offset of the table [tag] in the font [bytes].
int _tableOffset(Uint8List bytes, String tag) {
  final data = ByteData.sublistView(bytes);
  final tables = data.getUint16(4);
  for (var i = 0; i < tables; i++) {
    final record = 12 + i * 16;
    if (String.fromCharCodes(bytes.sublist(record, record + 4)) == tag) {
      return data.getUint32(record + 8);
    }
  }
  throw StateError('no $tag table');
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mostro/core/app_theme.dart';
import 'package:mostro/features/chat/widgets/message_bubble.dart';
import 'package:mostro/l10n/app_localizations.dart';

const _text = 'CBU 0000003100010000000001';

/// The long-press menu of a P2P chat message: held for a second, a text
/// message offers Copy.
void main() {
  ChatMessage textMessage({bool isMine = false}) => ChatMessage(
    id: 'm1',
    tradeId: 'order-chat',
    content: _text,
    isMine: isMine,
    isRead: true,
    hasAttachment: false,
    createdAt: 1000,
  );

  Future<void> pump(
    WidgetTester tester,
    ChatMessage message, {
    Locale locale = const Locale('en'),
    bool atBottom = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme(),
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          // A chat lists its newest message at the bottom.
          body: atBottom
              ? ListView(
                  reverse: true,
                  children: [
                    MessageBubble(message: message, peerColorHue: 200),
                  ],
                )
              : Center(
                  child: MessageBubble(message: message, peerColorHue: 200),
                ),
        ),
      ),
    );
  }

  /// Presses the message's text for [hold], then lifts the finger.
  Future<void> press(WidgetTester tester, Duration hold) async {
    final gesture = await tester.startGesture(
      tester.getCenter(find.text(_text).first),
    );
    await tester.pump(hold);
    await gesture.up();
    await tester.pumpAndSettle();
  }

  testWidgets('holding a counterpart message for a second opens the menu', (
    tester,
  ) async {
    await pump(tester, textMessage());

    await press(tester, const Duration(seconds: 1));

    expect(find.text('Copy'), findsOneWidget);
  });

  testWidgets('a shorter press opens nothing', (tester) async {
    await pump(tester, textMessage());

    await press(tester, const Duration(milliseconds: 600));

    expect(find.text('Copy'), findsNothing);
    expect(find.text('Copied'), findsNothing);
  });

  testWidgets('a press just under a second opens nothing', (tester) async {
    await pump(tester, textMessage());

    await press(tester, const Duration(milliseconds: 999));

    expect(find.text('Copy'), findsNothing);
  });

  testWidgets('a message at the bottom gets the menu above it, on screen', (
    tester,
  ) async {
    await pump(tester, textMessage(), atBottom: true);
    final bubble = tester.getRect(find.text(_text).first);

    await press(tester, const Duration(seconds: 1));
    final menu = tester.getRect(
      find
          .ancestor(of: find.text('Copy'), matching: find.byType(Material))
          .first,
    );

    expect(menu.bottom, lessThanOrEqualTo(bubble.top));
    expect(menu.top, greaterThanOrEqualTo(0));
    expect(menu.left, greaterThanOrEqualTo(0));
  });

  testWidgets('a change of screen size closes the menu', (tester) async {
    addTearDown(tester.view.reset);
    await pump(tester, textMessage());

    await press(tester, const Duration(seconds: 1));
    expect(find.text('Copy'), findsOneWidget);
    tester.view.physicalSize = tester.view.physicalSize.flipped;
    await tester.pumpAndSettle();

    expect(find.text('Copy'), findsNothing);
  });

  testWidgets('own messages open the same menu', (tester) async {
    await pump(tester, textMessage(isMine: true));

    await press(tester, const Duration(seconds: 1));

    expect(find.text('Copy'), findsOneWidget);
  });

  group('clipboard', () {
    late List<String?> copied;

    setUp(() => copied = []);

    void spyOnClipboard(WidgetTester tester) {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String?);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
    }

    testWidgets('Copy puts the text on the clipboard, closes and confirms', (
      tester,
    ) async {
      spyOnClipboard(tester);
      await pump(tester, textMessage());

      await press(tester, const Duration(seconds: 1));
      await tester.tap(find.text('Copy'));
      await tester.pumpAndSettle();

      expect(copied, [_text]);
      expect(find.text('Copy'), findsNothing);
      expect(find.text('Copied'), findsOneWidget);
    });

    testWidgets('tapping outside the menu closes it without copying', (
      tester,
    ) async {
      spyOnClipboard(tester);
      await pump(tester, textMessage());

      await press(tester, const Duration(seconds: 1));
      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();

      expect(find.text('Copy'), findsNothing);
      expect(find.text('Copied'), findsNothing);
      expect(copied, isEmpty);
    });
  });

  testWidgets('the open menu fits 320 dp at 2x text in German', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await pump(tester, textMessage(), locale: const Locale('de'));

    await press(tester, const Duration(seconds: 1));

    expect(find.text('Kopieren'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

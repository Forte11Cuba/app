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
    bool inLongList = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme(),
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          // A chat lists its newest message at the bottom.
          body: switch ((atBottom, inLongList)) {
            (true, _) => ListView(
                reverse: true,
                children: [
                  MessageBubble(message: message, peerColorHue: 200),
                ],
              ),
            // 300 dp down a list that scrolls far past it.
            (_, true) => ListView.builder(
                itemCount: 40,
                itemBuilder: (_, i) => i == 1
                    ? MessageBubble(message: message, peerColorHue: 200)
                    : const SizedBox(height: 300),
              ),
            _ => Center(
                child: MessageBubble(message: message, peerColorHue: 200),
              ),
          },
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

  ScrollPosition listPosition(WidgetTester tester) =>
      tester.state<ScrollableState>(find.byType(Scrollable)).position;

  testWidgets('the menu follows its message when the chat scrolls', (
    tester,
  ) async {
    await pump(tester, textMessage(), inLongList: true);
    await press(tester, const Duration(seconds: 1));
    final before = tester.getRect(find.text('Copy'));

    // As a new message arriving at the bottom would.
    listPosition(tester).jumpTo(100);
    await tester.pump();
    await tester.pump();

    expect(tester.getRect(find.text('Copy')).top, before.top - 100);
    // The lit copy of the message stays on the message.
    expect(
      tester.getRect(find.text(_text).last),
      tester.getRect(find.text(_text).first),
    );
  });

  testWidgets('the menu closes once its message is gone', (tester) async {
    await pump(tester, textMessage(), inLongList: true);
    await press(tester, const Duration(seconds: 1));

    listPosition(tester).jumpTo(5000);
    await tester.pumpAndSettle();

    expect(find.text('Copy'), findsNothing);
  });

  testWidgets('the menu closes once its message scrolls out of sight', (
    tester,
  ) async {
    await pump(tester, textMessage(), inLongList: true);
    await press(tester, const Duration(seconds: 1));
    final bubble = tester.getRect(find.text(_text).first);

    // Just above the top: out of sight, still built in the list's cache.
    listPosition(tester).jumpTo(bubble.bottom + 50);
    await tester.pump();
    expect(find.text(_text, skipOffstage: false), findsWidgets);
    await tester.pumpAndSettle();

    expect(find.text('Copy'), findsNothing);
  });

  testWidgets('a message partly scrolled away stays cut at the list', (
    tester,
  ) async {
    await pump(tester, textMessage(), inLongList: true);
    await press(tester, const Duration(seconds: 1));
    final bubble = tester.getRect(find.text(_text).first);

    // Half of it above the list's top edge.
    listPosition(tester).jumpTo(bubble.top + bubble.height / 2);
    await tester.pump();
    await tester.pump();

    expect(find.text('Copy'), findsOneWidget);
    final lit = find.text(_text).last;
    expect(tester.getRect(lit).top, lessThan(0));
    final cut = find.ancestor(of: lit, matching: find.byType(ClipRect)).first;
    expect(tester.getRect(cut).top, 0);
  });

  testWidgets('the menu stays clear of an open keyboard', (tester) async {
    addTearDown(tester.view.reset);
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await pump(tester, textMessage(), atBottom: true);

    await press(tester, const Duration(seconds: 1));

    expect(
      tester.getRect(find.text('Copy')).bottom,
      lessThanOrEqualTo(800 - 300),
    );
  });

  testWidgets('a change of screen size keeps the menu on its message', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    await pump(tester, textMessage());

    await press(tester, const Duration(seconds: 1));
    tester.view.physicalSize = tester.view.physicalSize.flipped;
    await tester.pumpAndSettle();

    expect(find.text('Copy'), findsOneWidget);
    expect(
      tester.getRect(find.text(_text).last),
      tester.getRect(find.text(_text).first),
    );
  });

  testWidgets('the menu keeps clear of a cutout on the side', (tester) async {
    addTearDown(tester.view.reset);
    tester.view.padding = const FakeViewPadding(left: 120);
    await pump(tester, textMessage());

    await press(tester, const Duration(seconds: 1));

    final cutout = 120 / tester.view.devicePixelRatio;
    expect(
      tester.getRect(find.text('Copy')).left,
      greaterThanOrEqualTo(cutout + 16),
    );
  });

  testWidgets('a screen reader learns what holding a message opens', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await pump(tester, textMessage());

    expect(
      tester.getSemantics(find.text(_text)),
      isSemantics(
        isButton: true,
        hasLongPressAction: true,
        onLongPressHint: 'Open the message menu',
      ),
    );
    semantics.dispose();
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

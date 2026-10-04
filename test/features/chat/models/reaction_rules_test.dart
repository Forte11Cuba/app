import 'package:flutter_test/flutter_test.dart';

import 'package:mostro/features/chat/models/reaction_rules.dart';
import 'package:mostro/shared/utils/platform_int64.dart';
import 'package:mostro/src/rust/api/types.dart' as rust_types;

rust_types.ChatReaction _reaction(String emoji, int at) =>
    rust_types.ChatReaction(
      senderPubkey: 'peer',
      emoji: emoji,
      createdAt: intToPlatformInt64(at),
      eventId: 'e$at',
    );

rust_types.ChatMessage _message(List<rust_types.ChatReaction> reactions) =>
    rust_types.ChatMessage(
      id: 'm',
      tradeId: 't',
      senderPubkey: 'me',
      content: 'hi',
      messageType: rust_types.MessageType.peer,
      isMine: true,
      isRead: true,
      hasAttachment: false,
      createdAt: intToPlatformInt64(1),
      reactions: reactions,
    );

void main() {
  group('shownReaction', () {
    test('shows the reaction a message carries', () {
      expect(shownReaction(_message([_reaction('👍', 5)])), '👍');
    });

    test('shows nothing for no reaction or a withdrawn one', () {
      expect(shownReaction(_message([])), isNull);
      expect(shownReaction(_message([_reaction('', 5)])), isNull);
    });
  });

  group('reactionsNotOlder', () {
    test('lets a newer or equal copy replace the one shown', () {
      final shown = _message([_reaction('👍', 5)]);

      expect(reactionsNotOlder(_message([_reaction('😂', 6)]), shown), isTrue);
      expect(reactionsNotOlder(_message([_reaction('👍', 5)]), shown), isTrue);
    });

    test('keeps a later reaction from an older reply', () {
      final shown = _message([_reaction('😂', 6)]);

      expect(reactionsNotOlder(_message([_reaction('👍', 5)]), shown), isFalse);
      expect(reactionsNotOlder(_message([]), shown), isFalse);
    });

    test('counts a withdrawal as the newest state', () {
      final shown = _message([_reaction('👍', 5)]);

      expect(reactionsNotOlder(_message([_reaction('', 6)]), shown), isTrue);
    });
  });

  group('sameReaction', () {
    test('matches with or without the presentation selector', () {
      expect(sameReaction('❤', '❤️'), isTrue);
      expect(sameReaction('❤️', '❤️'), isTrue);
    });

    test('does not match another emoji or none', () {
      expect(sameReaction('👍', '👎'), isFalse);
      expect(sameReaction('👍', null), isFalse);
    });
  });
}

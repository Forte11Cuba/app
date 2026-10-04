import 'package:mostro/src/rust/api/types.dart' as rust_types;

/// The reaction [msg] shows, or null. The core keeps one per party, an empty
/// one standing for a withdrawn reaction, and only the party who did not
/// write a message can react to it — so there is at most one to show: the
/// user's on the counterpart's message, the counterpart's on the user's.
String? shownReaction(rust_types.ChatMessage msg) {
  for (final reaction in msg.reactions) {
    if (reaction.emoji.isNotEmpty) return reaction.emoji;
  }
  return null;
}

/// Whether [next] may replace [current], two copies of one message: not
/// when its reactions are older. A reply to an earlier send can land after
/// the update of a later one, and must not bring the earlier reaction back.
bool reactionsNotOlder(
  rust_types.ChatMessage next,
  rust_types.ChatMessage current,
) => _newest(next) >= _newest(current);

int _newest(rust_types.ChatMessage msg) {
  var newest = 0;
  for (final reaction in msg.reactions) {
    final at = reaction.createdAt.toInt();
    if (at > newest) newest = at;
  }
  return newest;
}

/// Whether two emojis are the same reaction. A picker may hand over ❤ where
/// the menu offered ❤️: they differ only by the emoji presentation selector.
bool sameReaction(String a, String? b) => b != null && _bare(a) == _bare(b);

String _bare(String emoji) => emoji.replaceAll('\u{FE0F}', '');

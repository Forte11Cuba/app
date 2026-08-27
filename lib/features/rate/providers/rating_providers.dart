import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mostro/src/rust/api/reputation.dart' as reputation_api;
import 'package:mostro/src/rust/api/types.dart';

/// The rating the local user submitted for [tradeId], or `null` when they
/// have not rated that trade yet.
///
/// `getRatingForTrade` falls back to the counterpart's rating when the local
/// user has not submitted one, so `isMine` is what separates "I rated them"
/// from "they rated me" — only the former resolves the rate prompt.
///
/// The Rust store is in-memory by design (ratings live in the daemon's kind
/// 38383 tags, not in the local DB), so this resolves to `null` again after a
/// restart and the prompt comes back.
final myTradeRatingProvider = FutureProvider.autoDispose
    .family<RatingInfo?, String>((ref, tradeId) async {
  final rating = await reputation_api.getRatingForTrade(tradeId: tradeId);
  return rating != null && rating.isMine ? rating : null;
});

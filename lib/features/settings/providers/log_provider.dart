import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mostro/src/rust/api/logging.dart' as logging_api;
import 'package:mostro/src/rust/api/types.dart';

/// Entries held in the provider, matching the Rust ring buffer's own bound.
const _maxEntries = 500;

/// Log entries from the Rust backend, newest first.
///
/// Seeded from the Rust ring buffer so the screen opens on the history that led
/// to whatever the user is reporting, then followed live. Cancelled when the
/// provider is disposed (e.g. when LogReportScreen is popped).
final logEntriesProvider =
    StreamProvider.autoDispose<List<LogEntry>>((ref) async* {
  var cancelled = false;
  ref.onDispose(() => cancelled = true);

  // Subscribe before snapshotting: an entry emitted between the two calls
  // arrives on the stream and is dropped below, whereas the reverse order
  // would lose it entirely.
  final stream = await logging_api.onLogEntry();
  final entries = (await logging_api.recentLogs()).take(_maxEntries).toList();
  final seededUpTo = entries.isEmpty ? -1 : entries.first.id;
  yield List.unmodifiable(entries);

  while (!cancelled) {
    final entry = await stream.next();
    if (entry == null || cancelled) break;
    if (entry.id <= seededUpTo) continue; // already in the seed
    entries.insert(0, entry);
    if (entries.length > _maxEntries) entries.removeLast();
    yield List.unmodifiable(entries);
  }
});

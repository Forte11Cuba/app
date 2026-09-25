import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mostro/l10n/app_localizations.dart';
import 'package:mostro/src/rust/api/messages.dart' as messages_api;

/// Saves a decrypted attachment where the user chooses.
///
/// This is the one path that writes plaintext to disk, and only through the
/// system save dialog: the user picks the place and the name. The name
/// offered is the one Rust sanitized (no path, no control characters).
class AttachmentSaver {
  const AttachmentSaver();

  /// Resolves to false when the user closed the dialog.
  Future<bool> save({
    required String fileName,
    required Uint8List bytes,
  }) async {
    final path = await FilePicker.platform.saveFile(
      fileName: fileName,
      bytes: bytes,
    );
    if (path == null) return false;
    // Android, iOS and the web write `bytes` themselves; on desktop the
    // dialog only names the file.
    if (!kIsWeb && !Platform.isAndroid && !Platform.isIOS) {
      await File(path).writeAsBytes(bytes, flush: true);
    }
    return true;
  }
}

final attachmentSaverProvider = Provider<AttachmentSaver>(
  (ref) => const AttachmentSaver(),
);

/// Opens the save dialog for [data] and says how it went. A closed dialog
/// says nothing.
Future<void> saveAttachmentWithFeedback(
  BuildContext context,
  WidgetRef ref,
  messages_api.AttachmentData data,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final l10n = AppLocalizations.of(context);
  try {
    final saved = await ref
        .read(attachmentSaverProvider)
        .save(fileName: data.fileName, bytes: data.bytes);
    if (saved) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.attachmentSaved)));
    }
  } catch (e) {
    debugPrint('[chat] save attachment failed: $e');
    messenger.showSnackBar(SnackBar(content: Text(l10n.attachmentSaveFailed)));
  }
}

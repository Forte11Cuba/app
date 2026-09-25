import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';

import 'package:mostro/l10n/app_localizations.dart';
import 'package:mostro/src/rust/api/messages.dart' as messages_api;

/// What may be handed to another app, by MIME type, with the extension its
/// temporary copy gets: the types v1 sends (`FileValidationService`).
///
/// The MIME comes from Rust — sniffed for JPEG, PNG and PDF, declared by the
/// sender for the rest. Anything else can still be saved, but is never
/// opened for the user: an `.apk` dressed as a document must not reach the
/// package installer in one tap.
const Map<String, String> kOpenableTypes = {
  'image/jpeg': 'jpg',
  'image/png': 'png',
  'application/pdf': 'pdf',
  'application/msword': 'doc',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document':
      'docx',
  'video/mp4': 'mp4',
  'video/quicktime': 'mov',
  'video/x-msvideo': 'avi',
};

/// Where the temporary copies live, under the app's own cache directory.
const String kAttachmentTempDir = 'chat_attachments_open';

const int _maxStemLength = 60;

/// The name a temporary copy of [fileName] gets: letters, digits, space,
/// `.`, `_` and `-` only, and the extension of its MIME type, never the one
/// the sender chose.
///
/// Rust already strips paths and control characters; this is stricter
/// because the name reaches a shell on Windows (`open_filex` runs
/// `cmd /c start`), where `&` or `|` in a peer's file name would run a
/// command.
String safeTempFileName(String fileName, String extension) {
  final stem =
      p
          .basenameWithoutExtension(fileName)
          .replaceAll(RegExp(r'[^A-Za-z0-9 ._-]'), '_')
          .replaceAll(RegExp(r'^[ ._-]+'), '')
          .trim();
  final capped =
      stem.length > _maxStemLength ? stem.substring(0, _maxStemLength) : stem;
  return '${capped.isEmpty ? 'attachment' : capped}.$extension';
}

/// How handing a file to another app went.
enum LaunchOutcome { done, noApp, failed }

/// Hands a decrypted attachment to another app: "open with…" or the share
/// sheet (#589 phase 2b).
///
/// Both need the plaintext on disk, which the chat otherwise never writes.
/// So each copy goes to its own directory under the app's cache, named by
/// [safeTempFileName], and [sweep] deletes them all: when the user comes
/// back to the app (the other app has read it by then), at start-up, and on
/// an identity change.
class AttachmentLauncher {
  AttachmentLauncher({Future<Directory> Function()? tempRoot})
    : _tempRoot = tempRoot ?? getTemporaryDirectory;

  final Future<Directory> Function() _tempRoot;

  /// Whether [data] may be opened or shared: a known type, on a platform
  /// with a file system.
  bool canHandOff(messages_api.AttachmentData data) =>
      canHandOffType(data.mimeType);

  /// [canHandOff] by MIME alone, to decide what to offer before the file
  /// is downloaded.
  bool canHandOffType(String mimeType) =>
      !kIsWeb && kOpenableTypes.containsKey(mimeType);

  /// Whether this platform's share sheet takes files. Linux's does not.
  bool get supportsShare => !kIsWeb && !Platform.isLinux;

  Future<LaunchOutcome> openWith(messages_api.AttachmentData data) async {
    final path = await writeTempCopy(data);
    final result = await OpenFilex.open(path, type: data.mimeType);
    return switch (result.type) {
      ResultType.done => LaunchOutcome.done,
      ResultType.noAppToOpen => LaunchOutcome.noApp,
      _ => LaunchOutcome.failed,
    };
  }

  /// [origin] anchors the share popover on iPad and macOS.
  Future<void> share(messages_api.AttachmentData data, {Rect? origin}) async {
    final path = await writeTempCopy(data);
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(path, mimeType: data.mimeType)],
        sharePositionOrigin: origin,
      ),
    );
  }

  /// Writes [data] where another app can read it and returns the path.
  @visibleForTesting
  Future<String> writeTempCopy(messages_api.AttachmentData data) async {
    final extension = kOpenableTypes[data.mimeType];
    if (extension == null) {
      throw StateError('not an openable type: ${data.mimeType}');
    }
    // A directory per copy, so two files with the same name never collide.
    final dir = Directory(
      p.join((await _tempRoot()).path, kAttachmentTempDir, const Uuid().v4()),
    );
    await dir.create(recursive: true);
    final file = File(
      p.join(dir.path, safeTempFileName(data.fileName, extension)),
    );
    await file.writeAsBytes(data.bytes, flush: true);
    return file.path;
  }

  /// Deletes every temporary copy. Never throws: a copy that cannot be
  /// deleted now is retried at the next sweep.
  Future<void> sweep() async {
    if (kIsWeb) return;
    try {
      final dir = Directory(
        p.join((await _tempRoot()).path, kAttachmentTempDir),
      );
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (e) {
      debugPrint('[chat] attachment temp sweep failed: $e');
    }
  }
}

final attachmentLauncherProvider = Provider<AttachmentLauncher>(
  (ref) => AttachmentLauncher(),
);

/// "Open with…" for [data], saying so when no app takes it.
Future<void> openAttachmentWithFeedback(
  BuildContext context,
  WidgetRef ref,
  messages_api.AttachmentData data,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final l10n = AppLocalizations.of(context);
  LaunchOutcome outcome;
  try {
    outcome = await ref.read(attachmentLauncherProvider).openWith(data);
  } catch (e) {
    debugPrint('[chat] open attachment failed: $e');
    outcome = LaunchOutcome.failed;
  }
  final message = switch (outcome) {
    LaunchOutcome.done => null,
    LaunchOutcome.noApp => l10n.attachmentNoAppToOpen,
    LaunchOutcome.failed => l10n.attachmentOpenFailed,
  };
  if (message != null) {
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }
}

/// The share sheet for [data], anchored on the widget of [context].
Future<void> shareAttachmentWithFeedback(
  BuildContext context,
  WidgetRef ref,
  messages_api.AttachmentData data,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final l10n = AppLocalizations.of(context);
  final box = context.findRenderObject() as RenderBox?;
  final origin =
      box == null || !box.hasSize
          ? null
          : box.localToGlobal(Offset.zero) & box.size;
  try {
    await ref.read(attachmentLauncherProvider).share(data, origin: origin);
  } catch (e) {
    debugPrint('[chat] share attachment failed: $e');
    messenger.showSnackBar(SnackBar(content: Text(l10n.attachmentShareFailed)));
  }
}

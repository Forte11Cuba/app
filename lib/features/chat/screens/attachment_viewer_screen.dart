import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mostro/features/chat/attachments/attachment_errors.dart';
import 'package:mostro/features/chat/attachments/attachment_providers.dart';
import 'package:mostro/features/chat/attachments/attachment_saver.dart';
import 'package:mostro/l10n/app_localizations.dart';

/// A chat image, full screen, with pinch-zoom and Save.
///
/// Reads the decrypted bytes from memory — the bubble that opened it already
/// decrypted them — and writes them nowhere unless the user saves.
class AttachmentViewerScreen extends ConsumerWidget {
  const AttachmentViewerScreen({
    super.key,
    required this.messageId,
    required this.fileName,
  });

  final String messageId;
  final String fileName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final data = ref.watch(attachmentDataProvider(messageId));
    final file = data.valueOrNull;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(fileName, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: l10n.attachmentSave,
            icon: const Icon(Icons.download_outlined),
            onPressed:
                file == null
                    ? null
                    : () => saveAttachmentWithFeedback(context, ref, file),
          ),
        ],
      ),
      body: data.when(
        loading:
            () => const Center(
              child: CircularProgressIndicator(color: Colors.white70),
            ),
        error:
            (error, _) => Center(
              child: Text(
                attachmentErrorMessage(l10n, error),
                style: const TextStyle(color: Colors.white70),
              ),
            ),
        data:
            (file) => InteractiveViewer(
              maxScale: 6,
              child: Center(
                child: Image.memory(
                  file.bytes,
                  fit: BoxFit.contain,
                  semanticLabel: l10n.attachmentImageSemantics(fileName),
                  errorBuilder:
                      (_, _, _) => Text(
                        l10n.attachmentInvalidImage,
                        style: const TextStyle(color: Colors.white70),
                      ),
                ),
              ),
            ),
      ),
    );
  }
}

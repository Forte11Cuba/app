import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mostro/core/app_theme.dart';
import 'package:mostro/features/chat/attachments/attachment_errors.dart';
import 'package:mostro/features/chat/attachments/attachment_gateway.dart';
import 'package:mostro/features/chat/attachments/attachment_providers.dart';
import 'package:mostro/features/chat/attachments/attachment_saver.dart';
import 'package:mostro/l10n/app_localizations.dart';
import 'package:mostro/src/rust/api/types.dart' as rust_types;

/// An encrypted file that is not an image — a PDF, or a DOC/DOCX/video sent
/// from v1 — drawn inside its chat bubble.
///
/// Nothing is downloaded until the user asks: Save fetches, checks and
/// decrypts it in memory, then hands it to the system save dialog.
class EncryptedFileMessage extends ConsumerStatefulWidget {
  const EncryptedFileMessage({
    super.key,
    required this.messageId,
    required this.attachment,
  });

  final String messageId;
  final rust_types.AttachmentInfo attachment;

  @override
  ConsumerState<EncryptedFileMessage> createState() =>
      _EncryptedFileMessageState();
}

class _EncryptedFileMessageState extends ConsumerState<EncryptedFileMessage> {
  bool _busy = false;

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final data = await loadAttachment(
        cache: ref.read(decryptedAttachmentCacheProvider),
        gateway: ref.read(attachmentGatewayProvider),
        messageId: widget.messageId,
      );
      if (!mounted) return;
      await saveAttachmentWithFeedback(context, ref, data);
    } catch (e) {
      debugPrint('[chat] download attachment failed: $e');
      messenger.showSnackBar(
        SnackBar(content: Text(attachmentErrorMessage(l10n, e))),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    final attachment = widget.attachment;
    final details =
        '${formatAttachmentSize(attachment.fileSize.toInt())} · '
        '${fileTypeLabel(attachment.mimeType, l10n)}';

    return Semantics(
      label: '${attachment.fileName}, $details',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            fileTypeIcon(attachment.mimeType),
            color: Colors.white,
            size: 32,
          ),
          const SizedBox(width: AppSpacing.sm),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  attachment.fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.bodyMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                ExcludeSemantics(
                  child: Text(
                    details,
                    style: textTheme.bodySmall?.copyWith(color: Colors.white70),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.xs),
          SizedBox.square(
            dimension: 40,
            child:
                _busy
                    ? const Padding(
                      padding: EdgeInsets.all(10),
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white70,
                      ),
                    )
                    : IconButton(
                      tooltip: l10n.attachmentSave,
                      icon: const Icon(
                        Icons.download_outlined,
                        color: Colors.white,
                      ),
                      onPressed: _save,
                    ),
          ),
        ],
      ),
    );
  }
}

/// The icon for a file of [mime] type, as the sender declared it.
IconData fileTypeIcon(String mime) {
  if (mime.contains('pdf')) return Icons.picture_as_pdf_outlined;
  if (mime.startsWith('video/')) return Icons.video_file_outlined;
  if (mime.startsWith('image/')) return Icons.image_outlined;
  return Icons.description_outlined;
}

/// The short type label shown next to the size.
String fileTypeLabel(String mime, AppLocalizations l10n) {
  if (mime.contains('pdf')) return 'PDF';
  if (mime.startsWith('video/')) return l10n.fileTypeVideo;
  if (mime.startsWith('image/')) return l10n.fileTypeImage;
  if (mime.contains('zip') || mime.contains('tar')) return l10n.fileTypeArchive;
  return l10n.fileTypeFile;
}

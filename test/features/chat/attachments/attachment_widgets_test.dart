import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mostro/core/app_theme.dart';
import 'package:mostro/features/chat/attachments/attachment_gateway.dart';
import 'package:mostro/features/chat/attachments/attachment_saver.dart';
import 'package:mostro/features/chat/attachments/upload_controller.dart';
import 'package:mostro/features/chat/screens/attachment_viewer_screen.dart';
import 'package:mostro/features/chat/widgets/encrypted_file_message.dart';
import 'package:mostro/features/chat/widgets/encrypted_image_message.dart';
import 'package:mostro/features/chat/widgets/message_bubble.dart';
import 'package:mostro/features/chat/widgets/upload_bubble.dart';
import 'package:mostro/l10n/app_localizations.dart';
import 'package:mostro/src/rust/api/messages.dart' as messages_api;

import '../../../support/attachment_fixtures.dart';
import '../../../support/provider_harness.dart';

/// A real PNG, so `Image.memory` decodes rather than failing.
Future<Uint8List> _png(WidgetTester tester) async {
  return (await tester.runAsync(() async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawRect(
      const Rect.fromLTWH(0, 0, 8, 6),
      Paint()..color = const Color(0xFF3A7BD5),
    );
    final image = await recorder.endRecording().toImage(8, 6);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  }))!;
}

/// Lets `Image.memory` finish decoding, which happens outside fake time.
Future<void> _decodeImages(WidgetTester tester) async {
  await tester.runAsync(() async {
    for (final element in find.byType(Image).evaluate()) {
      final image = element.widget as Image;
      await precacheImage(image.image, element);
    }
  });
  await tester.pump();
}

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  required FakeAttachmentGateway gateway,
  FakeAttachmentSaver? saver,
}) async {
  final container = createContainer(
    overrides: [
      attachmentGatewayProvider.overrideWithValue(gateway),
      if (saver != null) attachmentSaverProvider.overrideWithValue(saver),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildDarkTheme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: Center(child: child)),
      ),
    ),
  );
}

void main() {
  group('EncryptedImageMessage', () {
    testWidgets('downloads on arrival and shows a spinner meanwhile', (
      tester,
    ) async {
      final pending = Completer<messages_api.AttachmentData>();
      final gateway = FakeAttachmentGateway(
        downloadResult: (_) => pending.future,
      );

      await _pump(
        tester,
        EncryptedImageMessage(messageId: 'm1', attachment: imageInfo()),
        gateway: gateway,
      );
      await tester.pump();

      expect(gateway.downloads, ['m1']);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      pending.completeError(Exception('DownloadFailed: late'));
      await tester.pump();
    });

    testWidgets('keeps the sender\'s shape before the image decrypts', (
      tester,
    ) async {
      final gateway = FakeAttachmentGateway(
        downloadResult: (_) => Completer<messages_api.AttachmentData>().future,
      );

      await _pump(
        tester,
        EncryptedImageMessage(
          messageId: 'm1',
          attachment: imageInfo(width: 1000, height: 2000),
        ),
        gateway: gateway,
      );

      final size = tester.getSize(find.byType(AspectRatio));
      expect(size.width, kImageBubbleMaxWidth);
      expect(size.height, kImageBubbleMaxWidth * 2);
    });

    testWidgets('shows the image and opens it full screen', (tester) async {
      final png = await _png(tester);
      final gateway = FakeAttachmentGateway(
        downloadResult: (_) async => attachmentData(png, mimeType: 'image/png'),
      );

      await _pump(
        tester,
        EncryptedImageMessage(messageId: 'm1', attachment: imageInfo()),
        gateway: gateway,
      );
      await tester.pump();
      await _decodeImages(tester);

      expect(find.byType(Image), findsOneWidget);
      expect(find.bySemanticsLabel('Image: receipt.jpg'), findsOneWidget);

      await tester.tap(find.byType(Image));
      await tester.pumpAndSettle();

      expect(find.byType(AttachmentViewerScreen), findsOneWidget);
      expect(find.byType(InteractiveViewer), findsOneWidget);
      // Served from memory: the viewer does not decrypt it again.
      expect(gateway.downloads, ['m1']);
    });

    testWidgets('a failed download offers a retry that downloads again', (
      tester,
    ) async {
      var calls = 0;
      final png = await _png(tester);
      final gateway = FakeAttachmentGateway(
        downloadResult: (_) async {
          if (calls++ == 0) throw Exception('DownloadFailed: 503');
          return attachmentData(png);
        },
      );

      await _pump(
        tester,
        EncryptedImageMessage(messageId: 'm1', attachment: imageInfo()),
        gateway: gateway,
      );
      await tester.pump();

      expect(find.text('The file could not be downloaded.'), findsOneWidget);
      await tester.tap(find.text('Retry'));
      await tester.pump();
      await tester.pump();
      await _decodeImages(tester);

      expect(gateway.downloads, ['m1', 'm1']);
      expect(find.byType(Image), findsOneWidget);
    });

    testWidgets('a file that does not decrypt offers no retry', (tester) async {
      final gateway = FakeAttachmentGateway(
        downloadResult: (_) async => throw Exception('DecryptionFailed: tag'),
      );

      await _pump(
        tester,
        EncryptedImageMessage(messageId: 'm1', attachment: imageInfo()),
        gateway: gateway,
      );
      await tester.pump();

      expect(find.text('This file could not be decrypted.'), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
    });
  });

  group('EncryptedFileMessage', () {
    testWidgets('shows name, size and type, and downloads nothing', (
      tester,
    ) async {
      final gateway = FakeAttachmentGateway();

      await _pump(
        tester,
        EncryptedFileMessage(messageId: 'm2', attachment: pdfInfo()),
        gateway: gateway,
      );

      expect(find.text('transfer.pdf'), findsOneWidget);
      expect(find.text('1.4 MB · PDF'), findsOneWidget);
      expect(gateway.downloads, isEmpty);
    });

    testWidgets('Save downloads, decrypts and hands it to the dialog', (
      tester,
    ) async {
      final gateway = FakeAttachmentGateway(
        downloadResult:
            (_) async => attachmentData(
              [37, 80, 68, 70],
              fileName: 'transfer.pdf',
              mimeType: 'application/pdf',
            ),
      );
      final saver = FakeAttachmentSaver();

      await _pump(
        tester,
        EncryptedFileMessage(messageId: 'm2', attachment: pdfInfo()),
        gateway: gateway,
        saver: saver,
      );
      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();

      expect(gateway.downloads, ['m2']);
      expect(saver.saved, ['transfer.pdf']);
      expect(find.text('File saved'), findsOneWidget);
    });

    testWidgets('a closed save dialog says nothing', (tester) async {
      final gateway = FakeAttachmentGateway(
        downloadResult: (_) async => attachmentData([1]),
      );

      await _pump(
        tester,
        EncryptedFileMessage(messageId: 'm2', attachment: pdfInfo()),
        gateway: gateway,
        saver: FakeAttachmentSaver(result: false),
      );
      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();

      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('a failed download is reported, not saved', (tester) async {
      final gateway = FakeAttachmentGateway(
        downloadResult: (_) async => throw Exception('DownloadFailed: 404'),
      );
      final saver = FakeAttachmentSaver();

      await _pump(
        tester,
        EncryptedFileMessage(messageId: 'm2', attachment: pdfInfo()),
        gateway: gateway,
        saver: saver,
      );
      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();

      expect(saver.saved, isEmpty);
      expect(find.text('The file could not be downloaded.'), findsOneWidget);
    });
  });

  group('UploadBubble', () {
    PendingUpload upload({
      UploadStatus status = UploadStatus.uploading,
      Object? error,
    }) => PendingUpload(
      id: 'u1',
      fileName: 'receipt.png',
      bytes: Uint8List(2048),
      progress: 0.3,
      status: status,
      error: error,
    );

    testWidgets('shows progress while uploading, and no actions', (
      tester,
    ) async {
      await _pump(
        tester,
        UploadBubble(upload: upload(), onRetry: () {}, onDiscard: () {}),
        gateway: FakeAttachmentGateway(),
      );

      final bar = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(bar.value, 0.3);
      expect(find.text('Sending… 2 KB'), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
      expect(find.text('Discard'), findsNothing);
    });

    testWidgets('a failed upload says why and offers retry and discard', (
      tester,
    ) async {
      var retried = 0;
      var discarded = 0;
      await _pump(
        tester,
        UploadBubble(
          upload: upload(
            status: UploadStatus.failed,
            error: Exception('UploadFailed: none'),
          ),
          onRetry: () => retried++,
          onDiscard: () => discarded++,
        ),
        gateway: FakeAttachmentGateway(),
      );

      expect(
        find.text('The upload failed. Check your connection and try again.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Retry'));
      await tester.tap(find.text('Discard'));
      expect((retried, discarded), (1, 1));
    });

    testWidgets('a file Rust refused offers only discard', (tester) async {
      await _pump(
        tester,
        UploadBubble(
          upload: upload(
            status: UploadStatus.failed,
            error: Exception('UnsupportedFileType: image/heic'),
          ),
          onRetry: () {},
          onDiscard: () {},
        ),
        gateway: FakeAttachmentGateway(),
      );

      expect(
        find.text('Only JPEG, PNG and PDF files can be sent.'),
        findsOneWidget,
      );
      expect(find.text('Retry'), findsNothing);
      expect(find.text('Discard'), findsOneWidget);
    });
  });

  group('MessageBubble', () {
    ChatMessage bubbleMessage(dynamic attachment) => ChatMessage(
      id: 'm3',
      tradeId: 'order-chat',
      content: 'transfer.pdf',
      isMine: false,
      isRead: true,
      hasAttachment: true,
      createdAt: 1000,
      attachment: attachment,
    );

    testWidgets('draws an image attachment as an image bubble', (tester) async {
      await _pump(
        tester,
        MessageBubble(message: bubbleMessage(imageInfo()), peerColorHue: 200),
        gateway: FakeAttachmentGateway(
          downloadResult:
              (_) => Completer<messages_api.AttachmentData>().future,
        ),
      );

      expect(find.byType(EncryptedImageMessage), findsOneWidget);
      expect(find.byType(EncryptedFileMessage), findsNothing);
    });

    testWidgets('draws a document as a file card, not as its name', (
      tester,
    ) async {
      await _pump(
        tester,
        MessageBubble(message: bubbleMessage(pdfInfo()), peerColorHue: 200),
        gateway: FakeAttachmentGateway(),
      );

      expect(find.byType(EncryptedFileMessage), findsOneWidget);
      // The name appears once, in the card — not also as message text.
      expect(find.text('transfer.pdf'), findsOneWidget);
    });
  });
}

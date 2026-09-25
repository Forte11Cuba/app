import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mostro/features/chat/attachments/attachment_launcher.dart';
import 'package:path/path.dart' as p;

import '../../../support/attachment_fixtures.dart';

void main() {
  group('safeTempFileName', () {
    test('keeps a plain name and swaps in the extension of its type', () {
      expect(safeTempFileName('transfer.pdf', 'pdf'), 'transfer.pdf');
      expect(safeTempFileName('receipt.exe', 'jpg'), 'receipt.jpg');
    });

    test('drops anything a Windows shell would read as a command', () {
      final name = safeTempFileName('a&calc|x^"%PATH%".pdf', 'pdf');
      expect(name, matches(RegExp(r'^[A-Za-z0-9 ._-]+\.pdf$')));
      expect(name, isNot(contains('&')));
    });

    test('never starts with a dot or a dash, never empty', () {
      expect(safeTempFileName('--help.pdf', 'pdf'), 'help.pdf');
      expect(safeTempFileName('.hidden.pdf', 'pdf'), 'hidden.pdf');
      expect(safeTempFileName('???.pdf', 'pdf'), 'attachment.pdf');
      expect(safeTempFileName('', 'pdf'), 'attachment.pdf');
    });

    test('caps a long name', () {
      final name = safeTempFileName('${'x' * 300}.pdf', 'pdf');
      expect(name.length, lessThanOrEqualTo(64));
    });
  });

  group('AttachmentLauncher', () {
    late Directory root;
    late AttachmentLauncher launcher;

    setUp(() {
      root = Directory.systemTemp.createTempSync('attachments_test');
      launcher = AttachmentLauncher(tempRoot: () async => root);
    });
    tearDown(() => root.deleteSync(recursive: true));

    test('hands off only the types v1 sends', () {
      for (final type in kOpenableTypes.keys) {
        expect(launcher.canHandOffType(type), isTrue, reason: type);
      }
      expect(
        launcher.canHandOffType('application/vnd.android.package-archive'),
        isFalse,
      );
      expect(launcher.canHandOffType('text/html'), isFalse);
      expect(launcher.canHandOffType('application/octet-stream'), isFalse);
    });

    test(
      'writes each copy apart, named safely, and sweep deletes them',
      () async {
        final data = attachmentData(
          [1, 2, 3],
          fileName: 'bank & co.pdf',
          mimeType: 'application/pdf',
        );

        final first = await launcher.writeTempCopy(data);
        final second = await launcher.writeTempCopy(data);

        expect(first, isNot(second));
        expect(
          p.isWithin(p.join(root.path, kAttachmentTempDir), first),
          isTrue,
        );
        expect(p.basename(first), 'bank _ co.pdf');
        expect(File(first).readAsBytesSync(), [1, 2, 3]);

        await launcher.sweep();

        expect(File(first).existsSync(), isFalse);
        expect(
          Directory(p.join(root.path, kAttachmentTempDir)).existsSync(),
          isFalse,
        );
      },
    );

    test('refuses to write a type it would not hand off', () async {
      final data = attachmentData(
        [1],
        fileName: 'x.apk',
        mimeType: 'application/zip',
      );
      await expectLater(launcher.writeTempCopy(data), throwsStateError);
      expect(
        Directory(p.join(root.path, kAttachmentTempDir)).existsSync(),
        isFalse,
      );
    });

    test('sweep with nothing to delete is a no-op', () async {
      await launcher.sweep();
    });
  });

  test('the Android app drops the media permissions open_filex declares', () {
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    for (final permission in [
      'READ_EXTERNAL_STORAGE',
      'READ_MEDIA_IMAGES',
      'READ_MEDIA_VIDEO',
      'READ_MEDIA_AUDIO',
    ]) {
      expect(
        manifest,
        contains(
          '<uses-permission android:name="android.permission.$permission" '
          'tools:node="remove" />',
        ),
        reason: permission,
      );
    }
  });
}

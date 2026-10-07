import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mostro/features/notifications/services/local_notifications.dart';

/// Android draws a notification's small icon from its alpha channel only, so
/// the opaque launcher icon shows as a solid square. Both notifications —
/// the trade update FCM renders and the chat-wake notice the app renders —
/// must name the white silhouette instead.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const resDir = 'android/app/src/main/res';
  const sizes = {
    'mdpi': 24,
    'hdpi': 36,
    'xhdpi': 48,
    'xxhdpi': 72,
    'xxxhdpi': 96,
  };
  final manifest =
      File('android/app/src/main/AndroidManifest.xml').readAsStringSync();

  group('the chat-wake notice', () {
    late List<MethodCall> calls;

    setUp(() {
      calls = [];
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('dexterous.com/flutter/local_notifications'),
            (call) async {
              calls.add(call);
              return true;
            },
          );
    });

    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('dexterous.com/flutter/local_notifications'),
            null,
          );
    });

    String? initializedIcon() {
      final init = calls.lastWhere((call) => call.method == 'initialize');
      return (init.arguments as Map)['defaultIcon'] as String?;
    }

    test(
      'the background isolate shows it with the notification icon',
      () async {
        await showChatWakeNotification('Mostro', 'You have a new message');

        expect(initializedIcon(), kNotificationIcon);
        expect(calls.map((call) => call.method), contains('show'));
      },
    );

    test('the app initialises the plugin with the same icon', () async {
      await ensurePushNotificationChannel();

      expect(initializedIcon(), kNotificationIcon);
    });
  });

  test('FCM renders the trade update with the same icon', () {
    expect(kNotificationIcon, '@drawable/ic_notification');
    expect(
      manifest,
      contains(
        'android:name="com.google.firebase.messaging.default_notification_icon"\n'
        '            android:resource="$kNotificationIcon" />',
      ),
    );
  });

  test('FCM falls back to the channel the app creates', () {
    expect(
      manifest,
      contains(
        'android:name="com.google.firebase.messaging.default_notification_channel_id"\n'
        '            android:value="$kPushChannelId" />',
      ),
    );
  });

  test(
    'every density is a silhouette: transparent and visible pixels',
    () async {
      for (final MapEntry(key: density, value: size) in sizes.entries) {
        final bytes =
            File(
              '$resDir/drawable-$density/ic_notification.png',
            ).readAsBytesSync();
        final codec = await ui.instantiateImageCodec(bytes);
        final image = (await codec.getNextFrame()).image;
        final rgba = (await image.toByteData())!;

        expect((image.width, image.height), (size, size), reason: density);
        final alphas = [
          for (var i = 3; i < rgba.lengthInBytes; i += 4) rgba.getUint8(i),
        ];
        // An opaque icon, whatever its colours, renders as a solid square.
        expect(
          alphas,
          contains(0),
          reason: '$density has no transparent pixel',
        );
        expect(alphas, contains(255), reason: '$density has no visible pixel');
      }
    },
  );
}

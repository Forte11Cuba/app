import 'package:flutter_test/flutter_test.dart';
import 'package:mostro/features/home/providers/home_order_providers.dart';

import '../../support/provider_harness.dart';

void main() {
  group('order book pipeline lifetime', () {
    test('tears down once nothing is displaying the filtered list', () async {
      var bookDisposed = false;
      final container = createContainer(overrides: [
        orderBookProvider.overrideWith((ref) {
          ref.onDispose(() => bookDisposed = true);
          return Stream.value(<OrderItem>[]);
        }),
      ]);

      final subscription = container.listen(filteredOrdersProvider, (_, __) {});
      await container.read(orderBookProvider.future);
      expect(bookDisposed, isFalse);

      // The user leaves Home for Chat, Trades or Settings.
      subscription.close();
      await Future<void>.delayed(Duration.zero);

      expect(
        bookDisposed,
        isTrue,
        reason: 'a derived provider that outlives the screen pins the whole '
            'map+filter+sort pipeline to every relay event',
      );
    });
  });
}

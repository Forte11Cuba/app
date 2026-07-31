import 'package:flutter_test/flutter_test.dart';
import 'package:mostro/core/daemon_errors.dart';
import 'package:mostro/l10n/app_localizations_en.dart';

/// PR #252 review (ermeme, supplemental): `UnsupportedNodeProtocol` is
/// reachable from every daemon action, not only create/take, and some Rust
/// wrappers prepend their own context while interpolating the inner error.
/// The central mapper must recognize the marker anywhere in the message so
/// invoice, cancel, fiat-sent, release, dispute, and rating flows all show
/// actionable node-selection guidance instead of a raw marker or an
/// unrelated generic failure.
void main() {
  final l10n = AppLocalizationsEn();

  test('maps the bare unsupported-protocol marker', () {
    expect(
      localizedDaemonError(l10n, 'UnsupportedNodeProtocol:1', fallback: 'x'),
      l10n.nodeProtocolUnsupported,
    );
  });

  test('finds the marker inside the dispute ProtocolError wrapper', () {
    expect(
      localizedDaemonError(
        l10n,
        'ProtocolError: could not build Dispute message: '
        'UnsupportedNodeProtocol:1',
        fallback: 'x',
      ),
      l10n.nodeProtocolUnsupported,
    );
  });

  test('finds the marker inside the rating RateUserDispatchFailed wrapper', () {
    expect(
      localizedDaemonError(
        l10n,
        'RateUserDispatchFailed: UnsupportedNodeProtocol:1',
        fallback: 'x',
      ),
      l10n.nodeProtocolUnsupported,
    );
  });

  test('maps the fail-closed capability-fetch marker', () {
    expect(
      localizedDaemonError(
        l10n,
        'NodeCapabilitiesUnknown: capabilities for node abc not fetched yet',
        fallback: 'x',
      ),
      l10n.nodeCapabilitiesUnknown,
    );
  });

  test('maps timeout and storage markers, and falls back otherwise', () {
    expect(
      localizedDaemonError(l10n, 'NoDaemonResponse', fallback: 'x'),
      l10n.sessionTimeoutMessage,
    );
    expect(
      localizedDaemonError(l10n, 'StorageUnavailable: no db', fallback: 'x'),
      l10n.storageUnavailable,
    );
    expect(
      localizedDaemonError(l10n, 'CantDo: something else', fallback: 'generic'),
      'generic',
    );
  });
}

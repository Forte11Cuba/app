/// Web implementation of the bridge readiness probe.
///
/// See `bridge_probe.dart` for why the probe exists.
///
/// Two globals rather than one tri-state value, so the smoke test can poll for
/// success and still fail fast — with a reason — when the bridge is broken:
///
/// ```js
/// await page.waitForFunction(
///   () => window.mostroBridgeReady === true || window.mostroBridgeError,
/// );
/// ```
library;

import 'dart:js_interop';
// setProperty — "unsafe" only in the sense of a dynamically-keyed property,
// which is exactly what writing a named global is.
import 'dart:js_interop_unsafe';

/// Set to `true` once a Rust bridge call has completed successfully.
const kBridgeReadyFlag = 'mostroBridgeReady';

/// Set to the error string when that call threw instead.
const kBridgeErrorFlag = 'mostroBridgeError';

/// Publishes a successful Rust bridge round-trip to the page.
void markBridgeReady() {
  globalContext.setProperty(kBridgeReadyFlag.toJS, true.toJS);
}

/// Publishes a failed Rust bridge round-trip, with [error] for the CI log.
///
/// The app itself keeps going — the caller already treats this failure as
/// non-fatal — but a build that reaches here is not deployable.
void markBridgeFailed(Object error) {
  globalContext.setProperty(kBridgeErrorFlag.toJS, error.toString().toJS);
}

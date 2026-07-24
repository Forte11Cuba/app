/// Health signal published to the page once the Rust bridge has answered.
///
/// On web the app ships as a wasm bundle whose worst failure mode is silent: a
/// toolchain or bundling regression kills flutter_rust_bridge's worker pool
/// (`DataCloneError`) while the DOM still looks perfectly healthy — the blank
/// page documented in `CLAUDE.md` under "Web (wasm) — non-obvious constraints".
/// Nothing observable from outside the app tells that apart from a working
/// build, so `main()` publishes the outcome of a real bridge call and the
/// headless smoke test in CI waits for it (issue #154).
///
/// Off web this is a no-op: there is no page to publish to, and the native
/// targets fail loudly at build time instead.
library;

export 'bridge_probe_stub.dart'
    if (dart.library.js_interop) 'bridge_probe_web.dart';

//! Log sink — captures `log` crate records, mirrors them to the platform
//! console, and exposes them to Flutter via a flutter_rust_bridge stream.
//!
//! [`install_log_bridge`] makes [`BridgeLogger`] the global `log` backend, and
//! every record it accepts goes to the platform console, to a bounded ring
//! buffer readable with [`recent_logs`], and to the live [`on_log_entry`]
//! stream.
//!
//! Dependency logs arrive here too: `nostr-sdk`, `nostr-relay-pool` and `sqlx`
//! emit through `tracing`, which the crate wires into `log` — see the comment
//! on that dependency in `Cargo.toml`.

use std::cell::Cell;
use std::collections::VecDeque;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Mutex, OnceLock};

use tokio::sync::broadcast;

use crate::api::types::{LogEntry, LogLevel};

/// Entries kept for [`recent_logs`] — a session's worth at `Info` level.
const BUFFER_CAPACITY: usize = 1000;

/// Lag tolerance for a slow live subscriber, not history.
const BROADCAST_CAPACITY: usize = 512;

// ── Shared state ─────────────────────────────────────────────────────────────

static LOG_TX: OnceLock<broadcast::Sender<LogEntry>> = OnceLock::new();
static BUFFER: OnceLock<Mutex<VecDeque<LogEntry>>> = OnceLock::new();

/// Monotonic entry id — how a consumer merging [`recent_logs`] with the live
/// stream drops the overlap.
static COUNTER: AtomicU32 = AtomicU32::new(0);

fn log_sender() -> &'static broadcast::Sender<LogEntry> {
    LOG_TX.get_or_init(|| broadcast::channel(BROADCAST_CAPACITY).0)
}

fn buffer() -> &'static Mutex<VecDeque<LogEntry>> {
    BUFFER.get_or_init(|| Mutex::new(VecDeque::with_capacity(BUFFER_CAPACITY)))
}

// ── Installation and verbosity ───────────────────────────────────────────────

/// Install the log capture bridge. Called once from `init_app()`; until it
/// runs, `log::` records go nowhere.
pub fn install_log_bridge() {
    static INSTALLED: std::sync::Once = std::sync::Once::new();
    INSTALLED.call_once(|| match log::set_logger(&BRIDGE_LOGGER) {
        Ok(()) => log::set_max_level(default_max_level()),
        // flutter_rust_bridge installs its own logger in
        // `setup_default_user_utils()`, which this crate never calls. If this
        // fires, `log::` macros bypass us and only `blog_*` reaches the UI.
        Err(e) => eprintln!("[logging] set_logger failed ({e}) — another logger is already active"),
    });
}

/// Verbosity before the user opts in: verbose while developing, `Info` in a
/// shipped build so `debug!` call sites cost nothing.
fn default_max_level() -> log::LevelFilter {
    if cfg!(debug_assertions) {
        log::LevelFilter::Debug
    } else {
        log::LevelFilter::Info
    }
}

/// Applies the "logging enabled" setting to the global filter.
pub(crate) fn set_verbose_logging(enabled: bool) {
    log::set_max_level(if enabled {
        log::LevelFilter::Debug
    } else {
        default_max_level()
    });
}

// ── Logger ───────────────────────────────────────────────────────────────────

static BRIDGE_LOGGER: BridgeLogger = BridgeLogger;

struct BridgeLogger;

thread_local! {
    /// Set while this thread is inside [`BridgeLogger::log`]: a console sink
    /// that logs would otherwise recurse until the stack runs out.
    static IN_LOG: Cell<bool> = const { Cell::new(false) };
}

struct ReentryGuard;

impl ReentryGuard {
    /// `None` when this thread is already emitting a record.
    fn acquire() -> Option<Self> {
        IN_LOG
            .try_with(|f| if f.replace(true) { None } else { Some(ReentryGuard) })
            .ok()
            .flatten()
    }
}

impl Drop for ReentryGuard {
    fn drop(&mut self) {
        let _ = IN_LOG.try_with(|f| f.set(false));
    }
}

impl log::Log for BridgeLogger {
    fn enabled(&self, metadata: &log::Metadata) -> bool {
        metadata.level() <= log::max_level()
    }

    fn log(&self, record: &log::Record) {
        if !self.enabled(record.metadata()) {
            return;
        }
        let Some(_guard) = ReentryGuard::acquire() else {
            return;
        };

        platform_console(record);
        forward_log(record.level(), record.target(), &record.args().to_string());
    }

    fn flush(&self) {}
}

// ── Platform console sinks ───────────────────────────────────────────────────

/// Android discards a process's stderr, so records go to logcat. The fixed tag
/// keeps `adb logcat -s mostro` useful; `android_logger` prepends the module
/// path to the message.
#[cfg(target_os = "android")]
fn platform_console(record: &log::Record) {
    use log::Log as _;

    static ANDROID: OnceLock<android_logger::AndroidLogger> = OnceLock::new();
    ANDROID
        .get_or_init(|| {
            android_logger::AndroidLogger::new(android_logger::Config::default().with_tag("mostro"))
        })
        .log(record);
}

/// `wasm32` has no stderr; devtools filters on the console severity.
#[cfg(target_arch = "wasm32")]
fn platform_console(record: &log::Record) {
    let line = format!("{}: {}", record.target(), record.args());
    match record.level() {
        log::Level::Error => web_sys::console::error_1(&line.into()),
        log::Level::Warn => web_sys::console::warn_1(&line.into()),
        log::Level::Info => web_sys::console::info_1(&line.into()),
        _ => web_sys::console::debug_1(&line.into()),
    }
}

/// Desktop and iOS: stderr, which is what `flutter run` shows. The timestamp
/// is UTC time-of-day; the Flutter side renders local time.
#[cfg(all(not(target_os = "android"), not(target_arch = "wasm32")))]
fn platform_console(record: &log::Record) {
    let secs = crate::rt::unix_now();
    eprintln!(
        "{:02}:{:02}:{:02}Z [{:<5}] {}: {}",
        (secs / 3600) % 24,
        (secs / 60) % 60,
        secs % 60,
        record.level(),
        record.target(),
        record.args(),
    );
}

// ── Buffer and Flutter stream ────────────────────────────────────────────────

/// Record an entry into the ring buffer and publish it to live subscribers.
pub(crate) fn forward_log(level: log::Level, target: &str, message: &str) {
    let entry = buffer_entry(level, target, message);

    // Fails when nobody is listening — that is what the ring buffer covers.
    let _ = log_sender().send(entry);
}

/// Append to the ring buffer, evicting the oldest, and return the entry.
///
/// The id is claimed under the lock so the buffer stays ordered by id when
/// several threads log at once; a poisoned lock costs the entry its history
/// slot, not its trip to the live stream.
fn buffer_entry(level: log::Level, target: &str, message: &str) -> LogEntry {
    let mut buf = buffer().lock().ok();

    let entry = LogEntry {
        id: COUNTER.fetch_add(1, Ordering::Relaxed),
        level: match level {
            log::Level::Error => LogLevel::Error,
            log::Level::Warn => LogLevel::Warning,
            log::Level::Info => LogLevel::Info,
            _ => LogLevel::Debug,
        },
        tag: short_tag(target),
        message: message.to_string(),
        timestamp: crate::rt::unix_now(),
    };

    if let Some(buf) = buf.as_mut() {
        while buf.len() >= BUFFER_CAPACITY {
            buf.pop_front();
        }
        buf.push_back(entry.clone());
    }

    entry
}

/// Last segment of a `log` target, so `rust::nwc::client` displays as `client`.
fn short_tag(target: &str) -> String {
    target.rsplit("::").next().unwrap_or(target).to_string()
}

/// Emit a record under an explicit `tag` instead of the module path that the
/// `log::` macros use as target.
pub(crate) fn bridge_log(level: log::Level, tag: &str, message: &str) {
    log::Log::log(
        &BRIDGE_LOGGER,
        &log::Record::builder()
            .level(level)
            .target(tag)
            .args(format_args!("{message}"))
            .build(),
    );
}

/// Shorthand helpers for tagged records.
pub(crate) fn blog_info(tag: &str, msg: String) {
    bridge_log(log::Level::Info, tag, &msg);
}
pub(crate) fn blog_warn(tag: &str, msg: String) {
    bridge_log(log::Level::Warn, tag, &msg);
}
pub(crate) fn blog_debug(tag: &str, msg: String) {
    bridge_log(log::Level::Debug, tag, &msg);
}

// ── FRB surface ──────────────────────────────────────────────────────────────

/// Stream of log entries for consumption by Flutter.
pub struct LogEntryStream {
    rx: broadcast::Receiver<LogEntry>,
}

impl LogEntryStream {
    /// Poll for the next log entry.
    pub async fn next(&mut self) -> Option<LogEntry> {
        loop {
            match self.rx.recv().await {
                Ok(entry) => return Some(entry),
                Err(broadcast::error::RecvError::Lagged(_)) => continue,
                Err(broadcast::error::RecvError::Closed) => return None,
            }
        }
    }
}

/// Subscribe to the live log stream.
///
/// Each call returns an independent stream that only sees entries emitted
/// after it subscribes — pair it with [`recent_logs`] for history.
pub fn on_log_entry() -> LogEntryStream {
    LogEntryStream {
        rx: log_sender().subscribe(),
    }
}

/// Snapshot of the buffered history, newest first.
///
/// Ids increase monotonically: subscribe to [`on_log_entry`] first, snapshot
/// second, and drop streamed entries the snapshot already holds.
pub fn recent_logs() -> Vec<LogEntry> {
    buffer()
        .lock()
        .map(|buf| buf.iter().rev().cloned().collect())
        .unwrap_or_default()
}

/// Drop the buffered history — log lines can name orders and counterparties,
/// so anything that wipes the user's identity should call this too.
pub fn clear_logs() {
    if let Ok(mut buf) = buffer().lock() {
        buf.clear();
    }
}

// ── Tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    /// Tests share the globals, so match on a unique tag, never on position.
    async fn recv_tagged(stream: &mut LogEntryStream, tag: &str) -> LogEntry {
        crate::rt::time::timeout(std::time::Duration::from_secs(2), async {
            loop {
                let entry = stream.next().await.expect("stream closed unexpectedly");
                if entry.tag == tag {
                    return entry;
                }
            }
        })
        .await
        .unwrap_or_else(|_| panic!("timed out waiting for a '{tag}' entry"))
    }

    #[test]
    fn forward_log_does_not_panic() {
        // Calling forward_log should not panic regardless of bridge state.
        // If bridge is installed, this forwards; if not, it's a no-op.
        forward_log(log::Level::Info, "test", "should not panic");
    }

    #[tokio::test]
    async fn install_and_receive_log() {
        install_log_bridge();
        let mut stream = on_log_entry();

        forward_log(log::Level::Warn, "nwc::client", "test warning");

        let entry = recv_tagged(&mut stream, "client").await;
        assert_eq!(entry.level, LogLevel::Warning);
        assert_eq!(entry.message, "test warning");
    }

    /// Guards the `tracing`-to-`log` wiring: without it every nostr-sdk and
    /// sqlx event is dropped.
    #[tokio::test]
    async fn tracing_events_reach_the_bridge() {
        install_log_bridge();
        let mut stream = on_log_entry();

        tracing::warn!(target: "tracing_probe", "event from a dependency");

        let entry = recv_tagged(&mut stream, "tracing_probe").await;
        assert_eq!(entry.level, LogLevel::Warning);
        assert!(entry.message.contains("event from a dependency"));
    }

    /// `blog_*` must go through the same fan-out as the `log::` macros.
    #[tokio::test]
    async fn tagged_helpers_reach_the_bridge() {
        install_log_bridge();
        let mut stream = on_log_entry();

        blog_info("blog_probe", "tagged message".to_string());

        let entry = recv_tagged(&mut stream, "blog_probe").await;
        assert_eq!(entry.level, LogLevel::Info);
        assert_eq!(entry.message, "tagged message");
    }

    /// Writes straight to the buffer: flooding the broadcast channel instead
    /// would lag any receiver a concurrent test is holding.
    #[test]
    fn recent_logs_is_bounded_and_newest_first() {
        for i in 0..(BUFFER_CAPACITY + 50) {
            buffer_entry(log::Level::Info, "buffer_probe", &format!("entry {i}"));
        }

        let entries = recent_logs();
        assert!(entries.len() <= BUFFER_CAPACITY);
        assert!(
            entries.windows(2).all(|w| w[0].id > w[1].id),
            "recent_logs must be ordered newest first",
        );
    }

    #[test]
    fn verbose_logging_gates_debug_records() {
        install_log_bridge();

        set_verbose_logging(true);
        assert!(log::log_enabled!(log::Level::Debug));

        // Also restores the filter for anything running concurrently.
        set_verbose_logging(false);
        assert_eq!(log::max_level(), default_max_level());
    }
}

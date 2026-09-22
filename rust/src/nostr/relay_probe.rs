//! Asking a `Connected` relay whether it is still there.
//!
//! Every recovery path in this client is keyed on an **observed** change:
//! a relay transitioning to `Disconnected`, the pool going `Online`, a relay
//! sending `CLOSED`, or the app resuming. A connection that keeps answering
//! the protocol while delivering nothing produces none of those, so nothing
//! wakes [`crate::nostr::live_subs`] — and `repair_relay` would report zero
//! anyway, since the SDK's registry still lists the subscription as present.
//!
//! Measured against a live daemon (issue #291): with the relay frozen so it
//! could not answer the WebSocket PONG, the SDK's own ping caught it in 56 s
//! and `live_subs` re-issued every subscription 15 s after it came back. With
//! a proxy answering the pings while swallowing the relay's frames, the app
//! was deaf for **6 minutes without logging a single line**, and the five
//! events it missed were never requested again. That second shape is what
//! this module detects. It is also the shape of a REQ refused over a relay's
//! per-connection cap (`req_census`): the subscription never existed, and the
//! `NOTICE` names none, so nothing can repair it.
//!
//! **Traffic proves life; silence proves nothing.** That asymmetry is the
//! whole design. Recent traffic from a relay is taken as proof it is healthy
//! and skips the probe — but a quiet relay is never *concluded* dead, only
//! asked. PR #324 measured 240 s of silence on a perfectly healthy relay and
//! would have reconnected it, so a silence timer cannot be the signal.

use std::collections::HashMap;
use std::time::Duration;

use nostr_sdk::prelude::{EventId, Filter, RelayStatus};

/// How long a relay may stay quiet before it is asked whether it is alive.
pub(crate) const PROBE_INTERVAL: Duration = Duration::from_secs(120);

/// How long the relay has to answer the probe's EOSE. Generous next to the
/// measured round trips (20 ms on a local nostr-rs-relay, 820 ms on nos.lol)
/// so a slow relay is never mistaken for a dead one.
pub(crate) const PROBE_TIMEOUT: Duration = Duration::from_secs(15);

/// Traffic newer than this makes a probe pointless: something arrived, so the
/// socket delivers.
pub(crate) const FRESH_TRAFFIC_WINDOW: Duration = Duration::from_secs(120);

/// The probe's filter: one event id of 32 zero bytes, which nothing can match,
/// so a healthy relay answers EOSE with no events at all.
///
/// **Not** `limit(0)`, the obvious candidate: measured, strfry (nos.lol)
/// answers it with EOSE in 0.8 s but nostr-rs-relay never answers it at all,
/// which would have made every such relay look dead. An id filter that cannot
/// match is answered by both — 0.02 s and 0.82 s respectively.
pub(crate) fn probe_filter() -> Filter {
    Filter::new().id(EventId::from_byte_array([0u8; 32]))
}

/// When each relay was last heard from, and last asked.
///
/// Keyed by relay URL so one relay's traffic never vouches for another's
/// socket — the flaw ermeme caught in #324's first round, where a pool-wide
/// timestamp meant a live relay masked a dead one.
#[derive(Debug, Default)]
pub(crate) struct RelayLiveness {
    seen: HashMap<String, i64>,
    probed: HashMap<String, i64>,
}

impl RelayLiveness {
    /// Something arrived from `url`: an event, or any relay message.
    pub(crate) fn record_traffic(&mut self, url: &str, at: i64) {
        self.seen.insert(url.to_string(), at);
    }

    /// A probe was issued to `url`, whatever its outcome. Recording it on the
    /// attempt, not on success, is what keeps a still-silent relay from being
    /// probed again on the very next tick.
    pub(crate) fn record_probe(&mut self, url: &str, at: i64) {
        self.probed.insert(url.to_string(), at);
    }

    /// Drop everything known about `url` — it left the pool.
    pub(crate) fn forget(&mut self, url: &str) {
        self.seen.remove(url);
        self.probed.remove(url);
    }

    pub(crate) fn last_seen(&self, url: &str) -> Option<i64> {
        self.seen.get(url).copied()
    }

    pub(crate) fn last_probe(&self, url: &str) -> Option<i64> {
        self.probed.get(url).copied()
    }
}

/// Whether `url` should be asked, now.
///
/// A relay with no traffic on record is a candidate rather than an exemption:
/// the one thing a connection that has never delivered anything deserves is a
/// question. #324 took the opposite reading — a missing baseline disabled its
/// recovery for good — and needed a review round to seed one at connect time.
/// Asking costs a REQ and an EOSE, and a healthy relay answers, so the
/// pessimistic default is the safe one here.
pub(crate) fn should_probe(
    status: RelayStatus,
    last_seen: Option<i64>,
    last_probe: Option<i64>,
    now: i64,
) -> bool {
    // A relay the SDK already knows is down is the SDK's to reconnect; only
    // one that still claims to be Connected can be silently dead.
    if status != RelayStatus::Connected {
        return false;
    }
    if within(last_seen, now, FRESH_TRAFFIC_WINDOW) {
        return false;
    }
    !within(last_probe, now, PROBE_INTERVAL)
}

/// Whether `stamp` is set and newer than `window` ago.
fn within(stamp: Option<i64>, now: i64, window: Duration) -> bool {
    stamp.is_some_and(|at| now.saturating_sub(at) < window.as_secs() as i64)
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: i64 = 1_800_000_000;

    #[test]
    fn a_quiet_connected_relay_is_asked() {
        assert!(should_probe(
            RelayStatus::Connected,
            Some(NOW - 300),
            Some(NOW - 300),
            NOW
        ));
    }

    /// The measurement that sank #324: 240 s of silence on a healthy relay.
    /// It is long enough to be asked — and asking is all that happens. Nothing
    /// here concludes the relay is dead, which is why a quiet node no longer
    /// means a reconnect every four minutes.
    #[test]
    fn four_minutes_of_silence_asks_rather_than_concludes() {
        assert!(should_probe(
            RelayStatus::Connected,
            Some(NOW - 240),
            None,
            NOW
        ));
    }

    #[test]
    fn recent_traffic_skips_the_probe() {
        assert!(!should_probe(
            RelayStatus::Connected,
            Some(NOW - 5),
            None,
            NOW
        ));
    }

    #[test]
    fn a_relay_that_is_not_connected_is_never_probed() {
        for status in [
            RelayStatus::Disconnected,
            RelayStatus::Connecting,
            RelayStatus::Terminated,
        ] {
            assert!(
                !should_probe(status, None, None, NOW),
                "{status:?} is the SDK's own reconnect to handle"
            );
        }
    }

    /// Without this the timeout path would re-probe on every tick of a relay
    /// that stays silent — the 30-second reconnect loop CodeRabbit found in
    /// #324, one layer up.
    #[test]
    fn a_relay_asked_recently_is_not_asked_again() {
        assert!(!should_probe(
            RelayStatus::Connected,
            Some(NOW - 600),
            Some(NOW - 10),
            NOW
        ));
    }

    #[test]
    fn a_relay_that_never_delivered_anything_is_asked() {
        assert!(should_probe(RelayStatus::Connected, None, None, NOW));
    }

    #[test]
    fn the_probe_filter_can_match_nothing_and_is_not_a_zero_limit() {
        let filter = probe_filter();
        assert_eq!(
            filter.ids.as_ref().map(|ids| ids.len()),
            Some(1),
            "the probe asks for one impossible id"
        );
        assert!(
            filter.limit.is_none(),
            "limit(0) is unanswered by nostr-rs-relay — see probe_filter"
        );
    }

    #[test]
    fn liveness_is_recorded_per_relay() {
        let mut liveness = RelayLiveness::default();
        liveness.record_traffic("wss://a", NOW);
        liveness.record_traffic("wss://b", NOW - 600);

        // One relay's traffic must not vouch for the other's socket.
        assert!(!should_probe(
            RelayStatus::Connected,
            liveness.last_seen("wss://a"),
            None,
            NOW
        ));
        assert!(should_probe(
            RelayStatus::Connected,
            liveness.last_seen("wss://b"),
            None,
            NOW
        ));
    }

    #[test]
    fn forgetting_a_relay_drops_both_stamps() {
        let mut liveness = RelayLiveness::default();
        liveness.record_traffic("wss://a", NOW);
        liveness.record_probe("wss://a", NOW);

        liveness.forget("wss://a");

        assert_eq!(liveness.last_seen("wss://a"), None);
        assert_eq!(liveness.last_probe("wss://a"), None);
    }
}

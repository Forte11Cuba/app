//! Correlation registry for outgoing daemon requests.
//!
//! Every request this client sends the daemon (create, take, add-invoice,
//! restore) is answered by an event that arrives on a shared subscription,
//! out of band and possibly interleaved with stale relay replays. This module
//! owns the bookkeeping that decides which inbound reply belongs to which
//! in-flight request, and hands the waiting caller its result.
//!
//! It lives here rather than in `api/` because nothing in it is callable from
//! Dart: it is protocol state, and `api/` is the FRB bridge surface (#120).
//!
//! The correlation rule is the whole point: a record is keyed by the fresh
//! trade key the attempt derived, and only a reply echoing the exact
//! `request_id` nonce may consume it. Anything else — an unsolicited event, a
//! relay replaying an old one — must leave the record intact for the genuine
//! reply that may still be in flight.

use crate::mostro::status::{map_core_status, status_for_action};
use std::collections::HashMap;
use std::sync::OnceLock;

/// Result sent by the daemon-message handler to the waiting request caller.
pub(crate) enum DaemonReply {
    /// Daemon accepted the order and assigned a UUID (create flow).
    Confirmed { daemon_id: String },
    /// Daemon accepted the take (take flow). Unlike a create, the take's
    /// first reply varies by role and daemon config (add-invoice,
    /// pay-invoice, a direct progression message, …), so the reply carries
    /// whatever the caller needs to build the trade from real daemon data
    /// instead of optimistic assumptions.
    TakeAccepted {
        action: mostro_core::message::Action,
        /// Order status from the reply payload, when present.
        status: Option<crate::api::types::OrderStatus>,
        /// Sat amount the daemon calculated for the trade, when present.
        amount_sats: Option<u64>,
        /// Hold invoice bolt11 (seller taking a buy order), when present.
        hold_invoice: Option<String>,
    },
    /// Daemon acknowledged an add-invoice. The reply doubles as a status
    /// update processed by the per-action arms; the caller only needs the
    /// unblock, so no data travels with it.
    Acknowledged,
    /// Daemon rejected the request with a CantDo reason.
    Rejected { reason: String, message: String },
    /// Daemon replied to a RestoreSession with the user's active trades and
    /// disputes. Correlated by trade pubkey (RestoreSession carries no
    /// request_id) — see take_matching_restore.
    Restored(mostro_core::message::RestoreSessionInfo),
}

/// What kind of outgoing request a pending record tracks.
pub(crate) enum PendingRequestKind {
    Create {
        /// Locally-generated UUID the order was created under before the
        /// daemon assigned the real one. Bridged to the daemon UUID on
        /// confirmation.
        local_uuid: String,
        /// Content fingerprint (see `order_content_key`) — lets the Kind
        /// 38383 subscription find this record when the daemon's public
        /// event arrives (that event carries neither our trade pubkey nor a
        /// request_id).
        content_key: String,
    },
    /// A take-buy / take-sell awaiting the daemon's first reply.
    Take,
    /// A buyer's add-invoice awaiting the daemon's acknowledgement.
    AddInvoice,
    /// A session-restore awaiting the daemon's RestoreData reply. Correlated
    /// by trade pubkey, not request_id (the RestoreSession message carries
    /// no request_id — see mostro-core Message::new_restore).
    Restore,
}

/// Everything one outgoing daemon request needs tracked until its reply is
/// consumed.
///
/// `request_id` is the correlation nonce sent in the outgoing message; the
/// daemon echoes it in both the success reply and any `CantDo` rejection.
/// Only a reply carrying the matching nonce may resolve or consume this
/// record — stale events replayed by relays carry a different (or no)
/// `request_id` and must leave every part of it in place for the genuine
/// reply. Keeping the waiter channel, the trade index, and the kind-specific
/// bridging state in one record keyed by the attempt's fresh trade key means
/// an uncorrelated event cannot consume state belonging to a live (or
/// concurrent) request.
pub(crate) struct PendingRequest {
    pub(crate) request_id: u64,
    pub(crate) trade_index: u32,
    pub(crate) kind: PendingRequestKind,
    /// `Some` while the caller is blocked waiting. The 10s timeout detaches
    /// only this sender and leaves the rest of the record, so a genuine late
    /// reply still reconciles trade-key and id bindings instead of being
    /// indistinguishable from a stale replay.
    pub(crate) tx: Option<tokio::sync::oneshot::Sender<DaemonReply>>,
}

/// Maps `trade_pubkey_hex` → the pending daemon request for that trade key.
///
/// Each request derives a fresh trade key, so one entry per key suffices;
/// sequential requests on the same key (e.g. a take followed by add-invoice)
/// work because the previous record is consumed by its reply. For creates:
/// the daemon assigns its own UUID to a new order and publishes it as a Kind
/// 38383 event signed by the daemon (not the maker), so the real order ID is
/// only learnable from the daemon acknowledgement; the record carries
/// the correlation state needed to consume that acknowledgement safely.
pub(crate) static PENDING_REQUESTS: OnceLock<std::sync::Mutex<HashMap<String, PendingRequest>>> = OnceLock::new();

pub(crate) fn pending_requests() -> &'static std::sync::Mutex<HashMap<String, PendingRequest>> {
    PENDING_REQUESTS.get_or_init(|| std::sync::Mutex::new(HashMap::new()))
}

/// True when a daemon reply carrying `got` may resolve a waiter that expects
/// `expected`. Replies must echo the exact nonce — `None` (stale replays,
/// unsolicited events) never matches.
pub(crate) fn request_id_matches(expected: u64, got: Option<u64>) -> bool {
    got == Some(expected)
}

/// Remove and return the pending RESTORE request for `pubkey_hex`. Unlike
/// `take_matching_request`, there is no request_id gate: the RestoreSession
/// message carries no request_id, so the daemon's RestoreData reply is
/// correlated purely by the trade pubkey it is addressed to.
pub(crate) fn take_matching_restore(pubkey_hex: &str) -> Option<PendingRequest> {
    let mut map = pending_requests().lock().ok()?;
    match map.get(pubkey_hex) {
        Some(p) if matches!(p.kind, PendingRequestKind::Restore) => map.remove(pubkey_hex),
        _ => None,
    }
}

/// Remove and return the pending request for `trade_pubkey_hex` **only** when
/// `got` echoes its `request_id`. A mismatched or absent id leaves the record
/// in place: relays can replay historical events, and a stale reply must not
/// confirm, reject, or reconcile a live request — the genuine reply (carrying
/// the nonce) arrives later and finds the record.
pub(crate) fn take_matching_request(trade_pubkey_hex: &str, got: Option<u64>) -> Option<PendingRequest> {
    let mut map = pending_requests().lock().ok()?;
    match map.get(trade_pubkey_hex) {
        Some(p) if request_id_matches(p.request_id, got) => map.remove(trade_pubkey_hex),
        Some(_) => {
            crate::api::logging::blog_debug("daemon-msg", format!(
                "request_id {got:?} does not match pending request for trade={} — \
                 leaving record for the genuine reply",
                &trade_pubkey_hex[..8]
            ));
            None
        }
        None => None,
    }
}

/// Remove and return the pending create whose content fingerprint equals
/// `content_key` — used by the Kind 38383 subscription to bridge the local
/// UUID once the daemon's public event arrives. Records with a live waiter
/// (`tx` is `Some`) are left alone: the in-flight `create_order` call owns
/// the reconciliation and must still find its record when the kind-14
/// acknowledgement lands.
pub(crate) fn take_pending_create_by_content_key(content_key: &str) -> Option<PendingRequest> {
    let mut map = pending_requests().lock().ok()?;
    let key = map
        .iter()
        .find(|(_, p)| {
            p.tx.is_none()
                && matches!(
                    &p.kind,
                    PendingRequestKind::Create { content_key: ck, .. } if ck == content_key
                )
        })
        .map(|(k, _)| k.clone())?;
    map.remove(&key)
}

/// Detach the waiter channel from the pending request for `trade_pubkey_hex`,
/// leaving the record itself in place — but only when `request_id` still
/// identifies this caller's own attempt. Called on the 10s timeout: the
/// caller stops waiting, but the record must survive so a genuine late reply
/// still reconciles (and a stale replay still cannot).
///
/// The nonce gate matters for same-key overlaps: `send_invoice` reuses the
/// take's trade key, so a newer attempt may have overwritten this record —
/// a timed-out older attempt must not detach the newer attempt's live waiter.
pub(crate) fn detach_request_waiter(trade_pubkey_hex: &str, request_id: u64) {
    if let Ok(mut m) = pending_requests().lock() {
        if let Some(p) = m.get_mut(trade_pubkey_hex) {
            if p.request_id == request_id {
                p.tx = None;
            }
        }
    }
}

/// Drop the pending request for `trade_pubkey_hex` — but only when
/// `request_id` still identifies this caller's own attempt (publish failure
/// rollback). Same same-key overlap rationale as [`detach_request_waiter`].
pub(crate) fn remove_pending_request(trade_pubkey_hex: &str, request_id: u64) {
    if let Ok(mut m) = pending_requests().lock() {
        if m.get(trade_pubkey_hex).is_some_and(|p| p.request_id == request_id) {
            m.remove(trade_pubkey_hex);
        }
    }
}

/// Drop whatever pending request remains for `trade_pubkey_hex`,
/// unconditionally. Only for the end of the per-trade subscription's
/// lifetime, when no reply can be delivered to any attempt on this key.
pub(crate) fn purge_pending_request(trade_pubkey_hex: &str) {
    if let Ok(mut m) = pending_requests().lock() {
        m.remove(trade_pubkey_hex);
    }
}

/// Local UUID of the pending create for `trade_pubkey_hex`, if any — a
/// read-only peek used to decide whether a stored order id is ours to rebind.
pub(crate) fn pending_local_uuid_for(trade_pubkey_hex: &str) -> Option<String> {
    pending_requests()
        .lock()
        .ok()?
        .get(trade_pubkey_hex)
        .and_then(|p| match &p.kind {
            PendingRequestKind::Create { local_uuid, .. } => Some(local_uuid.clone()),
            _ => None,
        })
}

/// Remove and return the pending request for `trade_pubkey_hex` only when it
/// is a `Take` and `got` echoes its nonce. Creates are left in place for the
/// `NewOrder` arm — a create's only success reply is `NewOrder`, while a
/// take's first reply varies, so takes are resolved before the per-action
/// arms (see `dispatch_mostro_message`).
pub(crate) fn take_matching_take(trade_pubkey_hex: &str, got: Option<u64>) -> Option<PendingRequest> {
    let mut map = pending_requests().lock().ok()?;
    match map.get(trade_pubkey_hex) {
        Some(p)
            if request_id_matches(p.request_id, got)
                && matches!(p.kind, PendingRequestKind::Take) =>
        {
            map.remove(trade_pubkey_hex)
        }
        _ => None,
    }
}

/// Remove and return the pending request for `trade_pubkey_hex` only when it
/// is an `AddInvoice` and `got` echoes its nonce. Unlike takes, the consumed
/// message still flows through the per-action arms — an add-invoice reply is
/// also a status update (see `dispatch_mostro_message`).
pub(crate) fn take_matching_add_invoice(trade_pubkey_hex: &str, got: Option<u64>) -> Option<PendingRequest> {
    let mut map = pending_requests().lock().ok()?;
    match map.get(trade_pubkey_hex) {
        Some(p)
            if request_id_matches(p.request_id, got)
                && matches!(p.kind, PendingRequestKind::AddInvoice) =>
        {
            map.remove(trade_pubkey_hex)
        }
        _ => None,
    }
}

/// Classify the daemon's first reply to a take into a [`DaemonReply`].
///
/// A take's success reply varies by role, order shape and daemon config —
/// `add-invoice` (buyer, with the calculated sats in an `Order` payload),
/// `pay-invoice` (seller, hold invoice in a `PaymentRequest` payload), or a
/// direct progression message when an invoice was pre-attached — so
/// classification goes by payload shape rather than by enumerating actions
/// (the pattern MostriX uses). `pay-bond-invoice` maps to a stable
/// `BondRequired` rejection: anti-abuse bonds are not supported yet, and an
/// honest error beats a fake trade or a silent timeout.
pub(crate) fn classify_take_reply(
    action: &mostro_core::message::Action,
    payload: &Option<mostro_core::message::Payload>,
) -> DaemonReply {
    use mostro_core::message::{Action, Payload};

    if matches!(action, Action::PayBondInvoice) {
        return DaemonReply::Rejected {
            reason: "BondRequired".to_string(),
            message: "BondRequired".to_string(),
        };
    }

    match payload {
        Some(Payload::PaymentRequest(small_order, invoice, amount)) => {
            let amount_sats = amount
                .and_then(|a| u64::try_from(a).ok())
                .or_else(|| {
                    small_order.as_ref().and_then(|so| {
                        if so.amount > 0 { Some(so.amount as u64) } else { None }
                    })
                });
            DaemonReply::TakeAccepted {
                action: action.clone(),
                status: small_order
                    .as_ref()
                    .and_then(|so| so.status.and_then(map_core_status))
                    .or_else(|| status_for_action(action)),
                amount_sats,
                hold_invoice: Some(invoice.clone()),
            }
        }
        Some(Payload::Order(small_order)) => DaemonReply::TakeAccepted {
            action: action.clone(),
            status: small_order
                .status
                .and_then(map_core_status)
                .or_else(|| status_for_action(action)),
            amount_sats: if small_order.amount > 0 {
                Some(small_order.amount as u64)
            } else {
                None
            },
            hold_invoice: None,
        },
        // Action-only progression reply (payload absent or of another shape):
        // still a genuine acceptance. The take interception consumes the
        // message before the status-sync arms run, so derive the implied
        // status from the action itself — otherwise the trade would persist
        // as Pending even though the daemon already advanced it (e.g.
        // waiting-seller-to-pay after a take-sell with an LN address).
        _ => DaemonReply::TakeAccepted {
            action: action.clone(),
            status: status_for_action(action),
            amount_sats: None,
            hold_invoice: None,
        },
    }
}

/// True when the order id stored for a trade may be rebound to `incoming_id`.
///
/// Only the locally-generated UUID of this trade key's own pending create is
/// ever ours to rebind (local → daemon). A stored id that is not that UUID is
/// either already the daemon's (nothing to do) or belongs to an earlier life
/// of a reused trade key — rebinding it to whatever id an incoming event
/// carries would let a stale replay corrupt a confirmed order.
pub(crate) fn may_reconcile_stored_id(
    stored_id: &str,
    incoming_id: &str,
    pending_local_uuid: Option<&str>,
) -> bool {
    stored_id != incoming_id && pending_local_uuid == Some(stored_id)
}

/// Build a stable content key for a maker order.
///
/// The key is stored in `TRADE_KEY_MAP` at creation time (prefixed with
/// `"content:"` so it never collides with real UUIDs).  On cold start the
/// relay subscription can compute the same key from an incoming Kind 38383
/// event and look up the trade index, restoring `is_mine = true` without
/// needing the daemon's acknowledgement.
pub(crate) fn order_content_key(
    kind: &crate::api::types::OrderKind,
    fiat_code: &str,
    fiat_amount: Option<f64>,
    fiat_amount_min: Option<f64>,
    fiat_amount_max: Option<f64>,
    payment_method: &str,
) -> String {
    let amount = match (fiat_amount, fiat_amount_min, fiat_amount_max) {
        (Some(a), _, _) => format!("f{}", a as i64),
        (_, Some(mn), Some(mx)) => format!("r{}:{}", mn as i64, mx as i64),
        _ => "?".to_string(),
    };
    let k = match kind {
        crate::api::types::OrderKind::Buy => "buy",
        crate::api::types::OrderKind::Sell => "sell",
    };
    format!("content:{k}:{fiat_code}:{amount}:{payment_method}")
}


#[cfg(test)]
mod tests {
    use super::*;

    /// The correlation nonce is the whole guard against a relay replaying an
    /// old reply into a live request: an exact echo, or no match at all.
    #[test]
    fn request_id_only_matches_the_exact_nonce() {
        assert!(request_id_matches(42, Some(42)));
        assert!(!request_id_matches(42, Some(41)));
        // Stale replayed events carry no request_id — they must never match.
        assert!(!request_id_matches(42, None));
    }

    /// A stored id may only be rebound when it is this trade key's own
    /// pending local UUID. Anything else is either already the daemon's or
    /// belongs to an earlier life of a reused key.
    #[test]
    fn only_our_own_pending_local_uuid_may_be_rebound() {
        assert!(may_reconcile_stored_id("local-1", "daemon-1", Some("local-1")));
        // Already the daemon's id: nothing to do.
        assert!(!may_reconcile_stored_id("daemon-1", "daemon-1", Some("daemon-1")));
        // A stale replay must not repoint a confirmed order.
        assert!(!may_reconcile_stored_id("daemon-1", "other", Some("local-1")));
        // No pending create for this key at all.
        assert!(!may_reconcile_stored_id("local-1", "daemon-1", None));
    }

    /// The content key is what lets a cold-started client recognise its own
    /// maker order from the daemon's public event, which carries neither the
    /// trade pubkey nor a request_id. Range and fixed orders must not collide.
    #[test]
    fn the_content_key_separates_range_from_fixed_orders() {
        use crate::api::types::OrderKind;
        let fixed = order_content_key(&OrderKind::Buy, "EUR", Some(100.0), None, None, "SEPA");
        let range = order_content_key(&OrderKind::Buy, "EUR", None, Some(10.0), Some(100.0), "SEPA");
        assert_ne!(fixed, range);
        assert!(fixed.starts_with("content:buy:EUR:"));
        // The prefix keeps these out of the UUID keyspace they share a map with.
        assert!(range.starts_with("content:"));
        // Kind is part of the identity: a buy and a sell are different orders.
        let sell = order_content_key(&OrderKind::Sell, "EUR", Some(100.0), None, None, "SEPA");
        assert_ne!(fixed, sell);
    }
}

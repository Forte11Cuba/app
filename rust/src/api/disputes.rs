/// Disputes API — open, track, and resolve trade disputes.
///
/// Dispute initiation sends a `Dispute` action to the Mostro daemon via NIP-59
/// Gift Wrap.  Incoming admin actions (`adminTookDispute`, `adminSettled`,
/// `adminCanceled`) update the local `Dispute` record and — for
/// `adminTookDispute` — trigger ECDH admin shared key derivation via the
/// session manager.
///
/// All state is held in-memory until the DB persistence layer is wired
/// (Phase 12+).
use anyhow::{anyhow, bail, Result};
use std::collections::HashMap;
use std::sync::OnceLock;
use tokio::sync::{broadcast, RwLock};
use tokio::sync::broadcast::error::RecvError;

use crate::api::types::{Dispute, DisputeResolution, DisputeStatus};

// ── Dispute store ─────────────────────────────────────────────────────────────

struct DisputeStore {
    /// Disputes keyed by trade_id.
    disputes: std::sync::Arc<RwLock<HashMap<String, Dispute>>>,
    /// Broadcast channel; payload = updated Dispute.
    update_tx: broadcast::Sender<Dispute>,
}

impl DisputeStore {
    fn new() -> Self {
        let (update_tx, _) = broadcast::channel(32);
        Self {
            disputes: std::sync::Arc::new(RwLock::new(HashMap::new())),
            update_tx,
        }
    }

    #[allow(dead_code)]
    async fn upsert(&self, dispute: Dispute) {
        {
            let mut store = self.disputes.write().await;
            store.insert(dispute.trade_id.clone(), dispute.clone());
        }
        let _ = self.update_tx.send(dispute);
    }

    async fn get(&self, trade_id: &str) -> Option<Dispute> {
        self.disputes.read().await.get(trade_id).cloned()
    }

    async fn all(&self) -> Vec<Dispute> {
        self.disputes.read().await.values().cloned().collect()
    }

    /// Atomically update a dispute under the write lock.
    ///
    /// `f` receives a mutable reference to the dispute and should return
    /// `Ok(())` to commit the change or `Err(...)` to abort (no mutation
    /// is persisted).  The broadcast notification is sent **after** the
    /// lock is released.
    async fn update_conditional<F>(&self, trade_id: &str, f: F) -> Result<()>
    where
        F: FnOnce(&mut Dispute) -> Result<()>,
    {
        let updated = {
            let mut store = self.disputes.write().await;
            let dispute = store
                .get_mut(trade_id)
                .ok_or_else(|| anyhow!("DisputeNotFound: no dispute for trade {trade_id}"))?;
            f(dispute)?;
            dispute.clone()
        }; // write lock released here
        let _ = self.update_tx.send(updated);
        Ok(())
    }

    /// Atomically insert a new dispute only if no active (non-Resolved)
    /// dispute exists for the trade. Prevents TOCTOU races on concurrent
    /// `open_dispute` calls.
    async fn try_insert_if_absent_or_resolved(&self, dispute: Dispute) -> Result<Dispute> {
        let mut store = self.disputes.write().await;
        if let Some(existing) = store.get(&dispute.trade_id) {
            if existing.status != DisputeStatus::Resolved {
                bail!(
                    "DisputeAlreadyOpen: dispute already exists for trade {}",
                    dispute.trade_id
                );
            }
        }
        store.insert(dispute.trade_id.clone(), dispute.clone());
        // Notify subscribers after releasing the write lock.
        drop(store);
        let _ = self.update_tx.send(dispute.clone());
        Ok(dispute)
    }
}

// ── Global singleton ──────────────────────────────────────────────────────────

static DISPUTE_STORE: OnceLock<DisputeStore> = OnceLock::new();

fn dispute_store() -> &'static DisputeStore {
    DISPUTE_STORE.get_or_init(DisputeStore::new)
}

// ── Helper ────────────────────────────────────────────────────────────────────

use crate::rt::unix_now;

// ── Public API ────────────────────────────────────────────────────────────────

/// Initiate a dispute on an active trade.
///
/// Sends a `Dispute` action to the Mostro daemon via NIP-59 Gift Wrap and
/// creates a local `Dispute` record.
///
/// **Preconditions**: Trade MUST be disputable (funds in escrow). No existing
/// open dispute for this trade.
///
/// **Errors**: `TradeNotDisputable`, `DisputeAlreadyOpen`, `ProtocolError`.
pub async fn open_dispute(trade_id: String, reason: Option<String>) -> Result<Dispute> {
    if trade_id.trim().is_empty() {
        bail!("TradeNotDisputable: trade_id must not be empty");
    }

    // Dispatch Action::Dispute to Mostro BEFORE creating the local record so
    // that a failed publish does not leave an un-retryable "open" slot in the
    // dispute store.  Only on a successful publish do we persist the dispute.
    let trade_index = crate::api::orders::trade_key_for_order(&trade_id)
        .await
        .ok_or_else(|| anyhow!("TradeNotDisputable: no trade key for trade {trade_id}"))?;

    let event_json: String = async {
        let sender_keys =
            crate::api::identity::get_active_trade_keys(trade_index).await?;
        let identity_keys =
            crate::api::identity::get_transport_identity_keys(&sender_keys).await?;
        let mostro_pubkey =
            nostr_sdk::PublicKey::from_hex(&crate::config::active_mostro_pubkey())
                .map_err(|e| anyhow!("invalid mostro pubkey: {e}"))?;
        crate::mostro::actions::dispute(
            &identity_keys,
            &sender_keys,
            &mostro_pubkey,
            &trade_id,
            trade_index,
        )
        .await
    }
    .await
    .map_err(|e| anyhow!("ProtocolError: could not build Dispute message: {e}"))?;

    crate::api::orders::publish_event(&event_json)
        .await
        .map_err(|e| anyhow!("ProtocolError: publish failed: {e}"))?;

    log::info!("[disputes] Dispute dispatched for trade={trade_id}");

    // Publish succeeded — persist the dispute record.
    let dispute = Dispute {
        id: uuid::Uuid::new_v4().to_string(),
        trade_id: trade_id.clone(),
        status: DisputeStatus::Open,
        initiated_by_me: true,
        reason,
        admin_pubkey: None,
        resolution: None,
        opened_at: unix_now(),
        resolved_at: None,
        is_read: true,
    };

    dispute_store()
        .try_insert_if_absent_or_resolved(dispute)
        .await
}

/// Submit free-text evidence for an open dispute.
///
/// Delivered as an admin-type message in the dispute chat.
///
/// **Errors**: `NoOpenDispute`, `EvidenceEmpty`.
pub async fn submit_evidence(trade_id: String, text: String) -> Result<()> {
    if text.trim().is_empty() {
        bail!("EvidenceEmpty: text must not be empty");
    }

    let dispute = dispute_store()
        .get(&trade_id)
        .await
        .ok_or_else(|| anyhow!("NoOpenDispute: no dispute for trade {trade_id}"))?;

    if dispute.status == DisputeStatus::Resolved {
        bail!("NoOpenDispute: dispute for trade {trade_id} is already resolved");
    }

    // Admin pubkey must be known (set by handle_admin_took_dispute).
    let admin_pubkey_hex = dispute
        .admin_pubkey
        .as_deref()
        .ok_or_else(|| anyhow!("AdminNotAssigned: dispute has no admin yet"))?;

    let admin_pubkey = nostr_sdk::PublicKey::from_hex(admin_pubkey_hex)
        .map_err(|e| anyhow!("invalid admin pubkey: {e}"))?;

    // Look up the trade key index.
    let trade_index = crate::api::orders::trade_key_for_order(&trade_id)
        .await
        .ok_or_else(|| anyhow!("TradeNotFound: no trade key for {trade_id}"))?;

    // Same envelope as the peer chat, keyed to the solver instead of the
    // counterparty: inner kind 1 signed by our trade key, NIP-44 under K_conv,
    // inside a kind 14 signed with K_sign and p-tagged to pub(K_conv). No gift
    // wrap and no ephemeral key — see
    // <https://mostro.network/protocol/dispute_chat.html>.
    //
    // The text travels as the message itself rather than a hand-rolled
    // {"type":"evidence"} JSON: this is a conversation with the solver, and
    // that shape had no reader on the other side of the envelope.
    let ctx = crate::api::messages::admin_chat_context(trade_index, &admin_pubkey).await?;
    let inner = crate::api::messages::publish_chat_payload_for(&ctx, &text).await?;

    // Interop dual-write (PR #254 review): the current solver client
    // (mostrix) still reads only NIP-59 gift wrap — its envelope migration is
    // tracked in mostrix#102. Until the deprecation date the evidence also
    // goes out in the pre-migration shape it understands, gift-wrapped
    // straight to the solver. Best-effort: the envelope copy above is the
    // durable one, and this copy disappears with the dual-read window.
    if crate::rt::unix_now() < crate::api::messages::LEGACY_CHAT_DEPRECATION_TS {
        let legacy_send: Result<()> = async {
            let sender_keys = crate::api::identity::get_active_trade_keys(trade_index).await?;
            let payload = serde_json::json!({
                "type": "evidence",
                "trade_id": trade_id,
                "text": text,
            })
            .to_string();
            let event_json = crate::nostr::gift_wrap::wrap(
                &sender_keys,
                &admin_pubkey,
                &payload,
                nostr_sdk::Kind::from(14u16),
            )
            .await
            .map_err(|e| anyhow!("legacy wrap failed: {e}"))?;
            crate::api::orders::publish_event(&event_json)
                .await
                .map_err(|e| anyhow!("legacy publish failed: {e}"))?;
            Ok(())
        }
        .await;
        if let Err(e) = legacy_send {
            log::warn!("[disputes] legacy evidence copy not sent trade={trade_id}: {e}");
        }
    }

    // Record it locally so the dispute conversation has history, exactly as a
    // peer message does. Keyed by the inner event id, so our own echo arriving
    // from a relay dedups against this record instead of duplicating it.
    crate::api::messages::store_outgoing_admin_message(&trade_id, &ctx, &text, &inner).await;

    log::info!("[disputes] evidence submitted for trade={trade_id}");
    Ok(())
}

/// Get dispute details for a trade.
///
/// Returns `None` if no dispute exists.
pub async fn get_dispute(trade_id: String) -> Result<Option<Dispute>> {
    Ok(dispute_store().get(&trade_id).await)
}

/// Handle an incoming `adminTookDispute` event.
///
/// Extracts the admin pubkey, marks the dispute as `InReview`, and derives
/// the ECDH admin shared key for dispute chat encryption.
pub async fn handle_admin_took_dispute(trade_id: String, admin_pubkey: String) -> Result<()> {
    let admin_pubkey_for_key = admin_pubkey.clone();

    // The daemon sends `admin-took-dispute` to BOTH parties, and the side that
    // did not open the dispute has no local record — `update_conditional` would
    // fail with DisputeNotFound and the admin pubkey would be lost. That pubkey
    // is the only way to reach the solver, so create the record instead.
    if dispute_store().get(&trade_id).await.is_none() {
        dispute_store()
            .upsert(Dispute {
                id: uuid::Uuid::new_v4().to_string(),
                trade_id: trade_id.clone(),
                status: DisputeStatus::InReview,
                initiated_by_me: false,
                reason: None,
                admin_pubkey: Some(admin_pubkey.clone()),
                resolution: None,
                opened_at: unix_now(),
                resolved_at: None,
                is_read: false,
            })
            .await;
        log::info!("[disputes] created record for peer-opened dispute trade={trade_id}");
        return derive_admin_shared_key(&trade_id, &admin_pubkey_for_key).await;
    }

    dispute_store()
        .update_conditional(&trade_id, move |dispute| {
            // Idempotent same-solver replay (PR #254 review): the record is
            // committed InReview before key derivation and listener startup,
            // both of which can fail transiently (keys not hydrated yet,
            // relay pool offline). A replayed assignment for the SAME solver
            // is the retry path for exactly that window, so it must fall
            // through to re-derive and re-arm instead of being rejected.
            if dispute.status == DisputeStatus::InReview
                && dispute.admin_pubkey.as_deref() == Some(admin_pubkey.as_str())
            {
                return Ok(());
            }
            if dispute.status != DisputeStatus::Open {
                return Err(anyhow!(
                    "InvalidState: dispute is not open (current: {:?})",
                    dispute.status
                ));
            }
            dispute.status = DisputeStatus::InReview;
            dispute.admin_pubkey = Some(admin_pubkey);
            dispute.is_read = false;
            Ok(())
        })
        .await?;

    derive_admin_shared_key(&trade_id, &admin_pubkey_for_key).await
}

/// Derive the dispute-chat keys for `trade_id` and start listening.
///
/// Both sides ECDH their trade key against the solver's pubkey and split the
/// secret with HKDF exactly as the peer chat does, so `derive_chat_keys` is
/// reused unchanged — the only difference is whose pubkey goes in
/// (<https://mostro.network/protocol/dispute_chat.html>).
///
/// Best-effort: if no trade key exists yet this logs a warning but does not
/// fail. The dispute record and the solver pubkey are already stored, so a
/// later reconnect can start the listener; losing the derivation must not lose
/// the pubkey with it.
async fn derive_admin_shared_key(trade_id: &str, admin_pubkey_hex: &str) -> Result<()> {
    let trade_id = trade_id.to_string();
    let admin_pubkey_hex = admin_pubkey_hex.to_string();

    let start_result: Result<()> = async {
        let trade_index = crate::api::orders::trade_key_for_order(&trade_id)
            .await
            .ok_or_else(|| anyhow!("no trade key for trade {trade_id}"))?;
        let trade_keys = crate::api::identity::get_active_trade_keys(trade_index).await?;
        let admin_pk = nostr_sdk::PublicKey::from_hex(&admin_pubkey_hex)
            .map_err(|e| anyhow!("invalid admin pubkey: {e}"))?;
        let (conv, sign) = crate::crypto::chat_keys::derive_chat_keys(&trade_keys, &admin_pk)?;

        // Own task, like the peer chat: the guard inside is keyed per channel,
        // so this never collides with the peer conversation of the same order.
        crate::rt::spawn(crate::api::messages::subscribe_incoming_chat(
            crate::api::messages::ChatChannel::Dispute,
            trade_id.clone(),
            trade_keys,
            admin_pk,
            conv,
            sign,
        ));
        log::info!("[disputes] dispute chat listening for trade={trade_id}");
        Ok(())
    }
    .await;

    if let Err(e) = start_result {
        log::warn!("[disputes] could not start dispute chat for trade={trade_id}: {e}");
    }

    Ok(())
}

/// Re-arm the dispute-chat listener of every in-review dispute with a known
/// solver. Called when the relay pool comes (back) online, mirroring
/// `resubscribe_active_chats` for the peer channel (PR #254 review): listener
/// startup is best-effort at assignment time and can fail while keys or
/// connectivity are not there yet, and without a rearm path solver replies
/// would stay invisible for the rest of the process. Idempotent — the
/// per-channel single-owner guard makes a spawn for an already-listening
/// dispute a no-op.
pub(crate) async fn resubscribe_active_dispute_chats() {
    for dispute in dispute_store().all().await {
        if dispute.status != DisputeStatus::InReview {
            continue;
        }
        let Some(admin) = dispute.admin_pubkey.clone() else {
            continue;
        };
        let _ = derive_admin_shared_key(&dispute.trade_id, &admin).await;
    }
}

/// Handle an incoming `adminSettled` event (admin resolved in buyer's favour).
pub async fn handle_admin_settled(trade_id: String) -> Result<()> {
    resolve_dispute(trade_id, DisputeResolution::FundsToBuyer).await
}

/// Handle an incoming `adminCanceled` event (admin refunded the seller).
pub async fn handle_admin_canceled(trade_id: String) -> Result<()> {
    resolve_dispute(trade_id, DisputeResolution::FundsToSeller).await
}

async fn resolve_dispute(trade_id: String, resolution: DisputeResolution) -> Result<()> {
    dispute_store()
        .update_conditional(&trade_id, move |dispute| {
            if dispute.status == DisputeStatus::Resolved {
                return Err(anyhow!("InvalidState: dispute is already resolved"));
            }
            dispute.status = DisputeStatus::Resolved;
            dispute.resolution = Some(resolution);
            dispute.resolved_at = Some(unix_now());
            dispute.is_read = false;
            Ok(())
        })
        .await
}

// ── Stream ────────────────────────────────────────────────────────────────────

/// A stream that emits updated [Dispute] records for a specific trade.
pub struct DisputeStream {
    rx: broadcast::Receiver<Dispute>,
    trade_id: String,
}

impl DisputeStream {
    /// Poll for the next dispute update matching this trade.
    ///
    /// `RecvError::Lagged` is handled gracefully: dropped messages are skipped
    /// and the loop continues rather than terminating the stream.
    pub async fn next(&mut self) -> Result<Dispute> {
        loop {
            match self.rx.recv().await {
                Ok(dispute) if dispute.trade_id == self.trade_id => return Ok(dispute),
                Ok(_) => continue, // different trade — keep waiting
                Err(RecvError::Lagged(_)) => continue, // missed messages; keep going
                Err(RecvError::Closed) => bail!("DisputeStream closed: channel sender dropped"),
            }
        }
    }
}

/// Subscribe to dispute updates for a specific trade.
pub async fn on_dispute_updated(trade_id: String) -> Result<DisputeStream> {
    let rx = dispute_store().update_tx.subscribe();
    Ok(DisputeStream { rx, trade_id })
}

// ── Tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    /// Insert a dispute directly into the store, bypassing dispatch.
    ///
    /// Used in unit tests that exercise store operations (admin events,
    /// evidence validation, etc.) without needing a live relay or trade key.
    async fn seed_dispute(trade_id: &str, reason: Option<String>) -> Dispute {
        let dispute = Dispute {
            id: uuid::Uuid::new_v4().to_string(),
            trade_id: trade_id.to_string(),
            status: DisputeStatus::Open,
            initiated_by_me: true,
            reason,
            admin_pubkey: None,
            resolution: None,
            opened_at: unix_now(),
            resolved_at: None,
            is_read: true,
        };
        dispute_store()
            .try_insert_if_absent_or_resolved(dispute)
            .await
            .expect("seed_dispute: insert failed")
    }

    #[tokio::test]
    async fn open_dispute_requires_trade_key() {
        // open_dispute now dispatches to Mostro before persisting; without a
        // trade key it must return TradeNotDisputable rather than silently
        // storing a local-only dispute that the daemon never received.
        let trade_id = format!("t-{}", uuid::Uuid::new_v4());
        let err = open_dispute(trade_id, Some("Price disagreement".into()))
            .await
            .unwrap_err();
        assert!(
            err.to_string().contains("TradeNotDisputable"),
            "expected TradeNotDisputable, got: {err}"
        );
    }

    #[tokio::test]
    async fn dispute_store_creates_record() {
        let trade_id = format!("t-{}", uuid::Uuid::new_v4());
        let dispute = seed_dispute(&trade_id, Some("Price disagreement".into())).await;

        assert_eq!(dispute.trade_id, trade_id);
        assert_eq!(dispute.status, DisputeStatus::Open);
        assert!(dispute.initiated_by_me);
        assert_eq!(dispute.reason.as_deref(), Some("Price disagreement"));
    }

    #[tokio::test]
    async fn duplicate_dispute_is_rejected() {
        let trade_id = format!("t-{}", uuid::Uuid::new_v4());
        seed_dispute(&trade_id, None).await;

        // Second insert into the same trade must fail.
        let dispute = Dispute {
            id: uuid::Uuid::new_v4().to_string(),
            trade_id: trade_id.clone(),
            status: DisputeStatus::Open,
            initiated_by_me: true,
            reason: None,
            admin_pubkey: None,
            resolution: None,
            opened_at: unix_now(),
            resolved_at: None,
            is_read: true,
        };
        let err = dispute_store()
            .try_insert_if_absent_or_resolved(dispute)
            .await
            .unwrap_err();
        assert!(err.to_string().contains("DisputeAlreadyOpen"));
    }

    /// PR #254 review (ermeme): the record commits InReview before key
    /// derivation and listener startup, which can fail transiently. A
    /// replayed assignment for the same solver is the retry path and must
    /// succeed instead of being rejected as InvalidState.
    #[tokio::test]
    async fn a_same_solver_assignment_replay_is_idempotent() {
        let trade_id = format!("t-{}", uuid::Uuid::new_v4());
        let admin_pk = "0000000000000000000000000000000000000000000000000000000000000005";
        seed_dispute(&trade_id, None).await;

        handle_admin_took_dispute(trade_id.clone(), admin_pk.to_string())
            .await
            .unwrap();
        // The replay (daemon resend / reconnect backfill) must be accepted.
        handle_admin_took_dispute(trade_id.clone(), admin_pk.to_string())
            .await
            .expect("same-solver replay must be an idempotent retry");

        let d = get_dispute(trade_id).await.unwrap().unwrap();
        assert_eq!(d.status, DisputeStatus::InReview);
        assert_eq!(d.admin_pubkey.as_deref(), Some(admin_pk));
    }

    #[tokio::test]
    async fn empty_evidence_is_rejected() {
        let trade_id = format!("t-{}", uuid::Uuid::new_v4());
        seed_dispute(&trade_id, None).await;

        let err = submit_evidence(trade_id, "  ".into()).await.unwrap_err();
        assert!(err.to_string().contains("EvidenceEmpty"));
    }

    #[tokio::test]
    async fn a_peer_opened_dispute_still_records_the_solver() {
        // The party that did not open the dispute has no local record when
        // `admin-took-dispute` arrives. Dropping it there would lose the only
        // pubkey that can establish the dispute chat.
        let trade_id = format!("t-{}", uuid::Uuid::new_v4());
        let admin_pk = "0000000000000000000000000000000000000000000000000000000000000002";

        assert!(get_dispute(trade_id.clone()).await.unwrap().is_none());

        handle_admin_took_dispute(trade_id.clone(), admin_pk.to_string())
            .await
            .unwrap();

        let dispute = get_dispute(trade_id).await.unwrap().expect("record created");
        assert_eq!(dispute.admin_pubkey.as_deref(), Some(admin_pk));
        assert_eq!(dispute.status, DisputeStatus::InReview);
        assert!(!dispute.initiated_by_me);
        assert!(!dispute.is_read, "a new solver assignment is unread");
    }

    #[tokio::test]
    async fn submit_evidence_fails_without_admin() {
        let trade_id = format!("t-{}", uuid::Uuid::new_v4());
        seed_dispute(&trade_id, None).await;

        // Dispute is Open but no admin assigned yet — must fail with AdminNotAssigned
        let err = submit_evidence(trade_id, "my evidence text".into())
            .await
            .unwrap_err();
        assert!(
            err.to_string().contains("AdminNotAssigned"),
            "expected AdminNotAssigned, got: {err}"
        );
    }

    #[tokio::test]
    async fn key_derivation_failure_does_not_block_dispute_status_update() {
        // Verifies the best-effort contract: even when adminSharedKey derivation
        // fails (here because there is no registered trade key for this trade_id,
        // so `trade_key_for_order` returns None), the function must still:
        //   1. Return Ok(())
        //   2. Set the dispute status to InReview
        //   3. Store the admin pubkey
        //
        // The derivation failure path reached here is "no trade key" (the most
        // common failure mode in tests). In production the equivalent happens
        // when the session has been cleaned up before adminTookDispute arrives.
        // The important invariant is that the store update is never rolled back
        // by a derivation error.
        let trade_id = format!("t-{}", uuid::Uuid::new_v4());
        seed_dispute(&trade_id, None).await;
        // Generator point G — a known valid secp256k1 pubkey.
        let fake_admin_pk =
            "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798";
        // No trade key registered for trade_id → trade_key_for_order returns
        // None → derivation returns Err → logged as warning, not propagated.
        let result = handle_admin_took_dispute(trade_id.clone(), fake_admin_pk.into()).await;
        assert!(result.is_ok(), "expected Ok(()) despite derivation failure, got: {:?}", result);

        let d = get_dispute(trade_id).await.unwrap().unwrap();
        assert_eq!(d.status, DisputeStatus::InReview, "dispute must be InReview after admin took it");
        assert_eq!(d.admin_pubkey.as_deref(), Some(fake_admin_pk), "admin pubkey must be stored");
    }

    #[tokio::test]
    async fn admin_took_dispute_sets_in_review() {
        let trade_id = format!("t-{}", uuid::Uuid::new_v4());
        seed_dispute(&trade_id, None).await;

        // "adminpubkey123" is intentionally invalid hex — this test only checks
        // that the dispute store is updated correctly (status → InReview,
        // admin_pubkey stored). ECDH key derivation will fail silently
        // (best-effort, logged as warning) because the string is not a valid
        // secp256k1 pubkey. That is acceptable here.
        handle_admin_took_dispute(trade_id.clone(), "adminpubkey123".into())
            .await
            .unwrap();

        let d = get_dispute(trade_id).await.unwrap().unwrap();
        assert_eq!(d.status, DisputeStatus::InReview);
        assert_eq!(d.admin_pubkey.as_deref(), Some("adminpubkey123"));
    }

    #[tokio::test]
    async fn admin_settled_resolves_dispute() {
        let trade_id = format!("t-{}", uuid::Uuid::new_v4());
        seed_dispute(&trade_id, None).await;

        handle_admin_settled(trade_id.clone()).await.unwrap();

        let d = get_dispute(trade_id).await.unwrap().unwrap();
        assert_eq!(d.status, DisputeStatus::Resolved);
        assert_eq!(d.resolution, Some(DisputeResolution::FundsToBuyer));
        assert!(d.resolved_at.is_some());
    }
}

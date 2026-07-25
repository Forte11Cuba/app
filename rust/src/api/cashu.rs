//! Cashu wallet surface for the UI — phase C2 of `docs/cashu/README.md`.
//!
//! Holds the single process-wide wallet, gates every entry point on the escrow
//! mode, and broadcasts changes so the UI never polls.
//!
//! **Nothing here runs on a Lightning node.** Every function returns
//! `CashuNotEnabled` unless [`crate::mostro::escrow_mode::is_cashu_mode`] is
//! true, which requires the active node to have advertised Cashu *and* a usable
//! mint. That gate is the whole reason this module is inert by default.
//!
//! Errors are stable markers (`CashuNotEnabled`, `CashuNotConnected`,
//! `CashuMintUnreachable`, …); Dart maps them to localized strings.

use anyhow::{bail, Result};
use std::sync::OnceLock;
use tokio::sync::broadcast::error::RecvError;
use tokio::sync::{broadcast, RwLock};

use crate::api::types::CashuWalletStatus;
use crate::cashu::CashuWallet;
use crate::mostro::escrow_mode;

// ── Global wallet ─────────────────────────────────────────────────────────────

fn wallet_lock() -> &'static RwLock<Option<CashuWallet>> {
    static WALLET: OnceLock<RwLock<Option<CashuWallet>>> = OnceLock::new();
    WALLET.get_or_init(|| RwLock::new(None))
}

fn changes() -> &'static broadcast::Sender<CashuWalletStatus> {
    static CHANGES: OnceLock<broadcast::Sender<CashuWalletStatus>> = OnceLock::new();
    CHANGES.get_or_init(|| broadcast::channel(32).0)
}

/// Where the proof store lives: a sibling of the app database, never inside it.
///
/// `cdk` owns that file's schema and migrations; mixing it into the app's would
/// put two migration systems on one file.
fn proof_store_path() -> Result<String> {
    let app_db = crate::db::app_db::app_db_path()
        .ok_or_else(|| anyhow::anyhow!("CashuStoreUnavailable: database not initialised"))?;

    // `init_db`'s argument is a filesystem path on native and an IndexedDB
    // *database name* on web. A name has no parent, and joining onto `""` would
    // silently produce a relative file next to the process's cwd — so the two
    // cases are separated rather than left to `Path` semantics.
    let parent = std::path::Path::new(app_db)
        .parent()
        .filter(|p| !p.as_os_str().is_empty());

    Ok(match parent {
        Some(dir) => dir.join("cashu.sqlite").to_string_lossy().into_owned(),
        None => "cashu.sqlite".to_string(),
    })
}

/// Fail closed unless the active node was positively identified as Cashu.
fn ensure_enabled() -> Result<()> {
    if !escrow_mode::is_cashu_mode() {
        bail!("CashuNotEnabled");
    }
    Ok(())
}

async fn snapshot() -> CashuWalletStatus {
    let guard = wallet_lock().read().await;
    match guard.as_ref() {
        Some(wallet) => CashuWalletStatus {
            connected: true,
            mint_url: Some(wallet.mint_url().to_string()),
            // A failed read reports `None`, never zero. The wallet is still
            // connected and the next event will carry the real figure, but in
            // the meantime the UI must say "unknown" rather than name a number
            // that would read as "your money is gone".
            balance_sats: match wallet.balance().await {
                Ok(balance) => Some(balance),
                Err(e) => {
                    log::warn!("[cashu] balance read failed: {e}");
                    None
                }
            },
            missing_capabilities: wallet
                .capabilities()
                .missing()
                .into_iter()
                .map(str::to_string)
                .collect(),
        },
        None => CashuWalletStatus {
            connected: false,
            mint_url: None,
            // Not connected is a known state, and a wallet with no binding
            // genuinely holds nothing spendable here.
            balance_sats: Some(0),
            missing_capabilities: Vec::new(),
        },
    }
}

async fn notify() {
    let _ = changes().send(snapshot().await);
}

// ── Public API ────────────────────────────────────────────────────────────────

/// Connect the wallet to the mint the active node pins, unless already connected.
///
/// Lazy by design: nothing connects at startup, so a Lightning user never opens
/// a proof store or contacts a mint. Repeat calls are cheap — an already
/// connected wallet is returned as is rather than reconnected.
///
/// **Errors**: `CashuNotEnabled` when the node is not a usable Cashu node,
/// `NoIdentity` before an identity is loaded, plus the markers from
/// [`CashuWallet::connect`].
pub async fn cashu_connect() -> Result<CashuWalletStatus> {
    ensure_enabled()?;

    // One connect at a time. Without this, two callers both miss the check
    // below, both open the proof store on the same file and both make the mint
    // round trip, and one of the wallets is then thrown away.
    static CONNECTING: OnceLock<tokio::sync::Mutex<()>> = OnceLock::new();
    let _connecting = CONNECTING
        .get_or_init(|| tokio::sync::Mutex::new(()))
        .lock()
        .await;

    {
        let guard = wallet_lock().read().await;
        if guard.is_some() {
            drop(guard);
            return Ok(snapshot().await);
        }
    }

    // The gate above implies a mint URL, but a concurrent node switch could
    // have cleared it — handled rather than unwrapped.
    let mint_url = escrow_mode::get_resolved()
        .config
        .mint_url
        .ok_or_else(|| anyhow::anyhow!("CashuNotEnabled"))?;

    let seed = crate::api::identity::current_bip39_seed()
        .await
        .ok_or_else(|| anyhow::anyhow!("NoIdentity"))?;

    let db_path = proof_store_path()?;
    let wallet = CashuWallet::connect(&mint_url, seed, &db_path).await?;

    {
        let mut guard = wallet_lock().write().await;
        // The connect mutex above makes this the only writer, but a
        // `cashu_disconnect` could have run in between; treat a live wallet as
        // authoritative rather than replacing it.
        if guard.is_none() {
            *guard = Some(wallet);
        }
    }

    notify().await;
    Ok(snapshot().await)
}

/// Current wallet status. Safe to call on any node — a Lightning node simply
/// reports "not connected".
pub async fn cashu_status() -> Result<CashuWalletStatus> {
    Ok(snapshot().await)
}

/// Spendable balance in satoshis.
///
/// **Errors**: `CashuNotEnabled`, `CashuNotConnected`.
pub async fn cashu_get_balance() -> Result<u64> {
    ensure_enabled()?;
    let guard = wallet_lock().read().await;
    let wallet = guard
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("CashuNotConnected"))?;
    wallet.balance().await
}

/// Redeem an encoded Cashu token into the wallet, returning the amount received.
///
/// **Errors**: `CashuNotEnabled`, `CashuNotConnected`, `CashuReceiveFailed`
/// (wrong mint, already spent, malformed).
pub async fn cashu_receive_token(encoded: String) -> Result<u64> {
    ensure_enabled()?;
    let amount = {
        let guard = wallet_lock().read().await;
        let wallet = guard
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("CashuNotConnected"))?;
        wallet.receive_token(&encoded).await?
    };
    notify().await;
    Ok(amount)
}

/// Export `amount_sats` from the wallet as an encoded token.
///
/// **Errors**: `CashuNotEnabled`, `CashuNotConnected`, `CashuAmountZero`,
/// `CashuSendFailed` (insufficient funds included).
pub async fn cashu_create_token(amount_sats: u64) -> Result<String> {
    ensure_enabled()?;
    let token = {
        let guard = wallet_lock().read().await;
        let wallet = guard
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("CashuNotConnected"))?;
        wallet.create_token(amount_sats).await?
    };
    notify().await;
    Ok(token)
}

/// Reconcile pending proofs with the mint, returning the amount reclaimed.
///
/// **Errors**: `CashuNotEnabled`, `CashuNotConnected`.
pub async fn cashu_check_proofs_state() -> Result<u64> {
    ensure_enabled()?;
    let reclaimed = {
        let guard = wallet_lock().read().await;
        let wallet = guard
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("CashuNotConnected"))?;
        wallet.check_proofs_state().await?
    };
    if reclaimed > 0 {
        notify().await;
    }
    Ok(reclaimed)
}

/// Drop the in-memory wallet. Proofs stay on disk — this is a disconnect, not a
/// wipe. Called when the active node changes, so a wallet bound to one node's
/// mint never serves another's.
pub async fn cashu_disconnect() -> Result<()> {
    {
        let mut guard = wallet_lock().write().await;
        *guard = None;
    }
    notify().await;
    Ok(())
}

// ── Stream ────────────────────────────────────────────────────────────────────

/// Emits the wallet status whenever it changes: connect, receive, send, reclaim
/// or disconnect.
pub struct CashuWalletStream {
    rx: broadcast::Receiver<CashuWalletStatus>,
}

impl CashuWalletStream {
    /// Poll for the next wallet-changed event.
    ///
    /// A lagged receiver skips dropped snapshots: the value is current state,
    /// so only the newest one matters.
    pub async fn next(&mut self) -> Result<CashuWalletStatus> {
        loop {
            match self.rx.recv().await {
                Ok(status) => return Ok(status),
                Err(RecvError::Lagged(_)) => continue,
                Err(RecvError::Closed) => bail!("CashuWalletStream closed"),
            }
        }
    }
}

/// Subscribe to wallet changes.
pub fn on_cashu_wallet_changed() -> CashuWalletStream {
    CashuWalletStream {
        rx: changes().subscribe(),
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    /// The escrow globals are process-wide; serialize the tests that read them
    /// and start from a node that has advertised nothing.
    fn escrow_lock() -> std::sync::MutexGuard<'static, ()> {
        static LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
        let guard = LOCK.lock().unwrap_or_else(|e| e.into_inner());
        escrow_mode::clear();
        guard
    }

    #[tokio::test]
    async fn every_entry_point_is_shut_on_a_lightning_node() {
        // Arrange — the default state: nothing fetched, so not Cashu.
        let _g = escrow_lock();

        // Act / Assert — the gate is the whole safety story, so check every
        // door rather than trusting one of them.
        for err in [
            cashu_connect().await.unwrap_err(),
            cashu_get_balance().await.unwrap_err(),
            cashu_receive_token("cashuBanything".to_string())
                .await
                .unwrap_err(),
            cashu_create_token(1).await.unwrap_err(),
            cashu_check_proofs_state().await.unwrap_err(),
        ] {
            assert!(
                err.to_string().contains("CashuNotEnabled"),
                "expected the gate to close, got {err}"
            );
        }
    }

    #[tokio::test]
    async fn status_is_answerable_on_any_node_and_reports_disconnected() {
        // Arrange
        let _g = escrow_lock();

        // Act — status is deliberately ungated: the UI asks before it knows
        // anything, and "not connected" is truthful everywhere.
        let status = cashu_status().await.unwrap();

        // Assert — a disconnected wallet holds nothing, and that is a *known*
        // zero rather than an unreadable balance.
        assert!(!status.connected);
        assert_eq!(status.balance_sats, Some(0));
        assert_eq!(status.mint_url, None);
    }

    #[tokio::test]
    async fn disconnect_is_idempotent_and_notifies() {
        // Arrange
        let _g = escrow_lock();
        let mut stream = on_cashu_wallet_changed();

        // Act — disconnecting a wallet that never existed must not error: this
        // runs on every node switch.
        cashu_disconnect().await.unwrap();

        // Assert
        let status = stream.next().await.unwrap();
        assert!(!status.connected);
    }

    #[test]
    fn the_proof_store_needs_an_initialised_database() {
        // Arrange / Act — with no app DB there is nowhere to put the store,
        // and guessing a path would create one the user never sees.
        let err = proof_store_path().unwrap_err();

        // Assert
        assert!(
            err.to_string().contains("CashuStoreUnavailable"),
            "got {err}"
        );
    }
}

/// Relay pool — manages connections to Nostr relays.
///
/// Subscribes to:
///   - Kind 38383 (public order book, `s=Pending` tag)
///   - Kind 14 (protocol-v2 NIP-44 direct Mostro replies, authored by the
///     node and p-tagged to our trade keys)
///
/// Connection state is derived: Online if ≥1 relay connected,
/// Reconnecting if attempting, Offline otherwise.
use anyhow::{anyhow, Result};
use nostr_sdk::prelude::*;
// The SDK re-exports its own `RelayStatus` via the prelude. Alias it to avoid
// conflicting with our internal `RelayStatus` from `crate::api::types`.
use nostr_sdk::prelude::RelayStatus as SdkRelayStatus;
use std::collections::HashSet;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::{broadcast, RwLock};

use crate::api::types::{ConnectionState, RelayInfo, RelaySource, RelayStatus};

/// How often the background task polls each relay's SDK status (seconds).
const STATUS_POLL_INTERVAL_SECS: u64 = 2;

/// Shared relay pool state.
pub struct RelayPool {
    client: Arc<Client>,
    relays: Arc<RwLock<Vec<RelayInfo>>>,
    /// Relays the user removed after a Mostro node announced them. A node's
    /// kind 10002 list is re-applied on every reconnect and node switch, so
    /// without this the removed relay would come straight back.
    blacklist: RwLock<HashSet<String>>,
    conn_tx: broadcast::Sender<ConnectionState>,
    relay_tx: broadcast::Sender<RelayInfo>,
}

impl RelayPool {
    /// Create a new pool with the given relay URLs.
    pub async fn new(relay_urls: Vec<String>) -> Result<Arc<Self>> {
        // No signer: every event this pool sends is signed by the caller
        // with the trade or chat key it belongs to.
        let client = Arc::new(Client::new());

        let (conn_tx, _) = broadcast::channel(16);
        let (relay_tx, _) = broadcast::channel(64);

        let pool = Arc::new(Self {
            client: client.clone(),
            relays: Arc::new(RwLock::new(Vec::new())),
            blacklist: RwLock::new(HashSet::new()),
            conn_tx,
            relay_tx,
        });

        for url in relay_urls {
            pool.add_relay_internal(&url, RelaySource::Default).await?;
        }

        client.connect().await;

        // Give the SDK a moment to initiate WebSocket handshakes before the
        // first status poll.  Without this the initial broadcast is always
        // Reconnecting (every relay is still in Pending/Connecting state).
        crate::rt::time::sleep(Duration::from_millis(500)).await;

        // Broadcast initial connection state after all relays are wired up.
        pool.broadcast_connection_state().await;

        pool.spawn_status_monitor();
        Ok(pool)
    }

    async fn add_relay_internal(&self, url: &str, source: RelaySource) -> Result<RelayInfo> {
        self.client
            .add_relay(url)
            .await
            .map_err(|e| anyhow!("add relay failed: {e}"))?;
        // `add_relay` only registers the relay; the SDK connects nothing on
        // its own. During construction `new()` calls `connect()` for the
        // whole set afterwards, but a relay added to a running pool — by the
        // user or from a node's relay list — would otherwise sit in
        // `Initialized` forever. `connect_relay` is non-blocking.
        if let Err(e) = self.client.connect_relay(url).await {
            log::warn!(
                "[relay] connect {} not started: {e}",
                crate::api::logging::display_relay(url)
            );
        }

        let info = RelayInfo {
            url: url.to_string(),
            is_active: true,
            is_default: matches!(source, RelaySource::Default),
            source,
            is_blacklisted: false,
            status: RelayStatus::Connecting,
            last_connected_at: None,
            last_error: None,
        };

        self.relays.write().await.push(info.clone());
        let _ = self.relay_tx.send(info.clone());
        self.broadcast_connection_state().await;
        Ok(info)
    }

    /// Add a relay and connect to it.
    ///
    /// An explicit add lifts the relay off the blacklist: the user asking
    /// for it back overrides their earlier removal.
    pub async fn add_relay(&self, url: &str) -> Result<RelayInfo> {
        let relays = self.relays.read().await;
        if relays.iter().any(|r| r.url == url) {
            return Err(anyhow!("RelayAlreadyExists"));
        }
        drop(relays);
        self.blacklist.write().await.remove(url);
        self.add_relay_internal(url, RelaySource::UserAdded).await
    }

    /// Remove a relay and disconnect.
    ///
    /// Removing a node-announced relay blacklists it (see `blacklist`), so
    /// the next relay-list sync leaves it out. Defaults and user-added relays
    /// are not blacklisted: they only come back if the user re-adds them.
    pub async fn remove_relay(&self, url: &str) -> Result<()> {
        let mut relays = self.relays.write().await;
        let active_count = relays.iter().filter(|r| r.is_active).count();
        if active_count <= 1 {
            return Err(anyhow!("LastRelay"));
        }
        let pos = relays
            .iter()
            .position(|r| r.url == url)
            .ok_or_else(|| anyhow!("RelayNotFound"))?;
        let mut removed = relays.remove(pos);
        removed.status = RelayStatus::Disconnected;
        drop(relays);

        if matches!(removed.source, RelaySource::MostroDiscovered) {
            self.blacklist.write().await.insert(url.to_string());
        }

        self.client
            .remove_relay(url)
            .await
            .map_err(|e| anyhow!("remove relay failed: {e}"))?;

        let _ = self.relay_tx.send(removed);
        self.broadcast_connection_state().await;
        Ok(())
    }

    /// Seed the blacklist (e.g. from persisted state) before the first sync.
    pub async fn set_blacklist(&self, urls: impl IntoIterator<Item = String>) {
        *self.blacklist.write().await = urls.into_iter().collect();
    }

    /// Re-apply what a previous session persisted: the source/default flags
    /// of relays this pool was constructed with (construction marks them all
    /// `Default`), and the blacklist. Rows for relays not in the pool are
    /// only consulted for the blacklist.
    pub async fn restore_persisted(&self, persisted: &[RelayInfo]) {
        {
            let mut relays = self.relays.write().await;
            for row in persisted.iter().filter(|r| !r.is_blacklisted) {
                if let Some(info) = relays.iter_mut().find(|r| r.url == row.url) {
                    info.source = row.source.clone();
                    info.is_default = row.is_default;
                }
            }
        }
        self.set_blacklist(
            persisted
                .iter()
                .filter(|r| r.is_blacklisted)
                .map(|r| r.url.clone()),
        )
        .await;
    }

    /// Relays the user removed after a node announced them.
    pub async fn blacklist(&self) -> Vec<String> {
        let mut urls: Vec<String> = self.blacklist.read().await.iter().cloned().collect();
        urls.sort();
        urls
    }

    /// Apply a Mostro node's announced relay list. **Additive only**: relays
    /// already configured are left alone (whatever their source), blacklisted
    /// ones are skipped, and nothing is ever disconnected — a node that
    /// drops a relay from its list does not take it away from the user.
    /// Returns the URLs that were newly added, in announcement order.
    pub async fn sync_discovered(&self, announced: &[String]) -> Vec<String> {
        let to_add = {
            let relays = self.relays.read().await;
            let blacklist = self.blacklist.read().await;
            plan_relay_sync(&relays, announced, &blacklist)
        };
        let mut added = Vec::with_capacity(to_add.len());
        for url in to_add {
            match self.add_relay_internal(&url, RelaySource::MostroDiscovered).await {
                Ok(_) => added.push(url),
                Err(e) => log::warn!(
                    "[relay] discovered relay {} not added: {e}",
                    crate::api::logging::display_relay(&url)
                ),
            }
        }
        added
    }

    pub async fn get_relays(&self) -> Vec<RelayInfo> {
        self.relays.read().await.clone()
    }

    pub async fn connection_state(&self) -> ConnectionState {
        derive_connection_state(&self.relays.read().await)
    }

    pub fn subscribe_connection_state(&self) -> broadcast::Receiver<ConnectionState> {
        self.conn_tx.subscribe()
    }

    pub fn subscribe_relay_status(&self) -> broadcast::Receiver<RelayInfo> {
        self.relay_tx.subscribe()
    }

    pub fn client(&self) -> Arc<Client> {
        self.client.clone()
    }

    // ── Internal helpers ──────────────────────────────────────────────────────

    async fn broadcast_connection_state(&self) {
        let state = derive_connection_state(&self.relays.read().await);
        let _ = self.conn_tx.send(state);
    }

    /// Spawn a background task that polls each relay's SDK status every
    /// `STATUS_POLL_INTERVAL_SECS` seconds and broadcasts changes on
    /// `relay_tx` / `conn_tx` when a relay transitions between states.
    ///
    /// `ClientNotification` in nostr-sdk 0.45 carries only `Event`, `Message`
    /// and `Shutdown` — no relay-level status transitions — so polling
    /// `client.relay(url).status()` remains the available mechanism. (Was
    /// `RelayPoolNotification` before 0.45; re-checked on the bump, unchanged.)
    fn spawn_status_monitor(self: &Arc<Self>) {
        let client = self.client.clone();
        let relays = self.relays.clone();
        let conn_tx = self.conn_tx.clone();
        let relay_tx = self.relay_tx.clone();

        crate::rt::spawn(async move {
            loop {
                crate::rt::time::sleep(Duration::from_secs(STATUS_POLL_INTERVAL_SECS)).await;

                let relay_urls: Vec<String> =
                    relays.read().await.iter().map(|r| r.url.clone()).collect();

                let mut any_changed = false;

                for url in relay_urls {
                    let Ok(Some(sdk_relay)) = client.relay(&url).await else {
                        continue;
                    };
                    let new_status = map_sdk_status(sdk_relay.status());

                    let mut relays_w = relays.write().await;
                    if let Some(info) = relays_w.iter_mut().find(|r| r.url == url) {
                        if info.status != new_status {
                            // Gaining/losing a connection is the signal that
                            // matters (INFO); the connecting↔disconnected
                            // retry churn of an unreachable relay stays at
                            // DEBUG so it doesn't drown a shipped build's log.
                            // Host-only display: a user-added relay URL may
                            // carry tokens/userinfo that must not be retained.
                            let line = format!(
                                "relay {} {:?}→{new_status:?}",
                                crate::api::logging::display_relay(&url),
                                info.status,
                            );
                            if matches!(info.status, RelayStatus::Connected)
                                || matches!(new_status, RelayStatus::Connected)
                            {
                                crate::api::logging::blog_info("relay", line);
                            } else {
                                crate::api::logging::blog_debug("relay", line);
                            }
                            info.status = new_status;
                            if matches!(info.status, RelayStatus::Connected) {
                                info.last_connected_at = Some(unix_now());
                            }
                            any_changed = true;
                            let _ = relay_tx.send(info.clone());
                        }
                    }
                    drop(relays_w);
                }

                if any_changed {
                    let state = derive_connection_state(&relays.read().await);
                    let _ = conn_tx.send(state);
                }
            }
        });
    }
}

// ── Pure helpers ──────────────────────────────────────────────────────────────

/// Which of `announced` should be added: not configured yet, not
/// blacklisted, first occurrence only. Order is preserved so the user sees
/// them in the order the node listed them.
fn plan_relay_sync(
    current: &[RelayInfo],
    announced: &[String],
    blacklist: &HashSet<String>,
) -> Vec<String> {
    let mut planned: Vec<String> = Vec::new();
    for url in announced {
        let known = current.iter().any(|r| &r.url == url);
        if known || blacklist.contains(url) || planned.contains(url) {
            continue;
        }
        planned.push(url.clone());
    }
    planned
}

fn derive_connection_state(relays: &[RelayInfo]) -> ConnectionState {
    let any_connected = relays
        .iter()
        .any(|r| matches!(r.status, RelayStatus::Connected));
    let any_connecting = relays
        .iter()
        .any(|r| matches!(r.status, RelayStatus::Connecting));

    if any_connected {
        ConnectionState::Online
    } else if any_connecting {
        ConnectionState::Reconnecting
    } else {
        ConnectionState::Offline
    }
}

/// Map an SDK `RelayStatus` to our internal `RelayStatus`.
fn map_sdk_status(s: SdkRelayStatus) -> RelayStatus {
    match s {
        SdkRelayStatus::Connected => RelayStatus::Connected,
        SdkRelayStatus::Connecting | SdkRelayStatus::Pending => RelayStatus::Connecting,
        SdkRelayStatus::Disconnected
        | SdkRelayStatus::Terminated
        | SdkRelayStatus::Initialized
        | SdkRelayStatus::Sleeping
        | SdkRelayStatus::Shutdown => RelayStatus::Disconnected,
        SdkRelayStatus::Banned => RelayStatus::Error,
    }
}

use crate::rt::unix_now;

#[cfg(test)]
mod tests {
    use super::*;

    fn relay(url: &str, source: RelaySource) -> RelayInfo {
        RelayInfo {
            url: url.to_string(),
            is_active: true,
            is_default: matches!(source, RelaySource::Default),
            source,
            is_blacklisted: false,
            status: RelayStatus::Connected,
            last_connected_at: None,
            last_error: None,
        }
    }

    fn urls(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn sync_plan_adds_only_unknown_relays_in_announcement_order() {
        let current = vec![relay("wss://relay.mostro.network", RelaySource::Default)];
        let announced = urls(&["wss://mostro-p2p.tech", "wss://relay.mostro.network", "wss://nos.lol"]);

        let planned = plan_relay_sync(&current, &announced, &HashSet::new());

        assert_eq!(planned, urls(&["wss://mostro-p2p.tech", "wss://nos.lol"]));
    }

    #[test]
    fn sync_plan_skips_blacklisted_relays() {
        let current = vec![relay("wss://relay.mostro.network", RelaySource::Default)];
        let announced = urls(&["wss://mostro-p2p.tech", "wss://nos.lol"]);
        let blacklist: HashSet<String> = ["wss://nos.lol".to_string()].into_iter().collect();

        let planned = plan_relay_sync(&current, &announced, &blacklist);

        assert_eq!(planned, urls(&["wss://mostro-p2p.tech"]));
    }

    #[test]
    fn sync_plan_never_removes_relays_the_node_stopped_announcing() {
        let current = vec![
            relay("wss://relay.mostro.network", RelaySource::Default),
            relay("wss://old.example", RelaySource::MostroDiscovered),
            relay("wss://mine.example", RelaySource::UserAdded),
        ];
        let announced = urls(&["wss://relay.mostro.network"]);

        let planned = plan_relay_sync(&current, &announced, &HashSet::new());

        assert!(planned.is_empty());
    }

    #[test]
    fn sync_plan_dedupes_repeated_announcements() {
        let announced = urls(&["wss://a.example", "wss://a.example"]);

        let planned = plan_relay_sync(&[], &announced, &HashSet::new());

        assert_eq!(planned, urls(&["wss://a.example"]));
    }

    #[tokio::test]
    async fn removing_a_discovered_relay_blacklists_it_and_re_adding_clears_it() {
        let pool = RelayPool::new(vec!["ws://127.0.0.1:1".to_string()]).await.unwrap();
        let added = pool.sync_discovered(&urls(&["ws://127.0.0.1:2"])).await;
        assert_eq!(added, urls(&["ws://127.0.0.1:2"]));

        pool.remove_relay("ws://127.0.0.1:2").await.unwrap();
        assert_eq!(pool.blacklist().await, urls(&["ws://127.0.0.1:2"]));

        // A later announcement is ignored while blacklisted…
        assert!(pool.sync_discovered(&urls(&["ws://127.0.0.1:2"])).await.is_empty());

        // …until the user explicitly adds the relay back.
        pool.add_relay("ws://127.0.0.1:2").await.unwrap();
        assert!(pool.blacklist().await.is_empty());
        let info = pool.get_relays().await.into_iter().find(|r| r.url == "ws://127.0.0.1:2").unwrap();
        assert!(matches!(info.source, RelaySource::UserAdded));
    }

    #[tokio::test]
    async fn removing_a_default_relay_does_not_blacklist_it() {
        let pool = RelayPool::new(vec!["ws://127.0.0.1:1".to_string(), "ws://127.0.0.1:2".to_string()])
            .await
            .unwrap();

        pool.remove_relay("ws://127.0.0.1:2").await.unwrap();

        assert!(pool.blacklist().await.is_empty());
    }
}

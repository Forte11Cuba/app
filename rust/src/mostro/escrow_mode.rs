//! Which settlement backend the active Mostro node runs — Lightning or Cashu.
//!
//! Phase C1 of `docs/cashu/README.md`. This is the gate every later Cashu phase
//! hangs off: nothing Cashu-shaped may run, and no Cashu UI may appear, unless
//! the active node has been *positively identified* as running Cashu escrow.
//!
//! Same shape as [`crate::mostro::pow`] — a process-global refreshed from the
//! daemon's Kind 38385 info event whenever the relay pool comes online or the
//! active node changes. Unlike PoW this one is tri-state, mirroring
//! `BondPolicy` on the Dart side (`lib/features/about/models/mostro_instance.dart`):
//! an old daemon that predates the tags is [`EscrowMode::Unknown`], which is
//! **not** the same as knowing it speaks Lightning.
//!
//! Fail-safe by construction: [`is_cashu_mode`] is the only way to ask whether
//! Cashu paths may run, and it answers `false` for `Unknown`, for `Lightning`,
//! and for a node that claims Cashu without publishing a usable mint. A node
//! that never answers therefore behaves exactly like today's Lightning-only
//! client.

use std::sync::RwLock;

/// Settlement backend advertised by the active Mostro node.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum EscrowMode {
    /// Info event not fetched yet, unreachable, or a daemon old enough that it
    /// publishes no `escrow_mode` tag. Treated as Lightning everywhere.
    #[default]
    Unknown,
    /// Tag absent or explicitly `"lightning"`.
    Lightning,
    /// Tag `escrow_mode` == `"cashu"`.
    Cashu,
}

impl EscrowMode {
    /// What the node said, nothing more. `Unknown` answers `false`, so the
    /// Cashu paths stay closed unless the node positively said otherwise.
    ///
    /// This is the *mode* question, for the About screen — a node can say
    /// Cashu and still be unusable. To decide whether a Cashu path may run,
    /// ask [`is_cashu_mode`], which also requires a usable mint.
    pub fn is_cashu(self) -> bool {
        matches!(self, EscrowMode::Cashu)
    }

    /// Parse an `escrow_mode` tag value. Anything unrecognised is Lightning:
    /// a daemon advertising a backend we do not implement is one we cannot
    /// trade Cashu with either, and Lightning is the safe reading.
    pub fn from_tag_value(value: &str) -> Self {
        match value.trim().to_ascii_lowercase().as_str() {
            "cashu" => EscrowMode::Cashu,
            _ => EscrowMode::Lightning,
        }
    }

    /// Stable marker for the Dart layer. Rust never returns prose — Dart maps
    /// these to localized strings (repo translation rule).
    pub fn as_marker(self) -> &'static str {
        match self {
            EscrowMode::Unknown => "unknown",
            EscrowMode::Lightning => "lightning",
            EscrowMode::Cashu => "cashu",
        }
    }
}

/// The Cashu parameters a node publishes alongside `escrow_mode`.
///
/// Every field is optional because each tag is independently absent on an old
/// daemon. A `Cashu` mode with no `mint_url` is a misconfigured node, and
/// callers must treat it as unusable rather than guessing a mint — hence
/// [`CashuNodeConfig::is_usable`].
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct CashuNodeConfig {
    /// Mint the node pins for every escrow. There is no per-order negotiation.
    pub mint_url: Option<String>,
    /// NUT-11 locktime the seller must set, in days (daemon default 15).
    pub escrow_locktime_days: Option<u32>,
    /// How close to expiry the daemon stops accepting `fiat-sent`, in days.
    pub settlement_margin_days: Option<u32>,
}

impl CashuNodeConfig {
    /// A Cashu node we can actually trade against needs, at minimum, a mint.
    pub fn is_usable(&self) -> bool {
        self.mint_url.as_deref().is_some_and(|u| !u.trim().is_empty())
    }
}

/// What the client resolved for the active node, override included.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ResolvedEscrowMode {
    pub mode: EscrowMode,
    pub config: CashuNodeConfig,
    /// True when the mode came from the developer override rather than the
    /// node's own tags. Surfaced in the UI so a tester is never fooled into
    /// thinking a Lightning node advertised Cashu.
    pub is_overridden: bool,
}

/// Developer override, for testing against a daemon branch that implements
/// Cashu but does not publish the info tags yet (§4.3).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum EscrowModeOverride {
    /// Trust the node's tags.
    #[default]
    Auto,
    /// Pretend the node advertised Cashu.
    ForceCashu,
}

impl EscrowModeOverride {
    /// Parse the persisted settings value. Unrecognised → `Auto`, so a
    /// corrupted setting can never silently enable Cashu.
    pub fn from_stored(value: &str) -> Self {
        match value.trim().to_ascii_lowercase().as_str() {
            "force_cashu" => EscrowModeOverride::ForceCashu,
            _ => EscrowModeOverride::Auto,
        }
    }

    pub fn as_stored(self) -> &'static str {
        match self {
            EscrowModeOverride::Auto => "auto",
            EscrowModeOverride::ForceCashu => "force_cashu",
        }
    }
}

/// Everything the resolver needs, so resolution itself stays a pure function
/// and can be tested without touching globals or the network.
#[derive(Debug, Clone, Default)]
pub struct EscrowModeInputs {
    /// What the node's 38385 tags said.
    pub from_tags: EscrowMode,
    /// Cashu parameters from the same tags.
    pub tag_config: CashuNodeConfig,
    /// Developer override.
    pub override_mode: EscrowModeOverride,
    /// Mint URL override, used when the node publishes none.
    pub mint_url_override: Option<String>,
}

/// Resolution order from §4.3: `override > 38385 tag > Lightning`.
///
/// The mint URL resolves independently and with the same precedence, because
/// the two overrides serve different gaps: forcing the mode is for a daemon
/// that speaks Cashu without advertising it, while overriding the mint is for
/// pointing a tester at a local nutshell instead of the node's mint.
pub fn resolve(inputs: &EscrowModeInputs) -> ResolvedEscrowMode {
    let overridden = matches!(inputs.override_mode, EscrowModeOverride::ForceCashu);
    let mode = if overridden {
        EscrowMode::Cashu
    } else {
        inputs.from_tags
    };

    let mut config = inputs.tag_config.clone();
    if let Some(url) = inputs
        .mint_url_override
        .as_deref()
        .map(str::trim)
        .filter(|u| !u.is_empty())
    {
        config.mint_url = Some(url.to_string());
    }

    ResolvedEscrowMode {
        mode,
        config,
        is_overridden: overridden,
    }
}

/// Read the `escrow_mode` / `cashu_*` tags out of a Kind 38385 event.
///
/// Tags are `["name", "value"]` pairs; anything malformed is skipped with a
/// warning rather than failing the whole fetch, matching how `fetch_and_set_pow`
/// already treats a bad `pow` value. A node is only reported as Cashu when it
/// says so explicitly.
pub fn parse_tags(tags: &[Vec<String>]) -> (EscrowMode, CashuNodeConfig) {
    let value_of = |name: &str| -> Option<&str> {
        tags.iter()
            .find(|t| t.first().map(String::as_str) == Some(name))
            .and_then(|t| t.get(1))
            .map(String::as_str)
    };

    let mode = match value_of("escrow_mode") {
        Some(v) => EscrowMode::from_tag_value(v),
        // No tag at all: an old daemon. Unknown, not Lightning — the
        // distinction is what lets the UI say "not advertised" honestly.
        None => EscrowMode::Unknown,
    };

    let days = |name: &str| -> Option<u32> {
        let raw = value_of(name)?;
        match raw.trim().parse::<u32>() {
            Ok(d) => Some(d),
            Err(_) => {
                log::warn!("[escrow-mode] malformed {name} tag value: {raw:?} — ignoring");
                None
            }
        }
    };

    let config = CashuNodeConfig {
        mint_url: value_of("cashu_mint_url")
            .map(str::trim)
            .filter(|u| !u.is_empty())
            .map(str::to_string),
        escrow_locktime_days: days("cashu_escrow_locktime_days"),
        settlement_margin_days: days("cashu_settlement_margin_days"),
    };

    (mode, config)
}

// ── Process-global state ────────────────────────────────────────────────────

static RESOLVED: RwLock<Option<ResolvedEscrowMode>> = RwLock::new(None);

/// Replace the resolved mode for the active node.
///
/// A poisoned lock is recovered from rather than propagated: escrow mode is a
/// cache of what the node advertised, and refusing to update it would leave the
/// app pinned to a stale node's mode after any unrelated panic.
pub fn set_resolved(resolved: ResolvedEscrowMode) {
    log::info!(
        "[escrow-mode] active node resolved to {} (overridden={}, mint={:?})",
        resolved.mode.as_marker(),
        resolved.is_overridden,
        resolved.config.mint_url,
    );
    let mut guard = RESOLVED.write().unwrap_or_else(|e| e.into_inner());
    *guard = Some(resolved);
}

/// Current resolution, or the `Unknown` default before the first fetch.
pub fn get_resolved() -> ResolvedEscrowMode {
    RESOLVED
        .read()
        .unwrap_or_else(|e| e.into_inner())
        .clone()
        .unwrap_or_default()
}

/// Forget the cached mode. Called when the active node changes, so a stale
/// Cashu resolution can never leak onto a different node between the switch
/// and the next successful fetch.
pub fn clear() {
    let mut guard = RESOLVED.write().unwrap_or_else(|e| e.into_inner());
    *guard = None;
}

/// The one question the rest of the app asks: may a Cashu path run against the
/// active node?
///
/// Deliberately stricter than [`EscrowMode::is_cashu`]. A node that advertises
/// `escrow_mode=cashu` but publishes no mint URL is misconfigured, and there is
/// nothing to connect to — enabling Cashu routing or UI for it would only fail
/// later and further from the cause. The gate therefore also requires
/// [`CashuNodeConfig::is_usable`], and the mint override (§4.3) is what makes a
/// forced Cashu mode usable against a daemon that publishes no mint of its own.
///
/// The About screen must *not* use this: it reads [`get_resolved`], so it can
/// say "cashu, but no mint advertised" instead of silently reading Lightning.
pub fn is_cashu_mode() -> bool {
    let resolved = get_resolved();
    resolved.mode.is_cashu() && resolved.config.is_usable()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tag(name: &str, value: &str) -> Vec<String> {
        vec![name.to_string(), value.to_string()]
    }

    /// Tests that touch `RESOLVED` run in the same process and would otherwise
    /// race each other. A poisoned lock is recovered from so one failing test
    /// does not cascade into the others.
    static GLOBAL: std::sync::Mutex<()> = std::sync::Mutex::new(());

    fn own_the_global() -> std::sync::MutexGuard<'static, ()> {
        GLOBAL.lock().unwrap_or_else(|e| e.into_inner())
    }

    #[test]
    fn a_daemon_without_the_tag_is_unknown_not_lightning() {
        // Arrange — today's daemons: pow and bond tags, nothing about escrow.
        let tags = vec![tag("pow", "8"), tag("bond", "enabled")];

        // Act
        let (mode, config) = parse_tags(&tags);

        // Assert — Unknown is what lets the About screen say "not advertised"
        // instead of claiming the node confirmed Lightning.
        assert_eq!(mode, EscrowMode::Unknown);
        assert!(!mode.is_cashu());
        assert_eq!(config, CashuNodeConfig::default());
    }

    #[test]
    fn unknown_and_lightning_both_keep_cashu_closed() {
        // Assert — the fail-safe the whole feature rests on.
        assert!(!EscrowMode::Unknown.is_cashu());
        assert!(!EscrowMode::Lightning.is_cashu());
        assert!(EscrowMode::Cashu.is_cashu());
    }

    #[test]
    fn a_cashu_node_is_parsed_with_its_parameters() {
        // Arrange
        let tags = vec![
            tag("escrow_mode", "cashu"),
            tag("cashu_mint_url", "https://mint.example.com"),
            tag("cashu_escrow_locktime_days", "15"),
            tag("cashu_settlement_margin_days", "3"),
        ];

        // Act
        let (mode, config) = parse_tags(&tags);

        // Assert
        assert_eq!(mode, EscrowMode::Cashu);
        assert_eq!(config.mint_url.as_deref(), Some("https://mint.example.com"));
        assert_eq!(config.escrow_locktime_days, Some(15));
        assert_eq!(config.settlement_margin_days, Some(3));
        assert!(config.is_usable());
    }

    #[test]
    fn an_explicit_lightning_tag_is_lightning() {
        // Arrange / Act
        let (mode, _) = parse_tags(&[tag("escrow_mode", "lightning")]);

        // Assert
        assert_eq!(mode, EscrowMode::Lightning);
    }

    #[test]
    fn an_unrecognised_backend_reads_as_lightning() {
        // Arrange — a future backend this client does not implement.
        let (mode, _) = parse_tags(&[tag("escrow_mode", "fedimint")]);

        // Assert — we cannot trade Cashu with it, so the safe reading is the
        // one that leaves every Cashu path shut.
        assert_eq!(mode, EscrowMode::Lightning);
        assert!(!mode.is_cashu());
    }

    #[test]
    fn tag_values_are_matched_case_insensitively_and_trimmed() {
        // Arrange / Act
        let (mode, _) = parse_tags(&[tag("escrow_mode", "  Cashu ")]);

        // Assert
        assert_eq!(mode, EscrowMode::Cashu);
    }

    #[test]
    fn malformed_day_counts_are_dropped_not_fatal() {
        // Arrange — a garbage locktime must not cost us the mint URL.
        let tags = vec![
            tag("escrow_mode", "cashu"),
            tag("cashu_mint_url", "https://mint.example.com"),
            tag("cashu_escrow_locktime_days", "fifteen"),
        ];

        // Act
        let (mode, config) = parse_tags(&tags);

        // Assert
        assert_eq!(mode, EscrowMode::Cashu);
        assert_eq!(config.escrow_locktime_days, None);
        assert_eq!(config.mint_url.as_deref(), Some("https://mint.example.com"));
    }

    #[test]
    fn an_empty_mint_url_is_not_a_mint_url() {
        // Arrange — a node that publishes the tag but leaves it blank.
        let tags = vec![tag("escrow_mode", "cashu"), tag("cashu_mint_url", "   ")];

        // Act
        let (_, config) = parse_tags(&tags);

        // Assert — is_usable() is what stops us from trying to reach "".
        assert_eq!(config.mint_url, None);
        assert!(!config.is_usable());
    }

    #[test]
    fn resolution_prefers_the_override_over_the_tags() {
        // Arrange — a Lightning node plus a tester forcing Cashu (§4.3).
        let inputs = EscrowModeInputs {
            from_tags: EscrowMode::Lightning,
            override_mode: EscrowModeOverride::ForceCashu,
            mint_url_override: Some("http://localhost:3338".to_string()),
            ..Default::default()
        };

        // Act
        let resolved = resolve(&inputs);

        // Assert
        assert_eq!(resolved.mode, EscrowMode::Cashu);
        assert!(resolved.is_overridden);
        assert_eq!(
            resolved.config.mint_url.as_deref(),
            Some("http://localhost:3338")
        );
    }

    #[test]
    fn without_an_override_the_tags_decide_and_nothing_is_flagged() {
        // Arrange
        let inputs = EscrowModeInputs {
            from_tags: EscrowMode::Cashu,
            tag_config: CashuNodeConfig {
                mint_url: Some("https://mint.example.com".to_string()),
                escrow_locktime_days: Some(15),
                settlement_margin_days: Some(3),
            },
            ..Default::default()
        };

        // Act
        let resolved = resolve(&inputs);

        // Assert — is_overridden drives the "this is forced" UI hint.
        assert_eq!(resolved.mode, EscrowMode::Cashu);
        assert!(!resolved.is_overridden);
        assert_eq!(
            resolved.config.mint_url.as_deref(),
            Some("https://mint.example.com")
        );
    }

    #[test]
    fn the_mint_override_wins_even_when_the_node_published_one() {
        // Arrange — pointing a tester at a local nutshell.
        let inputs = EscrowModeInputs {
            from_tags: EscrowMode::Cashu,
            tag_config: CashuNodeConfig {
                mint_url: Some("https://mint.example.com".to_string()),
                ..Default::default()
            },
            mint_url_override: Some("http://localhost:3338".to_string()),
            ..Default::default()
        };

        // Act
        let resolved = resolve(&inputs);

        // Assert
        assert_eq!(
            resolved.config.mint_url.as_deref(),
            Some("http://localhost:3338")
        );
    }

    #[test]
    fn a_blank_mint_override_is_ignored_rather_than_erasing_the_node_value() {
        // Arrange — an override field the user cleared.
        let inputs = EscrowModeInputs {
            from_tags: EscrowMode::Cashu,
            tag_config: CashuNodeConfig {
                mint_url: Some("https://mint.example.com".to_string()),
                ..Default::default()
            },
            mint_url_override: Some("   ".to_string()),
            ..Default::default()
        };

        // Act
        let resolved = resolve(&inputs);

        // Assert
        assert_eq!(
            resolved.config.mint_url.as_deref(),
            Some("https://mint.example.com")
        );
    }

    #[test]
    fn an_unrecognised_stored_override_falls_back_to_auto() {
        // Assert — a corrupted setting must never switch Cashu on.
        assert_eq!(
            EscrowModeOverride::from_stored("auto"),
            EscrowModeOverride::Auto
        );
        assert_eq!(EscrowModeOverride::from_stored(""), EscrowModeOverride::Auto);
        assert_eq!(
            EscrowModeOverride::from_stored("garbage"),
            EscrowModeOverride::Auto
        );
        assert_eq!(
            EscrowModeOverride::from_stored("force_cashu"),
            EscrowModeOverride::ForceCashu
        );
        // Round-trips through persistence.
        assert_eq!(
            EscrowModeOverride::from_stored(EscrowModeOverride::ForceCashu.as_stored()),
            EscrowModeOverride::ForceCashu
        );
    }

    #[test]
    fn the_global_defaults_to_unknown_and_clears_on_node_switch() {
        // Arrange — this test owns the global; keep it self-contained.
        let _guard = own_the_global();
        clear();
        assert_eq!(get_resolved().mode, EscrowMode::Unknown);
        assert!(!is_cashu_mode());

        // Act — a Cashu node is detected, then the user switches nodes.
        set_resolved(ResolvedEscrowMode {
            mode: EscrowMode::Cashu,
            config: CashuNodeConfig {
                mint_url: Some("https://mint.example.com".to_string()),
                ..Default::default()
            },
            is_overridden: false,
        });
        assert!(is_cashu_mode());
        clear();

        // Assert — a stale Cashu resolution must not leak onto the new node.
        assert_eq!(get_resolved().mode, EscrowMode::Unknown);
        assert!(!is_cashu_mode());
    }

    #[test]
    fn a_cashu_node_without_a_usable_mint_keeps_the_gate_shut() {
        // Arrange — a node that says cashu but published no mint URL.
        let _guard = own_the_global();
        clear();
        let (mode, config) = parse_tags(&[tag("escrow_mode", "cashu"), tag("cashu_mint_url", "  ")]);
        set_resolved(resolve(&EscrowModeInputs {
            from_tags: mode,
            tag_config: config,
            ..Default::default()
        }));

        // Assert — the mode is reported honestly for the About screen, but
        // there is no mint to connect to, so no Cashu path may run.
        assert_eq!(get_resolved().mode, EscrowMode::Cashu);
        assert!(!get_resolved().config.is_usable());
        assert!(!is_cashu_mode());

        // Act — the tester points it at a local mint (§4.3).
        set_resolved(resolve(&EscrowModeInputs {
            from_tags: EscrowMode::Cashu,
            mint_url_override: Some("http://localhost:3338".to_string()),
            ..Default::default()
        }));

        // Assert — now there is something to connect to.
        assert!(is_cashu_mode());
        clear();
    }
}

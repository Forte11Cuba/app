/// Wire protocol the connected Mostro speaks, from the `protocol_version` tag
/// of its Kind 38385 event.
///
/// A node speaks exactly **one** transport
/// (<https://mostro.network/protocol/transport_migration.html>):
///
/// * `"1"` → NIP-59 gift wrap, Kind 1059 — DEPRECATED and **not supported by
///   this app**. mostrod 0.19.0 drops it; mostro-core has the variant marked
///   for removal (mostro#786).
/// * `"2"` → NIP-44 direct, signed Kind 14 — what this app sends.
///
/// This module exists to make a mismatch legible. The gate is invisible on the
/// wire: a v1 node never decrypts a Kind 14 event, so it does not answer and
/// does not complain, and the client used to surface that as a plain timeout.
/// Reading the tag lets the app say which node it is talking to and why nothing
/// will happen, instead of leaving the user to guess.
use std::sync::atomic::{AtomicU8, Ordering};

/// No `protocol_version` seen yet (never fetched, or the node published none).
const UNKNOWN: u8 = 0;

/// The only protocol this app speaks.
pub const SUPPORTED_VERSION: u8 = 2;

static PROTOCOL_VERSION: AtomicU8 = AtomicU8::new(UNKNOWN);

/// Store the node's advertised protocol version, or `None` when it published
/// no `protocol_version` tag.
pub fn set_protocol_version(version: Option<u8>) {
    PROTOCOL_VERSION.store(version.unwrap_or(UNKNOWN), Ordering::Relaxed);
    match version {
        Some(SUPPORTED_VERSION) => log::info!("[protocol] node speaks v2 (signed kind 14)"),
        Some(v) => log::warn!(
            "[protocol] node advertises protocol version {v}, which this app does not speak — \
             messages to it will not be read"
        ),
        None => log::info!("[protocol] node published no protocol_version — assuming v2"),
    }
}

/// The node's advertised protocol version, or `None` when unknown.
pub fn get_protocol_version() -> Option<u8> {
    match PROTOCOL_VERSION.load(Ordering::Relaxed) {
        UNKNOWN => None,
        v => Some(v),
    }
}

/// Whether the connected node can read what this app sends.
pub fn node_is_supported() -> bool {
    is_supported(get_protocol_version())
}

/// Whether an advertised `protocol_version` is one this app speaks.
///
/// An **absent** tag counts as supported: nodes predating the tag exist, the
/// app has always spoken v2, and refusing to talk to a node that never said
/// otherwise would break working setups. Only an explicit version that is not
/// [`SUPPORTED_VERSION`] is treated as a mismatch.
pub fn is_supported(version: Option<u8>) -> bool {
    match version {
        Some(v) => v == SUPPORTED_VERSION,
        None => true,
    }
}

/// Read `protocol_version` out of a Kind 38385 tag list. A malformed value is
/// reported and treated as absent.
pub fn parse_protocol_version(tags: &[Vec<String>]) -> Option<u8> {
    let value = tags
        .iter()
        .find(|t| t.first().map(|s| s.as_str()) == Some("protocol_version"))?
        .get(1)?;

    match value.parse::<u8>() {
        Ok(v) => Some(v),
        Err(_) => {
            log::warn!("[protocol] malformed protocol_version tag: {value:?} — treating as absent");
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tag(name: &str, value: &str) -> Vec<String> {
        vec![name.to_string(), value.to_string()]
    }

    #[test]
    fn a_v2_node_is_supported() {
        assert!(is_supported(Some(2)));
    }

    #[test]
    fn a_v1_node_is_not_supported() {
        // Gift wrap is being removed, not implemented: a v1 node cannot read
        // what this app sends, and saying so beats a silent timeout.
        assert!(!is_supported(Some(1)));
    }

    #[test]
    fn an_absent_version_is_treated_as_supported() {
        // Nodes predating the tag exist and the app has always spoken v2;
        // refusing them would break setups that work today.
        assert!(is_supported(None));
    }

    #[test]
    fn an_unknown_future_version_is_not_assumed_compatible() {
        assert!(!is_supported(Some(3)));
    }

    #[test]
    fn the_version_is_read_from_the_tag_list() {
        // The shape the reference node (mostro 0.18.0) publishes today.
        let tags = vec![
            tag("mostro_version", "0.18.0"),
            tag("pow", "6"),
            tag("protocol_version", "1"),
        ];

        assert_eq!(parse_protocol_version(&tags), Some(1));
    }

    #[test]
    fn a_node_without_the_tag_reads_as_absent() {
        assert_eq!(parse_protocol_version(&[tag("pow", "6")]), None);
    }

    #[test]
    fn malformed_and_valueless_tags_read_as_absent() {
        assert_eq!(
            parse_protocol_version(&[tag("protocol_version", "two")]),
            None
        );
        assert_eq!(
            parse_protocol_version(&[vec!["protocol_version".to_string()]]),
            None
        );
    }
}

/// NIP-13 Proof of Work difficulties required by the connected Mostro.
///
/// Both are published in the daemon's Kind 38385 event and set when the relay
/// pool goes online:
///
/// * `pow` — required of **every** event the client sends.
/// * `pow_first_contact` — required when the visible sender is a trade key the
///   node does not yet associate with an active order or dispute: creating an
///   order, taking one, or a restore under a fresh trade key. Never lower than
///   `pow`, typically higher.
///
/// An under-powered event is dropped before the daemon decrypts anything, with
/// no `cant-do` and no error of any kind — mining against `pow` when the node
/// charges `pow_first_contact` makes order creation silently do nothing
/// (issue #177, <https://mostro.network/protocol/transport_migration.html>).
///
/// **An absent `pow_first_contact` tag means unknown, not zero and not `pow`.**
/// Daemons that enforce a first-contact difficulty but predate the tag exist,
/// so [`get_first_contact_pow`] returns `None` rather than a number and
/// [`first_contact_pow`] falls back to at least `pow`.
use std::sync::atomic::{AtomicU16, AtomicU8, Ordering};

static POW_DIFFICULTY: AtomicU8 = AtomicU8::new(0);

const FIRST_CONTACT_ABSENT: u16 = u16::MAX;

/// `pow_first_contact`, or [`FIRST_CONTACT_ABSENT`] when the node published no
/// such tag. A `u16` only so the "absent" state has a value a `u8` difficulty
/// can never occupy.
static POW_FIRST_CONTACT: AtomicU16 = AtomicU16::new(FIRST_CONTACT_ABSENT);

/// Store the required PoW difficulty for outgoing events.
pub fn set_pow(difficulty: u8) {
    POW_DIFFICULTY.store(difficulty, Ordering::Relaxed);
    log::info!("[pow] difficulty set to {difficulty}");
}

/// Store the first-contact difficulty, or `None` when the node published none.
pub fn set_first_contact_pow(difficulty: Option<u8>) {
    match difficulty {
        Some(d) => {
            POW_FIRST_CONTACT.store(u16::from(d), Ordering::Relaxed);
            log::info!("[pow] first-contact difficulty set to {d}");
        }
        None => {
            POW_FIRST_CONTACT.store(FIRST_CONTACT_ABSENT, Ordering::Relaxed);
            log::info!(
                "[pow] node published no pow_first_contact — first-contact difficulty unknown"
            );
        }
    }
}

/// Current PoW difficulty.  Returns 0 when no PoW is required.
pub fn get_pow() -> u8 {
    POW_DIFFICULTY.load(Ordering::Relaxed)
}

/// Advertised first-contact difficulty, or `None` when the node published no
/// `pow_first_contact` tag — which means *unknown*, not zero.
pub fn get_first_contact_pow() -> Option<u8> {
    match POW_FIRST_CONTACT.load(Ordering::Relaxed) {
        FIRST_CONTACT_ABSENT => None,
        d => Some(d as u8),
    }
}

/// Difficulty to mine a first-contact event at. See [`resolve_first_contact`].
pub fn first_contact_pow() -> u8 {
    resolve_first_contact(get_pow(), get_first_contact_pow())
}

/// The first-contact difficulty implied by [`pow`](get_pow) and an optional
/// `pow_first_contact`:
///
/// * published → that value, but never below `pow` (the protocol states it is
///   never lower; a node advertising otherwise is clamped rather than trusted).
/// * absent → `pow`, the documented floor for an unknown first-contact
///   difficulty. That may still be too low, which no client can detect from the
///   event alone: silence is the gate's only feedback.
pub fn resolve_first_contact(pow: u8, first_contact: Option<u8>) -> u8 {
    match first_contact {
        Some(d) => d.max(pow),
        None => pow,
    }
}

/// Read both PoW difficulties out of a Kind 38385 tag list.
///
/// A malformed value is reported and treated as if the tag were absent, which
/// for `pow` means 0 and for `pow_first_contact` means unknown.
pub fn parse_pow_tags(tags: &[Vec<String>]) -> (u8, Option<u8>) {
    (
        parse_difficulty(tags, "pow").unwrap_or(0),
        parse_difficulty(tags, "pow_first_contact"),
    )
}

fn parse_difficulty(tags: &[Vec<String>], name: &str) -> Option<u8> {
    let value = tags
        .iter()
        .find(|t| t.first().map(|s| s.as_str()) == Some(name))?
        .get(1)?;

    match value.parse::<u8>() {
        Ok(d) => Some(d),
        Err(_) => {
            log::warn!("[pow] malformed {name} tag value: {value:?} — treating as absent");
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
    fn an_absent_first_contact_tag_falls_back_to_pow() {
        // Not 0: the tag being absent means the difficulty is unknown, and
        // mining below `pow` would be dropped for certain.
        assert_eq!(resolve_first_contact(6, None), 6);
        assert_eq!(resolve_first_contact(0, None), 0);
    }

    #[test]
    fn a_published_first_contact_difficulty_is_used() {
        assert_eq!(resolve_first_contact(6, Some(12)), 12);
    }

    #[test]
    fn a_first_contact_difficulty_below_pow_is_clamped() {
        // The protocol states it is never lower than `pow`; a node saying
        // otherwise gets clamped rather than trusted, since `pow` applies to
        // every event including this one.
        assert_eq!(resolve_first_contact(6, Some(2)), 6);
    }

    #[test]
    fn both_difficulties_are_read_from_the_tag_list() {
        let tags = vec![
            tag("mostro_version", "0.18.0"),
            tag("pow", "6"),
            tag("pow_first_contact", "12"),
        ];

        assert_eq!(parse_pow_tags(&tags), (6, Some(12)));
    }

    #[test]
    fn a_node_publishing_only_pow_leaves_first_contact_unknown() {
        // What the daemon at 0.18.0 actually advertises today.
        let tags = vec![tag("pow", "6"), tag("protocol_version", "1")];

        assert_eq!(parse_pow_tags(&tags), (6, None));
    }

    #[test]
    fn malformed_values_are_treated_as_absent() {
        let tags = vec![tag("pow", "many"), tag("pow_first_contact", "-1")];

        assert_eq!(parse_pow_tags(&tags), (0, None));
    }

    #[test]
    fn a_valueless_tag_is_treated_as_absent() {
        let tags = vec![
            vec!["pow".to_string()],
            vec!["pow_first_contact".to_string()],
        ];

        assert_eq!(parse_pow_tags(&tags), (0, None));
    }
}

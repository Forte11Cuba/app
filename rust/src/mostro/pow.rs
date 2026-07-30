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
use std::sync::atomic::{AtomicU32, Ordering};

const FIRST_CONTACT_ABSENT: u16 = u16::MAX;

/// Both difficulties packed into one word — bits 0–7 hold `pow`, bits 8–23
/// hold `pow_first_contact` as a `u16` whose [`FIRST_CONTACT_ABSENT`] value a
/// `u8` difficulty can never occupy. One word, one store, one load: a reader
/// can never observe `pow` from one capability refresh and
/// `pow_first_contact` from another — e.g. mine a first-contact event at the
/// old first-contact value while a refresh to a stricter node is mid-flight.
static POW_SNAPSHOT: AtomicU32 = AtomicU32::new(encode(0, None));

const fn encode(pow: u8, first_contact: Option<u8>) -> u32 {
    let fc = match first_contact {
        Some(d) => d as u16,
        None => FIRST_CONTACT_ABSENT,
    };
    ((fc as u32) << 8) | pow as u32
}

const fn decode(snapshot: u32) -> (u8, Option<u8>) {
    let pow = (snapshot & 0xFF) as u8;
    match (snapshot >> 8) as u16 {
        FIRST_CONTACT_ABSENT => (pow, None),
        d => (pow, Some(d as u8)),
    }
}

/// Store both PoW difficulties as one atomic snapshot: `pow` for every
/// outgoing event, and `pow_first_contact` (`None` when the node published no
/// such tag). A single setter on purpose — publishing them separately would
/// let a concurrent wrap mine against one fresh and one stale value.
pub fn set_pows(pow: u8, first_contact: Option<u8>) {
    POW_SNAPSHOT.store(encode(pow, first_contact), Ordering::Relaxed);
    match first_contact {
        Some(d) => log::info!("[pow] difficulty set to {pow}, first-contact to {d}"),
        None => log::info!(
            "[pow] difficulty set to {pow}; node published no pow_first_contact — \
             first-contact difficulty unknown"
        ),
    }
}

/// Current PoW difficulty.  Returns 0 when no PoW is required.
pub fn get_pow() -> u8 {
    decode(POW_SNAPSHOT.load(Ordering::Relaxed)).0
}

/// Advertised first-contact difficulty, or `None` when the node published no
/// `pow_first_contact` tag — which means *unknown*, not zero.
pub fn get_first_contact_pow() -> Option<u8> {
    decode(POW_SNAPSHOT.load(Ordering::Relaxed)).1
}

/// Difficulty to mine a first-contact event at. Both inputs come from a single
/// atomic load, so they always belong to the same capability refresh. See
/// [`resolve_first_contact`].
pub fn first_contact_pow() -> u8 {
    let (pow, first_contact) = decode(POW_SNAPSHOT.load(Ordering::Relaxed));
    resolve_first_contact(pow, first_contact)
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

/// Serializes tests that touch the process-global PoW snapshot — they live in
/// this module and in `mostro::actions` — and restores the "nothing
/// advertised" default on drop so no test leaks a difficulty into another.
#[cfg(test)]
pub(crate) mod test_support {
    use std::sync::{Mutex, MutexGuard, PoisonError};

    static LOCK: Mutex<()> = Mutex::new(());

    pub(crate) struct PowGuard(#[allow(dead_code)] MutexGuard<'static, ()>);

    impl Drop for PowGuard {
        fn drop(&mut self) {
            super::set_pows(0, None);
        }
    }

    pub(crate) fn lock_pow() -> PowGuard {
        PowGuard(LOCK.lock().unwrap_or_else(PoisonError::into_inner))
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
    fn the_snapshot_roundtrips_every_boundary_value() {
        for (pow, fc) in [
            (0, None),
            (255, None),
            (0, Some(0)),
            (255, Some(255)),
            (6, Some(12)),
        ] {
            assert_eq!(decode(encode(pow, fc)), (pow, fc));
        }
    }

    /// Regression for the refresh race (PR #251 review): both difficulties are
    /// published as one snapshot, so the absent → advertised transition can
    /// never be observed half-applied by `first_contact_pow`.
    #[test]
    fn a_refresh_publishes_both_difficulties_together() {
        let _guard = test_support::lock_pow();

        set_pows(6, None);
        assert_eq!(get_pow(), 6);
        assert_eq!(get_first_contact_pow(), None);
        assert_eq!(first_contact_pow(), 6);

        set_pows(6, Some(12));
        assert_eq!(get_pow(), 6);
        assert_eq!(get_first_contact_pow(), Some(12));
        assert_eq!(first_contact_pow(), 12);
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

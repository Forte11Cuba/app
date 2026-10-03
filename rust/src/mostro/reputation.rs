//! Reputation values shared by the two places the daemon sends them: the
//! Kind 38383 `rating` tag and the `Peer` snapshot of a trade.

/// The last Unix second Dart's `DateTime` can hold: 8_640_000_000_000_000 ms
/// after the epoch. Past it, building the date throws instead of returning
/// one.
pub(crate) const MAX_SINCE_SECS: u64 = 8_640_000_000_000;

/// `since` as the bridge carries it: a positive number of seconds that Dart
/// can turn into a date, or `None`, which makes the UI fall back to the
/// deprecated day count.
pub(crate) fn since_from_wire(seconds: u64) -> Option<i64> {
    // Bounded by MAX_SINCE_SECS, so the cast cannot wrap.
    (1..=MAX_SINCE_SECS)
        .contains(&seconds)
        .then_some(seconds as i64)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_date_dart_can_hold_is_kept() {
        assert_eq!(since_from_wire(1), Some(1));
        assert_eq!(since_from_wire(1_699_920_000), Some(1_699_920_000));
        assert_eq!(since_from_wire(MAX_SINCE_SECS), Some(MAX_SINCE_SECS as i64));
    }

    #[test]
    fn zero_and_anything_past_dart_s_range_is_no_date() {
        assert_eq!(since_from_wire(0), None);
        assert_eq!(since_from_wire(MAX_SINCE_SECS + 1), None);
        assert_eq!(since_from_wire(i64::MAX as u64), None);
        assert_eq!(since_from_wire(u64::MAX), None);
    }
}

//! Order-status mapping and reconciliation rules.
//!
//! Pure functions, all of them: they translate between the daemon's wire
//! vocabulary (`mostro_core` actions and statuses) and this client's
//! `OrderStatus`, and decide when an inbound status may overwrite what is
//! already stored locally.
//!
//! Extracted from `api/orders.rs`, where they had no business living: nothing
//! here is callable from Dart, and `api/` is the FRB bridge surface (#120).
//! Being pure and dependency-free, they are also the cheapest part of the
//! protocol logic to test directly.

use crate::api::types::OrderStatus;

/// Maps a `mostro_core::order::Status` to the local [`OrderStatus`] enum.
/// Map a daemon action to the order status it implies, for messages that
/// carry no explicit status payload (action-only progression replies).
///
/// Shared by the status-sync arm in `dispatch_mostro_message` and by
/// `classify_take_reply`, so a take whose first reply is action-only (e.g.
/// `waiting-seller-to-pay` after a take-sell with a pre-attached LN address)
/// still persists the status the daemon already advanced to.
pub(crate) fn status_for_action(action: &mostro_core::message::Action) -> Option<OrderStatus> {
    use mostro_core::message::Action;
    match action {
        Action::AddInvoice => Some(OrderStatus::WaitingBuyerInvoice),
        Action::WaitingSellerToPay => Some(OrderStatus::WaitingPayment),
        Action::WaitingBuyerInvoice => Some(OrderStatus::WaitingBuyerInvoice),
        Action::BuyerTookOrder
        | Action::HoldInvoicePaymentAccepted
        | Action::BuyerInvoiceAccepted => Some(OrderStatus::Active),
        Action::FiatSentOk => Some(OrderStatus::FiatSent),
        Action::HoldInvoicePaymentSettled | Action::Released | Action::PurchaseCompleted => {
            Some(OrderStatus::SettledHoldInvoice)
        }
        Action::HoldInvoicePaymentCanceled => Some(OrderStatus::Canceled),
        Action::CooperativeCancelAccepted => Some(OrderStatus::CooperativelyCanceled),
        // Status doesn't change yet for cancel initiations; Rate/PaymentFailed
        // don't move the order either.
        Action::CooperativeCancelInitiatedByPeer
        | Action::CooperativeCancelInitiatedByYou
        | Action::Rate
        | Action::RateUser
        | Action::RateReceived
        | Action::PaymentFailed => None,
        Action::DisputeInitiatedByYou | Action::DisputeInitiatedByPeer => {
            Some(OrderStatus::Dispute)
        }
        Action::AdminSettled => Some(OrderStatus::SettledByAdmin),
        Action::AdminCanceled => Some(OrderStatus::CanceledByAdmin),
        _ => None,
    }
}

pub(crate) fn map_core_status(s: mostro_core::order::Status) -> Option<OrderStatus> {
    use mostro_core::order::Status as S;
    Some(match s {
        S::Pending => OrderStatus::Pending,
        S::WaitingBuyerInvoice => OrderStatus::WaitingBuyerInvoice,
        S::WaitingPayment => OrderStatus::WaitingPayment,
        S::Active => OrderStatus::Active,
        S::InProgress => OrderStatus::InProgress,
        S::FiatSent => OrderStatus::FiatSent,
        S::SettledHoldInvoice => OrderStatus::SettledHoldInvoice,
        S::Success => OrderStatus::Success,
        S::Canceled => OrderStatus::Canceled,
        S::CooperativelyCanceled => OrderStatus::CooperativelyCanceled,
        S::Expired => OrderStatus::Expired,
        S::CanceledByAdmin => OrderStatus::CanceledByAdmin,
        S::SettledByAdmin => OrderStatus::SettledByAdmin,
        S::CompletedByAdmin => OrderStatus::CompletedByAdmin,
        S::Dispute => OrderStatus::Dispute,
        // Anti-abuse bond is out of scope; these statuses have no local
        // OrderStatus mapping. No wildcard, so future Status variants keep
        // forcing this match to be revisited.
        S::WaitingTakerBond | S::WaitingMakerBond => return None,
    })
}

/// Statuses no daemon message may leave: mostrod never reopens a canceled
/// or completed trade. `SettledHoldInvoice` and `Dispute` are deliberately
/// NOT here — they still progress (to `Success` / admin resolutions).
pub(crate) fn is_hard_terminal(status: &OrderStatus) -> bool {
    matches!(
        status,
        OrderStatus::Canceled
            | OrderStatus::CanceledByAdmin
            | OrderStatus::CooperativelyCanceled
            | OrderStatus::Expired
            | OrderStatus::Success
            | OrderStatus::SettledByAdmin
            | OrderStatus::CompletedByAdmin
    )
}

pub(crate) fn is_terminal_status(s: &OrderStatus) -> bool {
    matches!(
        s,
        OrderStatus::Success
            | OrderStatus::SettledHoldInvoice
            | OrderStatus::SettledByAdmin
            | OrderStatus::CompletedByAdmin
            | OrderStatus::Canceled
            | OrderStatus::CanceledByAdmin
            | OrderStatus::CooperativelyCanceled
            | OrderStatus::Expired
    )
}

pub(crate) fn wire_status_applies(local: Option<&OrderStatus>, wire: &OrderStatus) -> bool {
    match local {
        None | Some(OrderStatus::Pending) => true,
        Some(_) => is_terminal_status(wire),
    }
}

/// Whether a daemon `canceled` should wipe the local trade record instead of
/// keeping a Canceled history row.
///
/// True only while the trade never reached Active — no peer pubkey, no chat,
/// no exchange happened (typically a waiting-state timeout, or a maker
/// canceling their own pending order). Anything further along keeps its row
/// (and chat) as history. `InProgress` is deliberately NOT wiped: mostrod
/// never sends it over kind-14 — it only lands in a maker row via the Kind
/// 38383 sync, where it masks both waiting AND active phases (mostrod
/// nip33.rs publishes taken orders as `in-progress`), so it is ambiguous.
pub(crate) fn cancellation_wipes_history(status: &OrderStatus) -> bool {
    matches!(
        status,
        OrderStatus::Pending
            | OrderStatus::WaitingBuyerInvoice
            | OrderStatus::WaitingPayment
    )
}

/// Extracts the status and calculated sats to persist from an inbound
/// `add-invoice` payload.
///
/// Returns `None` when the payload carries no order data — notably the
/// daemon's follow-up `add-invoice` with a `Peer` payload (counterparty
/// reputation), which is deliberately not consumed yet.
pub(crate) fn add_invoice_sync(
    payload: &Option<mostro_core::message::Payload>,
) -> Option<(OrderStatus, Option<u64>)> {
    match payload {
        Some(mostro_core::message::Payload::Order(so)) => {
            let status = so
                .status
                .and_then(map_core_status)
                .unwrap_or(OrderStatus::WaitingBuyerInvoice);
            let amount = if so.amount > 0 {
                Some(so.amount as u64)
            } else {
                None
            };
            Some((status, amount))
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The precedence rule that keeps a public order-book status from
    /// overwriting what this client knows about its own trade: once a trade
    /// has moved past `Pending`, only a terminal wire status may apply.
    #[test]
    fn a_wire_status_may_not_walk_a_live_trade_backwards() {
        // Nothing known locally, or still pending: the wire is all we have.
        assert!(wire_status_applies(None, &OrderStatus::Active));
        assert!(wire_status_applies(
            Some(&OrderStatus::Pending),
            &OrderStatus::Active
        ));
        // Live locally: a non-terminal wire status is the public book talking
        // about an order we know more about than it does.
        assert!(!wire_status_applies(
            Some(&OrderStatus::FiatSent),
            &OrderStatus::Active
        ));
        // Terminal always applies — the trade really is over.
        assert!(wire_status_applies(
            Some(&OrderStatus::FiatSent),
            &OrderStatus::Canceled
        ));
    }

    /// `SettledHoldInvoice` is terminal for status-sync purposes but not
    /// "hard" terminal: the escrow is settled and the payout may still be in
    /// flight, so history must survive it. Conflating the two would drop a
    /// trade the user is still waiting to be paid for.
    #[test]
    fn settled_hold_invoice_is_terminal_but_not_hard_terminal() {
        assert!(is_terminal_status(&OrderStatus::SettledHoldInvoice));
        assert!(!is_hard_terminal(&OrderStatus::SettledHoldInvoice));
        assert!(is_hard_terminal(&OrderStatus::Success));
        assert!(is_hard_terminal(&OrderStatus::Canceled));
    }

    /// Only the pre-trade states may have their history wiped by a
    /// cancellation: past that point the user has a trade worth keeping.
    #[test]
    fn only_pre_trade_cancellations_wipe_history() {
        assert!(cancellation_wipes_history(&OrderStatus::Pending));
        assert!(cancellation_wipes_history(&OrderStatus::WaitingBuyerInvoice));
        assert!(cancellation_wipes_history(&OrderStatus::WaitingPayment));
        assert!(!cancellation_wipes_history(&OrderStatus::Active));
        assert!(!cancellation_wipes_history(&OrderStatus::FiatSent));
    }

    /// The bond statuses have no local mapping on purpose, and `map_core_status`
    /// matches exhaustively so a new upstream variant fails the build rather
    /// than silently reading as something else.
    #[test]
    fn bond_statuses_map_to_nothing_rather_than_to_something_wrong() {
        use mostro_core::order::Status as S;
        assert_eq!(map_core_status(S::WaitingTakerBond), None);
        assert_eq!(map_core_status(S::WaitingMakerBond), None);
        assert_eq!(map_core_status(S::Active), Some(OrderStatus::Active));
    }

    /// Actions that carry no status change must return `None`, not a guess:
    /// a wrong `Some` here would move a trade on a message that never meant to.
    #[test]
    fn actions_without_a_status_change_return_none() {
        use mostro_core::message::Action;
        assert_eq!(status_for_action(&Action::Rate), None);
        assert_eq!(status_for_action(&Action::PaymentFailed), None);
        assert_eq!(
            status_for_action(&Action::CooperativeCancelInitiatedByPeer),
            None
        );
        assert_eq!(
            status_for_action(&Action::FiatSentOk),
            Some(OrderStatus::FiatSent)
        );
    }
}

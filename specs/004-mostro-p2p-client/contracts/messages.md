# Contract: Messages API

**Module**: `rust/src/api/messages.rs`

Encrypted peer-to-peer messaging during trades, over the **chat envelope**
of the protocol spec (<https://mostro.network/protocol/chat.html>, issue
#246): a kind 14 outer event signed with `K_sign` and `p`-tagged to
`pub(K_conv)` — both HKDF-SHA256 derivations of the trade-key ECDH secret —
carrying a NIP-44 encrypted kind 1 inner event signed by the sender's trade
key. NIP-59 gift wrap (kind 1059) is no longer *written* for peer chat (its
random ephemeral authors made third-party flooding unattributable); it is
still *read* from pre-migration peers until the dual-read deadline
(`LEGACY_CHAT_DEPRECATION_TS`, 2026-12-31T00:00:00Z), bounded by the same
LRU / rate budget / size cap / durable dedup / quota as the new envelope.
Admin/dispute chat still uses gift wrap. Messages persist locally after
validation. Supports encrypted file attachments via Blossom servers.

**Security requirements implemented** (see the protocol spec for the
normative list):

- Subscription pinned to `authors = [pub(K_sign)]`, bounded by a persisted
  per-order `since` cursor (clamped to the local clock) plus a `limit`.
- Cheapest-check-first validation; no signature or decryption work before
  the outer-id LRU and the rate-limit budget (token bucket, 30 msg/min
  sustained, burst 60; sustained violation marks the conversation flooded
  and halts chat processing while the trade stays operational).
- Inner signature verified and its author checked against the two trade
  keys of the order — the only sender authentication.
- Durable replay dedup on the inner event id (`messages` table on native,
  IndexedDB on web), **fail-closed**: a dedup lookup error drops the event.
- The rate budget meters only the live stream (post-EOSE); stored catch-up
  is bounded by the filter `limit` instead, so history above the burst size
  is never dropped.
- The cursor advances only past durably stored messages.
- Per-trade retention quotas (message count and total bytes) bound durable
  growth even at a legitimate send rate.
- Send-side size validation: a message whose encrypted envelope no receiver
  would accept fails with a stable `MessageTooLarge` error; each inner event
  carries a signed uniqueness nonce so identical same-second sends keep
  distinct ids.
- Subscription lifecycle: one task per order (spawn guard), explicit
  subscription ids unsubscribed on every exit, no idle timeout, and
  automatic resubscription of persisted active trades when the relay pool
  comes online.
- Isolation: chat runs on its own task and bounded channels; it can never
  block the order state machine, the daemon transport, or a dispute.

## Functions

### send_message(trade_id: String, content: String) → ChatMessage
Send an encrypted message to the trade counterparty.

**Validation**: `content` MUST not be empty. Trade MUST be active.

**Side effects**: Wraps in the chat envelope (inner kind 1 signed by the
trade key, outer kind 14 signed with `K_sign`), publishes to relays. The
stored message id is the inner event id, so both sides dedup on the same
identity. If the session, peer, or relay pool is unavailable the message is
stored locally with a warning.

**Errors**: `NoActiveTrade`, `TradeNotFound`, `MessageEmpty`.

---

### get_messages(trade_id: String) → Vec<ChatMessage>
Get all messages for a trade, ordered by creation time.

**Returns**: Locally persisted messages for the specified trade.

---

### mark_as_read(trade_id: String) → ()
Mark all messages in a trade as read.

**Side effects**: Updates `is_read` flag on all unread messages for
the trade. Emits on unread count stream.

---

### get_unread_count() → u32
Get total unread message count across all trades.

## Streams

### on_new_message(trade_id: String) → Stream<ChatMessage>
Emits when a new message is received for the specified trade.

### on_unread_count_changed() → Stream<u32>
Emits when the global unread message count changes.

---

## File Attachment Functions

### send_file(trade_id: String, file_bytes: Vec<u8>, file_name: String, mime_type: String) → ChatMessage
Encrypt and upload a file attachment, then send as a chat message.

**Validation**:
- File size MUST not exceed 25MB.
- `mime_type` MUST be a supported type (image/*, application/pdf,
  text/*, video/*).
- Trade MUST be active.

**Flow**:
1. Encrypt file with ChaCha20-Poly1305 (random nonce, key derived from
   sharedKey for P2P messages or tradeKey for admin/dispute messages).
2. Upload encrypted blob to Blossom server.
3. Send Blossom URL + metadata as a JSON pointer payload (`type: "file"`)
   through the same chat envelope as text messages.

**Returns**: ChatMessage with `has_attachment: true` and attachment metadata.

**Errors**: `FileTooLarge`, `UnsupportedFileType`, `UploadFailed`,
`NoActiveTrade`.

---

### download_attachment(message_id: String) → FileDownloadResult
Download and decrypt a file attachment.

**Returns**:
```text
FileDownloadResult {
  local_path: String    # Path to decrypted file on device
  file_name: String
  mime_type: String
  file_size: u64
}
```

**Errors**: `AttachmentNotFound`, `DownloadFailed`, `DecryptionFailed`.

---

### get_attachment_status(message_id: String) → AttachmentStatus?
Get download status of an attachment.

## Attachment Streams

### on_attachment_progress(message_id: String) → Stream<f64>
Emits download/upload progress (0.0 to 1.0).

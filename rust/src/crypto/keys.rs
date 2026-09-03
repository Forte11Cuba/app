/// BIP-39/BIP-32 key derivation for Mostro identity and trade keys.
///
/// Derivation path: `m/44'/1237'/38383'/0/N`
///   - Purpose  44' = BIP-44
///   - Coin     1237' = Nostr
///   - Account  38383' = Mostro
///   - Change   0
///   - Index    N  (0 = identity key, ≥1 = per-trade keys)
///
/// **DO NOT change the derivation path** — it is a protocol constant shared
/// with Mostro daemon and other compliant clients.
use anyhow::{anyhow, Result};
use bip32::{DerivationPath, XPrv};
use bip39::Mnemonic;
use nostr_sdk::prelude::{Keys, SecretKey};
use zeroize::Zeroizing;

const DERIVATION_PREFIX: &str = "m/44'/1237'/38383'/0";

/// Generate a fresh 12-word BIP-39 mnemonic phrase.
pub fn generate_mnemonic() -> Result<Vec<String>> {
    let mnemonic = Mnemonic::generate(12).map_err(|e| anyhow!("mnemonic generation: {e}"))?;
    Ok(mnemonic.words().map(|w| w.to_string()).collect())
}

/// Parse and validate a mnemonic from a word list.
/// Accepts 12 or 24 words. Returns error on invalid words or checksum.
pub fn validate_mnemonic(words: &[String]) -> Result<()> {
    let phrase = words.join(" ");
    Mnemonic::parse(&phrase).map_err(|e| anyhow!("invalid mnemonic: {e}"))?;
    Ok(())
}

/// Derive the identity (`N=0`) Nostr `Keys` from a mnemonic.
pub fn derive_master_key(mnemonic_words: &[String]) -> Result<Keys> {
    derive_at_index(mnemonic_words, 0)
}

/// Derive a trade-specific Nostr `Keys` at the given BIP-32 child index.
/// `index` must be ≥ 1; index 0 is reserved for the identity key.
pub fn derive_trade_key(mnemonic_words: &[String], index: u32) -> Result<Keys> {
    if index == 0 {
        return Err(anyhow!("index 0 is reserved for the identity key; use derive_master_key"));
    }
    derive_at_index(mnemonic_words, index)
}

/// Derive the raw BIP-39 seed from a mnemonic.
///
/// This is the same 64-byte seed [`derive_master_key`] feeds into BIP-32, with
/// the same empty passphrase. The Cashu wallet (phase C2) uses it directly:
/// `cdk` derives its blinding secrets from a 64-byte seed, so the wallet is
/// recoverable from the very words the user already backed up — one secret to
/// protect, not two.
/// Returned in a [`Zeroizing`] wrapper so the copy is wiped when the caller
/// drops it — the seed is the whole account, and it is about to cross into a
/// third-party crate.
pub fn derive_bip39_seed(mnemonic_words: &[String]) -> Result<Zeroizing<[u8; 64]>> {
    let phrase = mnemonic_words.join(" ");
    let mnemonic = Mnemonic::parse(&phrase).map_err(|e| anyhow!("invalid mnemonic: {e}"))?;
    Ok(Zeroizing::new(mnemonic.to_seed("")))
}

// ── Internal ─────────────────────────────────────────────────────────────────

fn derive_at_index(mnemonic_words: &[String], index: u32) -> Result<Keys> {
    let phrase = mnemonic_words.join(" ");
    let mnemonic = Mnemonic::parse(&phrase).map_err(|e| anyhow!("invalid mnemonic: {e}"))?;
    // BIP-39 seed — no passphrase per the Nostr NIP-06 convention.
    let seed = mnemonic.to_seed("");

    let path_str = format!("{}/{}", DERIVATION_PREFIX, index);
    let path: DerivationPath = path_str
        .parse()
        .map_err(|e| anyhow!("derivation path parse: {e}"))?;

    let xprv = XPrv::derive_from_path(seed, &path)
        .map_err(|e| anyhow!("BIP-32 derive error: {e}"))?;

    // k256 signing key → raw 32-byte secret
    let raw: [u8; 32] = xprv.private_key().to_bytes().into();
    let secret = SecretKey::from_slice(&raw).map_err(|e| anyhow!("invalid secret key: {e}"))?;
    Ok(Keys::new(secret))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip_mnemonic_generates_stable_keys() {
        let words = generate_mnemonic().unwrap();
        assert_eq!(words.len(), 12);

        let k1 = derive_master_key(&words).unwrap();
        let k2 = derive_master_key(&words).unwrap();
        assert_eq!(k1.public_key(), k2.public_key());
    }

    #[test]
    fn trade_key_differs_from_identity_key() {
        let words = generate_mnemonic().unwrap();
        let identity = derive_master_key(&words).unwrap();
        let trade = derive_trade_key(&words, 1).unwrap();
        assert_ne!(identity.public_key(), trade.public_key());
    }

    /// The Cashu wallet seeds itself from this, so it is not enough that the
    /// derivation is stable — it has to be *the* BIP-39 seed, or the ecash is
    /// recoverable only by this app and the user's 12 words buy them nothing in
    /// any other wallet. The vector is the canonical all-`abandon` mnemonic
    /// with an empty passphrase.
    #[test]
    fn the_bip39_seed_matches_the_standard_vector() {
        // Arrange
        let words: Vec<String> = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
            .split(' ')
            .map(str::to_string)
            .collect();

        // Act
        let seed = derive_bip39_seed(&words).unwrap();

        // Assert
        assert_eq!(
            hex::encode(*seed),
            "5eb00bbddcf069084889a8ab9155568165f5c453ccb85e70811aaed6f6da5fc19a5ac40b389cd370d086206dec8aa6c43daea6690f20ad3d8d48b2d2ce9e38e4"
        );
    }

    #[test]
    fn a_mnemonic_that_is_not_one_is_refused() {
        // Assert — the seed derivation validates rather than hashing whatever
        // it was handed; an nsec-imported identity has no words at all.
        assert!(derive_bip39_seed(&[]).is_err());
        assert!(derive_bip39_seed(&["not".to_string(), "a".to_string(), "mnemonic".to_string()]).is_err());
    }

    #[test]
    fn different_indices_produce_different_keys() {
        let words = generate_mnemonic().unwrap();
        let k1 = derive_trade_key(&words, 1).unwrap();
        let k2 = derive_trade_key(&words, 2).unwrap();
        assert_ne!(k1.public_key(), k2.public_key());
    }
}

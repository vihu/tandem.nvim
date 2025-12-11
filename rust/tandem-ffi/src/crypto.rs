//! End-to-end encryption for session data using AES-256-GCM.
//!
//! The encryption key is generated locally and shared via the session code.
//! The server never sees the plaintext data.

use aes_gcm::{
    Aes256Gcm, KeyInit, Nonce,
    aead::{Aead, OsRng, rand_core::RngCore},
};
use base64ct::{Base64UrlUnpadded, Encoding};
use nvim_oxi::{Dictionary, Function, Object};

/// Key size in bytes (256 bits)
pub const KEY_SIZE: usize = 32;

/// Nonce size in bytes (96 bits for GCM)
const NONCE_SIZE: usize = 12;

/// Generate a random 256-bit encryption key.
/// Returns the key as base64url-encoded string.
pub fn generate_key() -> String {
    let mut key = [0u8; KEY_SIZE];
    OsRng.fill_bytes(&mut key);
    Base64UrlUnpadded::encode_string(&key)
}

/// Encrypt plaintext using AES-256-GCM.
///
/// # Arguments
/// * `key_b64` - Base64url-encoded 256-bit key
/// * `plaintext` - Data to encrypt
///
/// # Returns
/// Base64url-encoded ciphertext with nonce prepended (nonce || ciphertext)
pub fn encrypt(key_b64: &str, plaintext: &[u8]) -> Result<String, String> {
    let key_bytes =
        Base64UrlUnpadded::decode_vec(key_b64).map_err(|e| format!("Invalid key base64: {e}"))?;

    if key_bytes.len() != KEY_SIZE {
        return Err(format!(
            "Invalid key size: expected {KEY_SIZE}, got {}",
            key_bytes.len()
        ));
    }

    let cipher = Aes256Gcm::new_from_slice(&key_bytes)
        .map_err(|e| format!("Failed to create cipher: {e}"))?;

    // Generate random nonce
    let mut nonce_bytes = [0u8; NONCE_SIZE];
    OsRng.fill_bytes(&mut nonce_bytes);
    let nonce = Nonce::from_slice(&nonce_bytes);

    // Encrypt
    let ciphertext = cipher
        .encrypt(nonce, plaintext)
        .map_err(|e| format!("Encryption failed: {e}"))?;

    // Prepend nonce to ciphertext
    let mut result = Vec::with_capacity(NONCE_SIZE + ciphertext.len());
    result.extend_from_slice(&nonce_bytes);
    result.extend_from_slice(&ciphertext);

    Ok(Base64UrlUnpadded::encode_string(&result))
}

/// Decrypt ciphertext using AES-256-GCM.
///
/// # Arguments
/// * `key_b64` - Base64url-encoded 256-bit key
/// * `ciphertext_b64` - Base64url-encoded ciphertext with nonce prepended
///
/// # Returns
/// Decrypted plaintext bytes
pub fn decrypt(key_b64: &str, ciphertext_b64: &str) -> Result<Vec<u8>, String> {
    let key_bytes =
        Base64UrlUnpadded::decode_vec(key_b64).map_err(|e| format!("Invalid key base64: {e}"))?;

    if key_bytes.len() != KEY_SIZE {
        return Err(format!(
            "Invalid key size: expected {KEY_SIZE}, got {}",
            key_bytes.len()
        ));
    }

    let data = Base64UrlUnpadded::decode_vec(ciphertext_b64)
        .map_err(|e| format!("Invalid ciphertext base64: {e}"))?;

    if data.len() < NONCE_SIZE {
        return Err("Ciphertext too short (missing nonce)".to_string());
    }

    let (nonce_bytes, ciphertext) = data.split_at(NONCE_SIZE);
    let nonce = Nonce::from_slice(nonce_bytes);

    let cipher = Aes256Gcm::new_from_slice(&key_bytes)
        .map_err(|e| format!("Failed to create cipher: {e}"))?;

    cipher
        .decrypt(nonce, ciphertext)
        .map_err(|e| format!("Decryption failed: {e}"))
}

/// Export crypto functions to Lua via nvim-oxi.
pub fn crypto_ffi() -> Dictionary {
    Dictionary::from_iter([
        (
            "generate_key",
            Object::from(Function::<(), String>::from_fn(
                |_| -> Result<String, nvim_oxi::Error> { Ok(generate_key()) },
            )),
        ),
        (
            "encrypt",
            Object::from(Function::<(String, String), String>::from_fn(
                |(key, plaintext)| -> Result<String, nvim_oxi::Error> {
                    match encrypt(&key, plaintext.as_bytes()) {
                        Ok(ct) => Ok(ct),
                        Err(e) => Err(nvim_oxi::Error::Api(nvim_oxi::api::Error::Other(e))),
                    }
                },
            )),
        ),
        (
            "decrypt",
            Object::from(Function::<(String, String), String>::from_fn(
                |(key, ciphertext)| -> Result<String, nvim_oxi::Error> {
                    match decrypt(&key, &ciphertext) {
                        Ok(bytes) => Ok(String::from_utf8_lossy(&bytes).to_string()),
                        Err(e) => Err(nvim_oxi::Error::Api(nvim_oxi::api::Error::Other(e))),
                    }
                },
            )),
        ),
    ])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_generate_key_length() {
        let key = generate_key();
        let decoded = Base64UrlUnpadded::decode_vec(&key).expect("valid base64");
        assert_eq!(decoded.len(), KEY_SIZE);
    }

    #[test]
    fn test_generate_key_unique() {
        let key1 = generate_key();
        let key2 = generate_key();
        assert_ne!(key1, key2);
    }

    #[test]
    fn test_encrypt_decrypt_roundtrip() {
        let key = generate_key();
        let plaintext = b"Hello, world!";

        let ciphertext = encrypt(&key, plaintext).expect("encrypt");
        let decrypted = decrypt(&key, &ciphertext).expect("decrypt");

        assert_eq!(decrypted, plaintext);
    }

    #[test]
    fn test_encrypt_produces_different_output() {
        let key = generate_key();
        let plaintext = b"Same message";

        let ct1 = encrypt(&key, plaintext).expect("encrypt 1");
        let ct2 = encrypt(&key, plaintext).expect("encrypt 2");

        // Different nonces should produce different ciphertexts
        assert_ne!(ct1, ct2);

        // But both should decrypt to same plaintext
        assert_eq!(decrypt(&key, &ct1).expect("decrypt 1"), plaintext);
        assert_eq!(decrypt(&key, &ct2).expect("decrypt 2"), plaintext);
    }

    #[test]
    fn test_decrypt_wrong_key_fails() {
        let key1 = generate_key();
        let key2 = generate_key();
        let plaintext = b"Secret message";

        let ciphertext = encrypt(&key1, plaintext).expect("encrypt");
        let result = decrypt(&key2, &ciphertext);

        assert!(result.is_err());
        assert!(result.unwrap_err().contains("Decryption failed"));
    }

    #[test]
    fn test_decrypt_tampered_ciphertext_fails() {
        let key = generate_key();
        let plaintext = b"Secret message";

        let ciphertext = encrypt(&key, plaintext).expect("encrypt");
        let mut tampered = Base64UrlUnpadded::decode_vec(&ciphertext).expect("decode");
        let last_idx = tampered.len() - 1;
        tampered[last_idx] ^= 0xFF; // Flip last byte
        let tampered_b64 = Base64UrlUnpadded::encode_string(&tampered);

        let result = decrypt(&key, &tampered_b64);
        assert!(result.is_err());
    }

    #[test]
    fn test_empty_plaintext() {
        let key = generate_key();
        let plaintext = b"";

        let ciphertext = encrypt(&key, plaintext).expect("encrypt");
        let decrypted = decrypt(&key, &ciphertext).expect("decrypt");

        assert_eq!(decrypted, plaintext);
    }

    #[test]
    fn test_large_plaintext() {
        let key = generate_key();
        let plaintext = vec![0x42u8; 100_000]; // 100KB

        let ciphertext = encrypt(&key, &plaintext).expect("encrypt");
        let decrypted = decrypt(&key, &ciphertext).expect("decrypt");

        assert_eq!(decrypted, plaintext);
    }

    #[test]
    fn test_invalid_key_base64() {
        let result = encrypt("not-valid-base64!!!", b"test");
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("Invalid key base64"));
    }

    #[test]
    fn test_invalid_key_size() {
        let short_key = Base64UrlUnpadded::encode_string(&[0u8; 16]); // 128-bit
        let result = encrypt(&short_key, b"test");
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("Invalid key size"));
    }
}

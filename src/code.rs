//! Session code encoding/decoding.
//!
//! Two formats supported:
//!
//! ## Legacy (WebSocket + E2E):
//! `base64url(doc_id || 0x00 || 256-bit-key)`
//!
//! ## P2P (Iroh):
//! `base64url(endpoint_id_str || 0x01 || relay_url)`
//! - endpoint_id_str: Iroh EndpointId as string (z32 encoded public key)
//! - relay_url: URL of the relay server for NAT traversal

use base64ct::{Base64UrlUnpadded, Encoding};
use nvim_oxi::{Dictionary, Function, Object};

use crate::crypto::KEY_SIZE;

/// Separator byte between doc_id and key (legacy format)
const SEPARATOR: u8 = 0x00;

/// Separator byte for P2P format (EndpointId || relay_url)
const P2P_SEPARATOR: u8 = 0x01;

/// Encode document ID and encryption key into a session code.
///
/// Format: `base64url(doc_id_bytes || 0x00 || key_bytes)`
pub fn encode(doc_id: &str, key_b64: &str) -> Result<String, String> {
    // Validate doc_id doesn't contain null bytes
    if doc_id.as_bytes().contains(&SEPARATOR) {
        return Err("Document ID cannot contain null bytes".to_string());
    }

    // Decode and validate key
    let key_bytes =
        Base64UrlUnpadded::decode_vec(key_b64).map_err(|e| format!("Invalid key base64: {e}"))?;

    if key_bytes.len() != KEY_SIZE {
        return Err(format!(
            "Invalid key size: expected {KEY_SIZE}, got {}",
            key_bytes.len()
        ));
    }

    // Build payload: doc_id || 0x00 || key
    let mut payload = Vec::with_capacity(doc_id.len() + 1 + KEY_SIZE);
    payload.extend_from_slice(doc_id.as_bytes());
    payload.push(SEPARATOR);
    payload.extend_from_slice(&key_bytes);

    Ok(Base64UrlUnpadded::encode_string(&payload))
}

/// Decode a session code into (doc_id, key_b64).
pub fn decode(code: &str) -> Result<(String, String), String> {
    let payload = Base64UrlUnpadded::decode_vec(code)
        .map_err(|e| format!("Invalid session code base64: {e}"))?;

    // Find separator
    let sep_pos = payload
        .iter()
        .position(|&b| b == SEPARATOR)
        .ok_or("Invalid session code: missing separator")?;

    // Validate key size
    let key_start = sep_pos + 1;
    if payload.len() - key_start != KEY_SIZE {
        return Err(format!(
            "Invalid session code: key size {} (expected {KEY_SIZE})",
            payload.len() - key_start
        ));
    }

    // Extract doc_id and key
    let doc_id = String::from_utf8(payload[..sep_pos].to_vec())
        .map_err(|e| format!("Invalid document ID UTF-8: {e}"))?;

    let key_b64 = Base64UrlUnpadded::encode_string(&payload[key_start..]);

    Ok((doc_id, key_b64))
}

// ============================================================================
// P2P Session Code (Iroh)
// ============================================================================

/// Encode EndpointId and RelayUrl into a P2P session code.
///
/// Format: `base64url(endpoint_id_str || 0x01 || relay_url)`
pub fn encode_p2p_session_code(endpoint_id: &str, relay_url: &str) -> Result<String, String> {
    // Validate inputs don't contain the separator
    if endpoint_id.as_bytes().contains(&P2P_SEPARATOR) {
        return Err("Endpoint ID cannot contain separator byte".to_string());
    }

    // Build payload: endpoint_id || 0x01 || relay_url
    let mut payload = Vec::with_capacity(endpoint_id.len() + 1 + relay_url.len());
    payload.extend_from_slice(endpoint_id.as_bytes());
    payload.push(P2P_SEPARATOR);
    payload.extend_from_slice(relay_url.as_bytes());

    Ok(Base64UrlUnpadded::encode_string(&payload))
}

/// Decode a P2P session code into (endpoint_id, relay_url).
pub fn decode_p2p_session_code(code: &str) -> Result<(String, String), String> {
    let payload = Base64UrlUnpadded::decode_vec(code)
        .map_err(|e| format!("Invalid P2P session code base64: {e}"))?;

    // Find separator
    let sep_pos = payload
        .iter()
        .position(|&b| b == P2P_SEPARATOR)
        .ok_or("Invalid P2P session code: missing separator (not a P2P code?)")?;

    // Extract endpoint_id and relay_url
    let endpoint_id = String::from_utf8(payload[..sep_pos].to_vec())
        .map_err(|e| format!("Invalid endpoint ID UTF-8: {e}"))?;

    let relay_url = String::from_utf8(payload[sep_pos + 1..].to_vec())
        .map_err(|e| format!("Invalid relay URL UTF-8: {e}"))?;

    Ok((endpoint_id, relay_url))
}

/// Export code functions to Lua via nvim-oxi.
pub fn code_ffi() -> Dictionary {
    Dictionary::from_iter([
        // Legacy (WebSocket + E2E)
        (
            "encode",
            Object::from(Function::<(String, String), String>::from_fn(
                |(doc_id, key)| -> Result<String, nvim_oxi::Error> {
                    match encode(&doc_id, &key) {
                        Ok(code) => Ok(code),
                        Err(e) => Err(nvim_oxi::Error::Api(nvim_oxi::api::Error::Other(e))),
                    }
                },
            )),
        ),
        (
            "decode",
            Object::from(Function::<String, (String, String)>::from_fn(
                |code| -> Result<(String, String), nvim_oxi::Error> {
                    match decode(&code) {
                        Ok((doc_id, key)) => Ok((doc_id, key)),
                        Err(e) => Err(nvim_oxi::Error::Api(nvim_oxi::api::Error::Other(e))),
                    }
                },
            )),
        ),
        // P2P (Iroh)
        (
            "encode_p2p",
            Object::from(Function::<(String, String), String>::from_fn(
                |(endpoint_id, relay_url)| -> Result<String, nvim_oxi::Error> {
                    match encode_p2p_session_code(&endpoint_id, &relay_url) {
                        Ok(code) => Ok(code),
                        Err(e) => Err(nvim_oxi::Error::Api(nvim_oxi::api::Error::Other(e))),
                    }
                },
            )),
        ),
        (
            "decode_p2p",
            Object::from(Function::<String, (String, String)>::from_fn(
                |code| -> Result<(String, String), nvim_oxi::Error> {
                    match decode_p2p_session_code(&code) {
                        Ok((endpoint_id, relay_url)) => Ok((endpoint_id, relay_url)),
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
    use crate::crypto::generate_key;

    #[test]
    fn test_encode_decode_roundtrip() {
        let doc_id = "my-project";
        let key = generate_key();

        let code = encode(doc_id, &key).expect("encode");
        let (decoded_doc_id, decoded_key) = decode(&code).expect("decode");

        assert_eq!(decoded_doc_id, doc_id);
        assert_eq!(decoded_key, key);
    }

    #[test]
    fn test_encode_decode_various_doc_ids() {
        let test_cases = [
            "simple",
            "with-dashes",
            "with_underscores",
            "MixedCase",
            "123",
            "a",
            "very-long-document-identifier-that-is-quite-lengthy",
        ];

        for doc_id in test_cases {
            let key = generate_key();
            let code = encode(doc_id, &key).expect("encode");
            let (decoded_doc_id, decoded_key) = decode(&code).expect("decode");

            assert_eq!(decoded_doc_id, doc_id, "doc_id mismatch for {doc_id}");
            assert_eq!(decoded_key, key, "key mismatch for {doc_id}");
        }
    }

    #[test]
    fn test_code_length_estimation() {
        // For doc_id "my-project" (10 bytes) + 1 separator + 32 key = 43 bytes
        // Base64 encoding: ceil(43 * 4 / 3) = 58 chars (without padding)
        let doc_id = "my-project";
        let key = generate_key();
        let code = encode(doc_id, &key).expect("encode");

        // Should be around 58 characters for this doc_id
        assert!(
            code.len() >= 50 && code.len() <= 60,
            "code length: {}",
            code.len()
        );
    }

    #[test]
    fn test_doc_id_with_null_byte_rejected() {
        let key = generate_key();
        let doc_id = "bad\x00id";

        let result = encode(doc_id, &key);
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("null bytes"));
    }

    #[test]
    fn test_invalid_key_rejected() {
        let short_key = Base64UrlUnpadded::encode_string(&[0u8; 16]);
        let result = encode("test", &short_key);

        assert!(result.is_err());
        assert!(result.unwrap_err().contains("Invalid key size"));
    }

    #[test]
    fn test_decode_invalid_base64() {
        let result = decode("not-valid-base64!!!");
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("Invalid session code base64"));
    }

    #[test]
    fn test_decode_missing_separator() {
        // Encode raw bytes without separator
        let data = b"no-separator-here";
        let code = Base64UrlUnpadded::encode_string(data);

        let result = decode(&code);
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("missing separator"));
    }

    #[test]
    fn test_decode_wrong_key_size() {
        // Encode with wrong key size
        let mut payload = b"test".to_vec();
        payload.push(SEPARATOR);
        payload.extend_from_slice(&[0u8; 16]); // 16 bytes instead of 32
        let code = Base64UrlUnpadded::encode_string(&payload);

        let result = decode(&code);
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("key size"));
    }

    #[test]
    fn test_unicode_doc_id() {
        // UTF-8 characters in doc_id
        let doc_id = "проект";
        let key = generate_key();

        let code = encode(doc_id, &key).expect("encode");
        let (decoded_doc_id, decoded_key) = decode(&code).expect("decode");

        assert_eq!(decoded_doc_id, doc_id);
        assert_eq!(decoded_key, key);
    }

    #[test]
    fn test_empty_doc_id() {
        let doc_id = "";
        let key = generate_key();

        let code = encode(doc_id, &key).expect("encode");
        let (decoded_doc_id, decoded_key) = decode(&code).expect("decode");

        assert_eq!(decoded_doc_id, doc_id);
        assert_eq!(decoded_key, key);
    }
}

//! P2P session code encoding/decoding.
//!
//! Format: `base64url(endpoint_id_str || 0x01 || relay_url)`
//! - endpoint_id_str: Iroh EndpointId as string (z32 encoded public key)
//! - relay_url: URL of the relay server for NAT traversal

use base64ct::{Base64UrlUnpadded, Encoding};
use nvim_oxi::{Dictionary, Function, Object};

/// Separator byte for P2P format
const P2P_SEPARATOR: u8 = 0x01;

/// Encode EndpointId and RelayUrl into a P2P session code.
///
/// Format: `base64url(endpoint_id_str || 0x01 || relay_url)`
pub fn encode(endpoint_id: &str, relay_url: &str) -> Result<String, String> {
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
pub fn decode(code: &str) -> Result<(String, String), String> {
    let payload =
        Base64UrlUnpadded::decode_vec(code).map_err(|e| format!("Invalid session code: {e}"))?;

    // Find separator
    let sep_pos = payload
        .iter()
        .position(|&b| b == P2P_SEPARATOR)
        .ok_or("Invalid session code: missing separator")?;

    // Extract endpoint_id and relay_url
    let endpoint_id = String::from_utf8(payload[..sep_pos].to_vec())
        .map_err(|e| format!("Invalid endpoint ID: {e}"))?;

    let relay_url = String::from_utf8(payload[sep_pos + 1..].to_vec())
        .map_err(|e| format!("Invalid relay URL: {e}"))?;

    Ok((endpoint_id, relay_url))
}

/// Export code functions to Lua via nvim-oxi.
pub fn code_ffi() -> Dictionary {
    Dictionary::from_iter([
        (
            "encode",
            Object::from(Function::<(String, String), String>::from_fn(
                |(endpoint_id, relay_url)| -> Result<String, nvim_oxi::Error> {
                    match encode(&endpoint_id, &relay_url) {
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

    #[test]
    fn test_roundtrip() {
        let endpoint_id = "abc123xyz";
        let relay_url = "https://relay.example.com";

        let code = encode(endpoint_id, relay_url).expect("encode");
        let (decoded_id, decoded_url) = decode(&code).expect("decode");

        assert_eq!(decoded_id, endpoint_id);
        assert_eq!(decoded_url, relay_url);
    }

    #[test]
    fn test_real_endpoint_id() {
        // Iroh endpoint IDs are z32-encoded public keys
        let endpoint_id = "aeagcidcmbjgc3djobqxg2ldoaqc4idcmfwca53imf2cazdfobzq";
        let relay_url = "https://euw1-1.relay.iroh.network./";

        let code = encode(endpoint_id, relay_url).expect("encode");
        let (decoded_id, decoded_url) = decode(&code).expect("decode");

        assert_eq!(decoded_id, endpoint_id);
        assert_eq!(decoded_url, relay_url);
    }

    #[test]
    fn test_invalid_code() {
        let result = decode("not-valid-base64!!!");
        assert!(result.is_err());
    }

    #[test]
    fn test_missing_separator() {
        // Encode raw bytes without separator
        let data = b"no-separator-here";
        let code = Base64UrlUnpadded::encode_string(data);

        let result = decode(&code);
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("missing separator"));
    }
}

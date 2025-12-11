//! Client-side JWT generation for anonymous authentication.
//!
//! When connecting to a Conflux server running in anonymous mode (`--anonymous`),
//! clients generate their own JWTs. The server validates structure only, not signature.

use chrono::{Duration, Utc};
use jsonwebtoken::{EncodingKey, Header, encode};
use nvim_oxi::{Dictionary, Function, Object};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// JWT claims structure matching Conflux server expectations.
#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct Claims {
    /// Subject (username)
    pub sub: String,
    /// Issued at (Unix timestamp)
    pub iat: usize,
    /// Expiration (Unix timestamp)
    pub exp: usize,
    /// Session ID (UUID)
    pub sid: String,
}

/// Generate a JWT token for anonymous authentication.
///
/// The token is signed with a random secret since anonymous mode servers
/// only validate the JWT structure, not the signature.
pub fn generate_token(username: &str) -> String {
    let now = Utc::now();
    let session_id = Uuid::new_v4().to_string();

    let claims = Claims {
        sub: username.to_string(),
        iat: now.timestamp() as usize,
        exp: (now + Duration::hours(24)).timestamp() as usize,
        sid: session_id,
    };

    // Use a random secret - anonymous mode servers don't verify signatures
    let secret = Uuid::new_v4().to_string();

    encode(
        &Header::default(),
        &claims,
        &EncodingKey::from_secret(secret.as_bytes()),
    )
    .expect("failed to encode JWT")
}

/// Export auth functions to Lua via nvim-oxi.
pub fn auth_ffi() -> Dictionary {
    Dictionary::from_iter([(
        "generate_token",
        Object::from(Function::<String, String>::from_fn(
            |username| -> Result<String, nvim_oxi::Error> { Ok(generate_token(&username)) },
        )),
    )])
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};

    #[test]
    fn test_generate_token_structure() {
        let token = generate_token("testuser");

        // Should have 3 parts separated by dots
        let parts: Vec<&str> = token.split('.').collect();
        assert_eq!(parts.len(), 3);

        // Decode and verify claims
        let payload = URL_SAFE_NO_PAD.decode(parts[1]).expect("valid base64");
        let claims: Claims = serde_json::from_slice(&payload).expect("valid JSON");

        assert_eq!(claims.sub, "testuser");
        assert!(!claims.sid.is_empty());

        let now = Utc::now().timestamp() as usize;
        assert!(claims.iat <= now);
        assert!(claims.exp > now);
    }

    #[test]
    fn test_unique_session_ids() {
        let token1 = generate_token("user");
        let token2 = generate_token("user");

        let parts1: Vec<&str> = token1.split('.').collect();
        let parts2: Vec<&str> = token2.split('.').collect();

        let payload1 = URL_SAFE_NO_PAD.decode(parts1[1]).unwrap();
        let payload2 = URL_SAFE_NO_PAD.decode(parts2[1]).unwrap();

        let claims1: Claims = serde_json::from_slice(&payload1).unwrap();
        let claims2: Claims = serde_json::from_slice(&payload2).unwrap();

        // Same user, different session IDs
        assert_eq!(claims1.sub, claims2.sub);
        assert_ne!(claims1.sid, claims2.sid);
    }

    #[test]
    fn test_token_expiration() {
        let token = generate_token("user");

        let parts: Vec<&str> = token.split('.').collect();
        let payload = URL_SAFE_NO_PAD.decode(parts[1]).unwrap();
        let claims: Claims = serde_json::from_slice(&payload).unwrap();

        let now = Utc::now().timestamp() as usize;

        // Token should expire in ~24 hours
        assert!(claims.exp > now + 23 * 3600);
        assert!(claims.exp <= now + 25 * 3600);
    }
}

//! Binary MessagePack protocol for tandem communication
//!
//! This matches the tandem-server protocol exactly.
//! Server now sends compacted snapshots instead of accumulated updates.

use serde::{Deserialize, Serialize};

/// Client -> Server messages (MessagePack)
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "t", content = "d")]
pub enum ClientMsg {
    /// Request sync state (snapshot)
    #[serde(rename = "s")]
    SyncRequest,
    /// CRDT update (raw binary Loro update)
    #[serde(rename = "u")]
    #[serde(with = "serde_bytes")]
    Update(Vec<u8>),
    /// Awareness update (cursor/presence)
    #[serde(rename = "a")]
    Awareness(rmpv::Value),
}

/// Server -> Client messages (MessagePack)
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "t", content = "d")]
pub enum ServerMsg {
    /// Sync response with compacted snapshot
    #[serde(rename = "s")]
    #[serde(with = "serde_bytes")]
    SyncResponse(Vec<u8>),
    /// CRDT update broadcast
    #[serde(rename = "u")]
    #[serde(with = "serde_bytes")]
    Update(Vec<u8>),
    /// Awareness broadcast
    #[serde(rename = "a")]
    Awareness(rmpv::Value),
    /// Error message from server
    #[serde(rename = "e")]
    Error { code: String, message: String },
}

impl ClientMsg {
    pub fn sync_request() -> Vec<u8> {
        rmp_serde::to_vec_named(&ClientMsg::SyncRequest).unwrap_or_default()
    }

    pub fn update(data: Vec<u8>) -> Vec<u8> {
        rmp_serde::to_vec_named(&ClientMsg::Update(data)).unwrap_or_default()
    }

    pub fn awareness(value: rmpv::Value) -> Vec<u8> {
        rmp_serde::to_vec_named(&ClientMsg::Awareness(value)).unwrap_or_default()
    }
}

impl ServerMsg {
    pub fn parse(data: &[u8]) -> Option<Self> {
        rmp_serde::from_slice(data).ok()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_client_msg_roundtrip() {
        // SyncRequest
        let msg = ClientMsg::SyncRequest;
        let encoded = rmp_serde::to_vec_named(&msg).unwrap();
        let decoded: ClientMsg = rmp_serde::from_slice(&encoded).unwrap();
        assert!(matches!(decoded, ClientMsg::SyncRequest));

        // Update
        let data = vec![1, 2, 3, 4, 5];
        let msg = ClientMsg::Update(data.clone());
        let encoded = rmp_serde::to_vec_named(&msg).unwrap();
        let decoded: ClientMsg = rmp_serde::from_slice(&encoded).unwrap();
        if let ClientMsg::Update(d) = decoded {
            assert_eq!(d, data);
        } else {
            panic!("Expected Update");
        }
    }

    #[test]
    fn test_server_msg_parse_snapshot() {
        // Create a SyncResponse with snapshot
        let snapshot = vec![1, 2, 3, 4, 5];
        let msg = ServerMsg::SyncResponse(snapshot.clone());
        let encoded = rmp_serde::to_vec_named(&msg).unwrap();

        // Parse it back
        let decoded = ServerMsg::parse(&encoded).unwrap();
        if let ServerMsg::SyncResponse(data) = decoded {
            assert_eq!(data, snapshot);
        } else {
            panic!("Expected SyncResponse");
        }
    }

    #[test]
    fn test_server_msg_parse_error() {
        // Create an Error message
        let msg = ServerMsg::Error {
            code: "TEST_ERROR".to_string(),
            message: "Test error message".to_string(),
        };
        let encoded = rmp_serde::to_vec_named(&msg).unwrap();

        // Parse it back
        let decoded = ServerMsg::parse(&encoded).unwrap();
        if let ServerMsg::Error { code, message } = decoded {
            assert_eq!(code, "TEST_ERROR");
            assert_eq!(message, "Test error message");
        } else {
            panic!("Expected Error");
        }
    }
}

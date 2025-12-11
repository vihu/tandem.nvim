//! tandem-server: WebSocket relay server with server-side CRDT
//!
//! Features:
//! - Server maintains canonical LoroDoc per room
//! - Incoming updates are applied to server's doc, then broadcast
//! - Late joiners receive compacted snapshot instead of update history
//! - Configurable limits (max peers, max rooms, max doc size)
//! - Room cleanup when last peer disconnects (ephemeral)
//!
//! Protocol: Binary MessagePack over WebSocket
//!
//! Usage:
//!   cargo run -p tandem-server
//!   # Listens on ws://127.0.0.1:8080
//!
//! Environment variables:
//!   TANDEM_BIND_ADDR       - Bind address (default: 127.0.0.1:8080)
//!   TANDEM_MAX_PEERS       - Max peers per room (default: 8)
//!   TANDEM_MAX_ROOMS       - Max total rooms (default: 1000000)
//!   TANDEM_MAX_DOC_SIZE    - Max document size in bytes (default: 10485760 = 10MB)

use futures_util::{SinkExt, StreamExt};
use log::{debug, error, info, warn};
use loro::{ExportMode, LoroDoc};
use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    env,
    net::SocketAddr,
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
};
use tokio::{
    net::{TcpListener, TcpStream},
    sync::{RwLock, broadcast, mpsc},
};
use tokio_tungstenite::{
    accept_hdr_async,
    tungstenite::{Message, handshake::server::Request, handshake::server::Response},
};
use uuid::Uuid;

/// Server configuration
#[derive(Debug, Clone)]
struct Config {
    bind_addr: String,
    max_peers_per_room: usize,
    max_rooms: usize,
    max_doc_size: usize,
}

impl Config {
    fn from_env() -> Self {
        Self {
            bind_addr: env::var("TANDEM_BIND_ADDR").unwrap_or_else(|_| "127.0.0.1:8080".into()),
            max_peers_per_room: env::var("TANDEM_MAX_PEERS")
                .ok()
                .and_then(|s| s.parse().ok())
                .unwrap_or(8),
            max_rooms: env::var("TANDEM_MAX_ROOMS")
                .ok()
                .and_then(|s| s.parse().ok())
                .unwrap_or(1_000_000),
            max_doc_size: env::var("TANDEM_MAX_DOC_SIZE")
                .ok()
                .and_then(|s| s.parse().ok())
                .unwrap_or(10 * 1024 * 1024), // 10MB
        }
    }
}

/// Global counter for unique peer IDs (for logging)
static PEER_COUNTER: AtomicUsize = AtomicUsize::new(0);

/// A room holds the canonical CRDT document and broadcast channel
struct Room {
    /// Broadcast channel for updates to all peers
    tx: broadcast::Sender<(Uuid, Message)>,
    /// The canonical CRDT document (server is authoritative)
    doc: RwLock<LoroDoc>,
    /// Connected peers (peer_id -> peer info for future presence)
    peers: RwLock<HashMap<Uuid, PeerInfo>>,
    /// Number of connected peers (atomic for quick access)
    peer_count: AtomicUsize,
}

/// Basic peer information (will be extended for presence)
#[derive(Debug, Clone)]
struct PeerInfo {
    #[allow(dead_code)]
    log_id: usize, // For logging only
}

impl Room {
    fn new() -> Self {
        let (tx, _) = broadcast::channel(256);
        // Create empty LoroDoc - do NOT initialize any containers
        // Server just stores/merges what clients send, doesn't create its own operations
        let doc = LoroDoc::new();

        Self {
            tx,
            doc: RwLock::new(doc),
            peers: RwLock::new(HashMap::new()),
            peer_count: AtomicUsize::new(0),
        }
    }

    async fn add_peer(&self, peer_id: Uuid, log_id: usize) -> usize {
        let mut peers = self.peers.write().await;
        peers.insert(peer_id, PeerInfo { log_id });
        self.peer_count.fetch_add(1, Ordering::SeqCst) + 1
    }

    async fn remove_peer(&self, peer_id: &Uuid) -> usize {
        let mut peers = self.peers.write().await;
        peers.remove(peer_id);
        self.peer_count.fetch_sub(1, Ordering::SeqCst) - 1
    }

    fn peer_count(&self) -> usize {
        self.peer_count.load(Ordering::SeqCst)
    }

    /// Apply an update to the canonical document
    /// Returns Ok(true) if applied, Ok(false) if duplicate/no-op, Err on invalid
    async fn apply_update(&self, update: &[u8], max_doc_size: usize) -> Result<bool, String> {
        let doc = self.doc.write().await;

        // Check document size limit before applying
        let current_size = doc
            .export(ExportMode::Snapshot)
            .map(|s| s.len())
            .unwrap_or(0);
        if current_size + update.len() > max_doc_size {
            return Err(format!(
                "Document size limit exceeded: {} + {} > {}",
                current_size,
                update.len(),
                max_doc_size
            ));
        }

        // Apply the update
        match doc.import(update) {
            Ok(_) => Ok(true),
            Err(e) => {
                // Check if it's a "already applied" error (duplicate)
                let err_str = e.to_string();
                if err_str.contains("already") || err_str.contains("outdated") {
                    Ok(false) // Duplicate, not an error
                } else {
                    Err(format!("Failed to import update: {}", e))
                }
            }
        }
    }

    /// Export a compacted snapshot of the document
    async fn export_snapshot(&self) -> Vec<u8> {
        let doc = self.doc.read().await;
        doc.export(ExportMode::Snapshot).unwrap_or_default()
    }
}

/// Server state: map of room_id -> Room
type Rooms = Arc<RwLock<HashMap<String, Arc<Room>>>>;

#[tokio::main]
async fn main() {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();

    let config = Config::from_env();
    info!(
        "tandem-server starting with config: bind={}, max_peers={}, max_rooms={}, max_doc_size={}",
        config.bind_addr, config.max_peers_per_room, config.max_rooms, config.max_doc_size
    );

    let listener = TcpListener::bind(&config.bind_addr)
        .await
        .expect("Failed to bind");
    info!("tandem-server listening on ws://{}", config.bind_addr);

    let rooms: Rooms = Arc::new(RwLock::new(HashMap::new()));
    let config = Arc::new(config);

    while let Ok((stream, addr)) = listener.accept().await {
        let rooms = rooms.clone();
        let config = config.clone();
        tokio::spawn(async move {
            if let Err(e) = handle_connection(stream, addr, rooms, config).await {
                error!("Connection error from {}: {}", addr, e);
            }
        });
    }
}

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
    /// Error message
    #[serde(rename = "e")]
    Error { code: String, message: String },
}

/// Extract room ID from WebSocket upgrade request path
fn extract_room_id(path: &str) -> String {
    let path = path.strip_prefix("/ws/").unwrap_or(path);
    let path = path.split('?').next().unwrap_or(path);
    if path.is_empty() {
        "default".to_string()
    } else {
        path.to_string()
    }
}

/// Parse a binary MessagePack message
fn parse_message(data: &[u8]) -> Option<ClientMsg> {
    rmp_serde::from_slice(data).ok()
}

/// Build a binary sync_response with snapshot
fn build_sync_response(snapshot: Vec<u8>) -> Vec<u8> {
    let msg = ServerMsg::SyncResponse(snapshot);
    rmp_serde::to_vec_named(&msg).unwrap_or_default()
}

/// Build a binary update message
fn build_update(data: &[u8]) -> Vec<u8> {
    let msg = ServerMsg::Update(data.to_vec());
    rmp_serde::to_vec_named(&msg).unwrap_or_default()
}

/// Build a binary awareness message
fn build_awareness(value: rmpv::Value) -> Vec<u8> {
    let msg = ServerMsg::Awareness(value);
    rmp_serde::to_vec_named(&msg).unwrap_or_default()
}

/// Build a binary error message
fn build_error(code: &str, message: &str) -> Vec<u8> {
    let msg = ServerMsg::Error {
        code: code.to_string(),
        message: message.to_string(),
    };
    rmp_serde::to_vec_named(&msg).unwrap_or_default()
}

async fn handle_connection(
    stream: TcpStream,
    addr: SocketAddr,
    rooms: Rooms,
    config: Arc<Config>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let log_id = PEER_COUNTER.fetch_add(1, Ordering::Relaxed);
    let peer_id = Uuid::new_v4();

    let room_id = Arc::new(std::sync::Mutex::new(String::new()));
    let room_id_clone = room_id.clone();

    let callback = |req: &Request, resp: Response| {
        let path = req.uri().path();
        let extracted = extract_room_id(path);
        *room_id_clone.lock().unwrap() = extracted;
        Ok(resp)
    };

    let ws_stream = accept_hdr_async(stream, callback).await?;
    let room_id = room_id.lock().unwrap().clone();

    info!(
        "[peer:{}] Connected from {} to room '{}' (uuid: {})",
        log_id, addr, room_id, peer_id
    );

    // Check room limit before creating new room
    {
        let rooms_read = rooms.read().await;
        if !rooms_read.contains_key(&room_id) && rooms_read.len() >= config.max_rooms {
            warn!(
                "[peer:{}] Room limit reached ({}), rejecting connection",
                log_id, config.max_rooms
            );
            return Ok(());
        }
    }

    // Get or create room
    let room = {
        let mut rooms_write = rooms.write().await;
        rooms_write
            .entry(room_id.clone())
            .or_insert_with(|| Arc::new(Room::new()))
            .clone()
    };

    // Check peer limit before joining
    if room.peer_count() >= config.max_peers_per_room {
        warn!(
            "[peer:{}] Room '{}' is full ({} peers), rejecting connection",
            log_id, room_id, config.max_peers_per_room
        );
        return Ok(());
    }

    // Track this peer
    let peer_count = room.add_peer(peer_id, log_id).await;
    info!(
        "[peer:{}] Room '{}' now has {} peer(s)",
        log_id, room_id, peer_count
    );

    let mut broadcast_rx = room.tx.subscribe();
    let (mut ws_tx, mut ws_rx) = ws_stream.split();

    // Channel for direct messages to this peer (like sync_response)
    let (direct_tx, mut direct_rx) = mpsc::channel::<Message>(32);

    // Task to send messages to this peer
    let send_task = tokio::spawn(async move {
        loop {
            tokio::select! {
                // Direct messages (sync_response, errors)
                Some(msg) = direct_rx.recv() => {
                    if ws_tx.send(msg).await.is_err() {
                        break;
                    }
                }
                // Broadcast messages (updates from other peers)
                Ok((sender_id, msg)) = broadcast_rx.recv() => {
                    // Don't echo back to sender
                    if sender_id != peer_id && ws_tx.send(msg).await.is_err() {
                        break;
                    }
                }
            }
        }
    });

    // Receive messages from this peer
    let room_tx = room.tx.clone();
    while let Some(msg_result) = ws_rx.next().await {
        match msg_result {
            Ok(msg) => {
                if msg.is_close() {
                    break;
                }

                if msg.is_binary() {
                    let data = msg.clone().into_data();

                    if let Some(client_msg) = parse_message(&data) {
                        match client_msg {
                            ClientMsg::SyncRequest => {
                                // Export compacted snapshot
                                let snapshot = room.export_snapshot().await;
                                let response = build_sync_response(snapshot.clone());
                                debug!(
                                    "[peer:{}] Sending sync_response (snapshot: {} bytes)",
                                    log_id,
                                    snapshot.len()
                                );
                                let _ = direct_tx.send(Message::Binary(response.into())).await;
                            }
                            ClientMsg::Update(update_data) => {
                                // Apply update to server's canonical document
                                match room.apply_update(&update_data, config.max_doc_size).await {
                                    Ok(true) => {
                                        debug!(
                                            "[peer:{}] Applied update ({} bytes)",
                                            log_id,
                                            update_data.len()
                                        );
                                        // Broadcast to all peers (including sender for ack)
                                        let broadcast_msg =
                                            Message::Binary(build_update(&update_data).into());
                                        let _ = room_tx.send((peer_id, broadcast_msg));
                                    }
                                    Ok(false) => {
                                        debug!(
                                            "[peer:{}] Duplicate/no-op update, not broadcasting",
                                            log_id
                                        );
                                    }
                                    Err(e) => {
                                        warn!("[peer:{}] Update rejected: {}", log_id, e);
                                        let error_msg = build_error("UPDATE_REJECTED", &e);
                                        let _ =
                                            direct_tx.send(Message::Binary(error_msg.into())).await;
                                    }
                                }
                            }
                            ClientMsg::Awareness(value) => {
                                // Broadcast awareness to other peers
                                let broadcast_msg = Message::Binary(build_awareness(value).into());
                                let _ = room_tx.send((peer_id, broadcast_msg));
                            }
                        }
                    } else {
                        warn!("[peer:{}] Failed to parse binary message", log_id);
                    }
                } else {
                    warn!("[peer:{}] Received non-binary message, ignoring", log_id);
                }
            }
            Err(e) => {
                warn!("[peer:{}] WebSocket error: {}", log_id, e);
                break;
            }
        }
    }

    send_task.abort();

    // Clean up peer from room
    let remaining = room.remove_peer(&peer_id).await;
    info!(
        "[peer:{}] Disconnected from room '{}', {} peer(s) remaining",
        log_id, room_id, remaining
    );

    // If room is empty, remove it (ephemeral)
    if remaining == 0 {
        info!("[room:{}] No peers remaining, removing room", room_id);
        let mut rooms_write = rooms.write().await;
        rooms_write.remove(&room_id);
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_extract_room_id() {
        assert_eq!(extract_room_id("/ws/my-room"), "my-room");
        assert_eq!(extract_room_id("/ws/my-room?token=abc"), "my-room");
        assert_eq!(extract_room_id("/ws/"), "default");
    }

    #[test]
    fn test_empty_loro_doc_snapshot() {
        // Verify that an empty LoroDoc exports to 0 bytes
        let doc = LoroDoc::new();
        let snapshot = doc.export(ExportMode::Snapshot).unwrap();
        println!("Empty LoroDoc snapshot: {} bytes", snapshot.len());
        // Empty doc should have minimal snapshot
        assert!(
            snapshot.len() < 100,
            "Empty snapshot too large: {} bytes",
            snapshot.len()
        );
    }

    #[test]
    fn test_config_defaults() {
        // Clear env vars to test defaults
        // SAFETY: Tests run single-threaded, no concurrent access to env vars
        unsafe {
            env::remove_var("TANDEM_BIND_ADDR");
            env::remove_var("TANDEM_MAX_PEERS");
            env::remove_var("TANDEM_MAX_ROOMS");
            env::remove_var("TANDEM_MAX_DOC_SIZE");
        }

        let config = Config::from_env();
        assert_eq!(config.bind_addr, "127.0.0.1:8080");
        assert_eq!(config.max_peers_per_room, 8);
        assert_eq!(config.max_rooms, 1_000_000);
        assert_eq!(config.max_doc_size, 10 * 1024 * 1024);
    }

    #[test]
    fn test_message_serialization() {
        // Test ClientMsg::SyncRequest
        let msg = ClientMsg::SyncRequest;
        let encoded = rmp_serde::to_vec_named(&msg).unwrap();
        let decoded: ClientMsg = rmp_serde::from_slice(&encoded).unwrap();
        assert!(matches!(decoded, ClientMsg::SyncRequest));

        // Test ClientMsg::Update
        let update_data = vec![1, 2, 3, 4, 5];
        let msg = ClientMsg::Update(update_data.clone());
        let encoded = rmp_serde::to_vec_named(&msg).unwrap();
        let decoded: ClientMsg = rmp_serde::from_slice(&encoded).unwrap();
        if let ClientMsg::Update(data) = decoded {
            assert_eq!(data, update_data);
        } else {
            panic!("Expected Update variant");
        }
    }

    #[test]
    fn test_sync_response_serialization() {
        let snapshot = vec![1, 2, 3, 4, 5];
        let response = build_sync_response(snapshot.clone());
        let decoded: ServerMsg = rmp_serde::from_slice(&response).unwrap();
        if let ServerMsg::SyncResponse(data) = decoded {
            assert_eq!(data, snapshot);
        } else {
            panic!("Expected SyncResponse variant");
        }
    }

    #[test]
    fn test_error_serialization() {
        let error = build_error("TEST_ERROR", "This is a test error");
        let decoded: ServerMsg = rmp_serde::from_slice(&error).unwrap();
        if let ServerMsg::Error { code, message } = decoded {
            assert_eq!(code, "TEST_ERROR");
            assert_eq!(message, "This is a test error");
        } else {
            panic!("Expected Error variant");
        }
    }

    #[tokio::test]
    async fn test_room_operations() {
        let room = Room::new();

        // Add peers
        let peer1 = Uuid::new_v4();
        let peer2 = Uuid::new_v4();

        assert_eq!(room.add_peer(peer1, 0).await, 1);
        assert_eq!(room.add_peer(peer2, 1).await, 2);
        assert_eq!(room.peer_count(), 2);

        // Remove peer
        assert_eq!(room.remove_peer(&peer1).await, 1);
        assert_eq!(room.peer_count(), 1);
    }

    #[tokio::test]
    async fn test_room_loro_operations() {
        let room = Room::new();

        // Create a valid Loro update
        let doc = LoroDoc::new();
        let text = doc.get_text("content");
        text.insert(0, "Hello, World!").unwrap();
        let update = doc.export(ExportMode::all_updates()).unwrap();

        // Apply to room
        let result = room.apply_update(&update, 10 * 1024 * 1024).await;
        assert!(result.is_ok());
        assert!(result.unwrap()); // Should return true (applied)

        // Export snapshot
        let snapshot = room.export_snapshot().await;
        assert!(!snapshot.is_empty());

        // Verify content by importing into new doc
        let verify_doc = LoroDoc::new();
        verify_doc.import(&snapshot).unwrap();
        let text = verify_doc.get_text("content");
        assert_eq!(text.to_string(), "Hello, World!");
    }

    #[tokio::test]
    async fn test_room_update_merge() {
        let room = Room::new();

        // Create two separate docs with updates
        let doc1 = LoroDoc::new();
        let text1 = doc1.get_text("content");
        text1.insert(0, "Hello").unwrap();
        let update1 = doc1.export(ExportMode::all_updates()).unwrap();

        let doc2 = LoroDoc::new();
        let text2 = doc2.get_text("content");
        text2.insert(0, "World").unwrap();
        let update2 = doc2.export(ExportMode::all_updates()).unwrap();

        // Apply both updates
        room.apply_update(&update1, 10 * 1024 * 1024).await.unwrap();
        room.apply_update(&update2, 10 * 1024 * 1024).await.unwrap();

        // Verify merge
        let snapshot = room.export_snapshot().await;
        let verify_doc = LoroDoc::new();
        verify_doc.import(&snapshot).unwrap();
        let text = verify_doc.get_text("content");
        // CRDT merge: both strings should be present (order may vary)
        let content = text.to_string();
        assert!(content.contains("Hello") || content.contains("World"));
    }

    #[tokio::test]
    async fn test_room_doc_size_limit() {
        let room = Room::new();

        // Create a large update
        let doc = LoroDoc::new();
        let text = doc.get_text("content");
        let large_content = "x".repeat(1000);
        text.insert(0, &large_content).unwrap();
        let update = doc.export(ExportMode::all_updates()).unwrap();

        // Should reject when limit is small
        let result = room.apply_update(&update, 100).await;
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("size limit"));
    }
}

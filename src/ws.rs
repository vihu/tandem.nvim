//! WebSocket client module with callback-based event delivery
//!
//! Uses `AsyncHandle` to immediately deliver WebSocket events to Lua callbacks
//! instead of polling, eliminating race conditions from the event queue.
//!
//! Supports optional E2E encryption: if an encryption key is provided at connect time,
//! all incoming data is decrypted and outgoing data is encrypted transparently.

use base64::Engine;
use base64ct::{Base64UrlUnpadded, Encoding as Base64UrlEncoding};
use futures_util::{SinkExt, StreamExt};
use log::{debug, error, info, warn};
use nvim_oxi::{
    Dictionary, Function, Object,
    libuv::AsyncHandle,
    mlua::{
        lua,
        prelude::{LuaFunction, LuaTable},
    },
    schedule,
};
use parking_lot::Mutex;
use std::{collections::HashMap, sync::Arc, sync::LazyLock};
use tokio::sync::mpsc::{self, UnboundedReceiver, UnboundedSender};
use tokio_tungstenite::tungstenite::Message;
use url::Url;
use uuid::Uuid;

use crate::crypto;
use crate::protocol::{ClientMsg, ServerMsg};
use crate::runtime;

/// Global registry of WebSocket clients
static CLIENTS: LazyLock<Mutex<HashMap<Uuid, WsClient>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

/// Events received from WebSocket
#[derive(Debug, Clone)]
pub enum WsEvent {
    Connected,
    Disconnected,
    /// Sync response: compacted snapshot from server (base64 encoded)
    SyncResponse(String),
    /// Update from another peer: raw CRDT update (base64 encoded)
    Update(String),
    /// Awareness update (JSON string)
    Awareness(String),
    /// Server error
    ServerError {
        code: String,
        message: String,
    },
    /// Connection/transport error
    Error(String),
}

/// Outbound message types
#[derive(Debug)]
enum OutboundMsg {
    SyncRequest,
    Update(Vec<u8>),
    EncryptedUpdate(Vec<u8>),
    Awareness(rmpv::Value),
}

/// Callbacks retrieved from Lua globals
#[derive(Clone)]
struct WsCallbacks {
    on_connect: Option<LuaFunction>,
    on_disconnect: Option<LuaFunction>,
    on_sync_response: Option<LuaFunction>,
    on_update: Option<LuaFunction>,
    on_awareness: Option<LuaFunction>,
    on_server_error: Option<LuaFunction>,
    on_error: Option<LuaFunction>,
}

impl WsCallbacks {
    /// Read callbacks from Lua global table: _G["_TANDEM_NVIM"].ws.callbacks[client_id]
    fn from_lua(client_id: Uuid) -> Result<Self, String> {
        let lua = lua();
        let callbacks = lua
            .globals()
            .get::<LuaTable>("_TANDEM_NVIM")
            .map_err(|e| format!("Failed to get _TANDEM_NVIM: {}", e))?
            .get::<LuaTable>("ws")
            .map_err(|e| format!("Failed to get ws: {}", e))?
            .get::<LuaTable>("callbacks")
            .map_err(|e| format!("Failed to get callbacks: {}", e))?
            .get::<LuaTable>(client_id.to_string())
            .map_err(|e| format!("Failed to get callbacks for {}: {}", client_id, e))?;

        Ok(Self {
            on_connect: callbacks
                .get::<Option<LuaFunction>>("on_connect")
                .map_err(|e| format!("Failed to get on_connect: {}", e))?,
            on_disconnect: callbacks
                .get::<Option<LuaFunction>>("on_disconnect")
                .map_err(|e| format!("Failed to get on_disconnect: {}", e))?,
            on_sync_response: callbacks
                .get::<Option<LuaFunction>>("on_sync_response")
                .map_err(|e| format!("Failed to get on_sync_response: {}", e))?,
            on_update: callbacks
                .get::<Option<LuaFunction>>("on_update")
                .map_err(|e| format!("Failed to get on_update: {}", e))?,
            on_awareness: callbacks
                .get::<Option<LuaFunction>>("on_awareness")
                .map_err(|e| format!("Failed to get on_awareness: {}", e))?,
            on_server_error: callbacks
                .get::<Option<LuaFunction>>("on_server_error")
                .map_err(|e| format!("Failed to get on_server_error: {}", e))?,
            on_error: callbacks
                .get::<Option<LuaFunction>>("on_error")
                .map_err(|e| format!("Failed to get on_error: {}", e))?,
        })
    }
}

/// A WebSocket client instance
struct WsClient {
    id: Uuid,
    #[allow(dead_code)]
    url: String,
    outbound_tx: UnboundedSender<OutboundMsg>,
    close_tx: UnboundedSender<()>,
    #[allow(dead_code)]
    lua_handle: AsyncHandle,
    /// Optional E2E encryption key (base64url-encoded)
    encryption_key: Option<Arc<String>>,
}

impl WsClient {
    fn new(client_id: Uuid, url: String, encryption_key: Option<String>) -> Result<Self, String> {
        let parsed_url = Url::parse(&url).map_err(|e| format!("Invalid URL: {}", e))?;

        // Wrap encryption key in Arc for sharing with async task
        let encryption_key = encryption_key.map(Arc::new);

        // Read callbacks from Lua globals (must be registered before connect)
        let callbacks = WsCallbacks::from_lua(client_id)?;

        // Channel for inbound events (from WS task to AsyncHandle)
        let (inbound_tx, mut inbound_rx) = mpsc::unbounded_channel::<WsEvent>();

        // Channel for outbound messages (from FFI to WS task)
        let (outbound_tx, outbound_rx) = mpsc::unbounded_channel::<OutboundMsg>();

        // Channel for close signal
        let (close_tx, close_rx) = mpsc::unbounded_channel::<()>();

        // Create AsyncHandle that will invoke Lua callbacks when events arrive
        // IMPORTANT: libuv async handles coalesce multiple send() calls into one callback,
        // so we must drain ALL pending events, not just one.
        let lua_handle = AsyncHandle::new(move || {
            // Drain all pending events from the channel
            // Use try_recv in a loop to get all buffered events
            let mut events = Vec::new();
            loop {
                match inbound_rx.try_recv() {
                    Ok(event) => events.push(event),
                    Err(mpsc::error::TryRecvError::Empty) => break,
                    Err(mpsc::error::TryRecvError::Disconnected) => break,
                }
            }

            if events.is_empty() {
                return Ok::<_, nvim_oxi::Error>(());
            }

            debug!(
                "[ws:{}] AsyncHandle draining {} event(s)",
                client_id,
                events.len()
            );

            let callbacks = callbacks.clone();
            let id_str = client_id.to_string();

            // Schedule callback invocations on Neovim's main thread
            // Process all events in order within a single schedule call
            schedule(move |_| {
                for event in events {
                    let id = id_str.clone();
                    match event {
                        WsEvent::Connected => {
                            if let Some(ref cb) = callbacks.on_connect
                                && let Err(e) = cb.call::<()>(id)
                            {
                                error!("[ws] on_connect callback error: {}", e);
                            }
                        }
                        WsEvent::Disconnected => {
                            if let Some(ref cb) = callbacks.on_disconnect
                                && let Err(e) = cb.call::<()>(id)
                            {
                                error!("[ws] on_disconnect callback error: {}", e);
                            }
                        }
                        WsEvent::SyncResponse(data_b64) => {
                            if let Some(ref cb) = callbacks.on_sync_response
                                && let Err(e) = cb.call::<()>((id, data_b64))
                            {
                                error!("[ws] on_sync_response callback error: {}", e);
                            }
                        }
                        WsEvent::Update(data_b64) => {
                            if let Some(ref cb) = callbacks.on_update
                                && let Err(e) = cb.call::<()>((id, data_b64))
                            {
                                error!("[ws] on_update callback error: {}", e);
                            }
                        }
                        WsEvent::Awareness(json) => {
                            if let Some(ref cb) = callbacks.on_awareness
                                && let Err(e) = cb.call::<()>((id, json))
                            {
                                error!("[ws] on_awareness callback error: {}", e);
                            }
                        }
                        WsEvent::ServerError { code, message } => {
                            if let Some(ref cb) = callbacks.on_server_error
                                && let Err(e) = cb.call::<()>((id, code, message))
                            {
                                error!("[ws] on_server_error callback error: {}", e);
                            }
                        }
                        WsEvent::Error(err) => {
                            if let Some(ref cb) = callbacks.on_error
                                && let Err(e) = cb.call::<()>((id, err))
                            {
                                error!("[ws] on_error callback error: {}", e);
                            }
                        }
                    }
                }
                Ok::<(), nvim_oxi::Error>(())
            });

            Ok::<_, nvim_oxi::Error>(())
        })
        .map_err(|e| format!("Failed to create AsyncHandle: {}", e))?;

        // Clone handle for the async task
        let lua_handle_clone = lua_handle.clone();
        let inbound_tx_clone = inbound_tx.clone();
        let id = client_id;
        let encryption_key_clone = encryption_key.clone();

        // Spawn WebSocket task
        runtime().spawn(async move {
            if let Err(e) = run_ws_client(
                id,
                parsed_url,
                inbound_tx_clone.clone(),
                &lua_handle_clone,
                outbound_rx,
                close_rx,
                encryption_key_clone,
            )
            .await
            {
                error!("[ws:{}] WebSocket error: {}", id, e);
                let _ = inbound_tx_clone.send(WsEvent::Error(e.to_string()));
                let _ = lua_handle_clone.send();
            }

            // Send disconnect event
            let _ = inbound_tx_clone.send(WsEvent::Disconnected);
            let _ = lua_handle_clone.send();

            // Remove from registry
            CLIENTS.lock().remove(&id);
            info!("[ws:{}] Client removed from registry", id);
        });

        Ok(Self {
            id: client_id,
            url,
            outbound_tx,
            close_tx,
            lua_handle,
            encryption_key,
        })
    }

    fn send_sync_request(&self) {
        if let Err(e) = self.outbound_tx.send(OutboundMsg::SyncRequest) {
            error!("[ws:{}] Failed to queue sync request: {}", self.id, e);
        }
    }

    fn send_update(&self, data: Vec<u8>) {
        // If encryption is enabled, encrypt and send as EncryptedUpdate
        // Otherwise, send as regular Update
        if let Some(ref key) = self.encryption_key {
            info!(
                "[ws:{}] Encrypting update ({} bytes plaintext)",
                self.id,
                data.len()
            );
            match crypto::encrypt(key, &data) {
                Ok(encrypted_b64) => {
                    // Decode the base64url string back to bytes for sending
                    match Base64UrlUnpadded::decode_vec(&encrypted_b64) {
                        Ok(encrypted_bytes) => {
                            info!(
                                "[ws:{}] Sending EncryptedUpdate ({} bytes ciphertext)",
                                self.id,
                                encrypted_bytes.len()
                            );
                            if let Err(e) = self
                                .outbound_tx
                                .send(OutboundMsg::EncryptedUpdate(encrypted_bytes))
                            {
                                error!("[ws:{}] Failed to queue encrypted update: {}", self.id, e);
                            }
                        }
                        Err(e) => {
                            error!("[ws:{}] Failed to decode encrypted data: {}", self.id, e);
                        }
                    }
                }
                Err(e) => {
                    error!("[ws:{}] Encryption failed: {}", self.id, e);
                }
            }
        } else {
            debug!(
                "[ws:{}] Sending unencrypted Update ({} bytes)",
                self.id,
                data.len()
            );
            if let Err(e) = self.outbound_tx.send(OutboundMsg::Update(data)) {
                error!("[ws:{}] Failed to queue update: {}", self.id, e);
            }
        }
    }

    fn send_awareness(&self, value: rmpv::Value) {
        if let Err(e) = self.outbound_tx.send(OutboundMsg::Awareness(value)) {
            error!("[ws:{}] Failed to queue awareness: {}", self.id, e);
        }
    }

    fn disconnect(&self) {
        let _ = self.close_tx.send(());
    }
}

/// Run the WebSocket client connection
async fn run_ws_client(
    id: Uuid,
    url: Url,
    event_tx: UnboundedSender<WsEvent>,
    lua_handle: &AsyncHandle,
    mut outbound_rx: UnboundedReceiver<OutboundMsg>,
    mut close_rx: UnboundedReceiver<()>,
    encryption_key: Option<Arc<String>>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    info!("[ws:{}] Connecting to {}", id, url);

    // Helper to send event and notify Lua
    let send_event = |event: WsEvent| {
        if let Err(e) = event_tx.send(event) {
            error!("[ws:{}] Failed to send event: {}", id, e);
        }
        if let Err(e) = lua_handle.send() {
            error!("[ws:{}] Failed to notify Lua: {}", id, e);
        }
    };

    // Connect
    let ws_stream = match tokio_tungstenite::connect_async(url.as_str()).await {
        Ok((stream, _response)) => {
            info!("[ws:{}] Connected", id);
            send_event(WsEvent::Connected);
            stream
        }
        Err(e) => {
            error!("[ws:{}] Connection failed: {}", id, e);
            return Err(format!("Connection failed: {}", e).into());
        }
    };

    let (mut ws_tx, mut ws_rx) = ws_stream.split();

    loop {
        tokio::select! {
            // Receive from WebSocket
            msg = ws_rx.next() => {
                match msg {
                    Some(Ok(Message::Binary(data))) => {
                        debug!("[ws:{}] Received binary ({} bytes)", id, data.len());
                        if let Some(server_msg) = ServerMsg::parse(&data) {
                            match server_msg {
                                ServerMsg::SyncResponse(snapshot) => {
                                    // SyncResponse from server is NOT encrypted
                                    // (Server can't store/compact encrypted data, so E2E sessions
                                    // will have empty SyncResponse and rely on EncryptedUpdate from peers)
                                    debug!("[ws:{}] SyncResponse ({} bytes)", id, snapshot.len());
                                    let b64 = base64::engine::general_purpose::STANDARD.encode(&snapshot);
                                    send_event(WsEvent::SyncResponse(b64));
                                }
                                ServerMsg::Update(update_data) => {
                                    // Regular Update - should only be received when NOT using E2E encryption
                                    debug!("[ws:{}] Update ({} bytes)", id, update_data.len());
                                    let b64 = base64::engine::general_purpose::STANDARD.encode(&update_data);
                                    send_event(WsEvent::Update(b64));
                                }
                                ServerMsg::EncryptedUpdate(encrypted_data) => {
                                    // E2E encrypted update - decrypt and send as regular Update event
                                    info!("[ws:{}] EncryptedUpdate received ({} bytes)", id, encrypted_data.len());
                                    if let Some(ref key) = encryption_key {
                                        if encrypted_data.is_empty() {
                                            warn!("[ws:{}] Received empty EncryptedUpdate", id);
                                            send_event(WsEvent::Update(String::new()));
                                        } else {
                                            // Convert to base64url for decryption
                                            let encrypted_b64 = Base64UrlUnpadded::encode_string(&encrypted_data);
                                            match crypto::decrypt(key, &encrypted_b64) {
                                                Ok(decrypted) => {
                                                    info!("[ws:{}] Decrypted update: {} bytes", id, decrypted.len());
                                                    let b64 = base64::engine::general_purpose::STANDARD.encode(&decrypted);
                                                    send_event(WsEvent::Update(b64));
                                                }
                                                Err(e) => {
                                                    error!("[ws:{}] EncryptedUpdate decryption FAILED: {}", id, e);
                                                }
                                            }
                                        }
                                    } else {
                                        error!("[ws:{}] Received EncryptedUpdate but no encryption key configured!", id);
                                    }
                                }
                                ServerMsg::Awareness(value) => {
                                    debug!("[ws:{}] Awareness update", id);
                                    let json = serde_json::to_string(&value).unwrap_or_default();
                                    send_event(WsEvent::Awareness(json));
                                }
                                ServerMsg::Error { code, message } => {
                                    warn!("[ws:{}] Server error: {} - {}", id, code, message);
                                    send_event(WsEvent::ServerError { code, message });
                                }
                            }
                        } else {
                            warn!("[ws:{}] Failed to parse server message", id);
                        }
                    }
                    Some(Ok(Message::Text(text))) => {
                        warn!("[ws:{}] Received unexpected text: {}", id, text);
                    }
                    Some(Ok(Message::Close(_))) => {
                        info!("[ws:{}] Server closed connection", id);
                        break;
                    }
                    Some(Ok(_)) => {
                        // Ping/Pong handled automatically
                    }
                    Some(Err(e)) => {
                        error!("[ws:{}] Receive error: {}", id, e);
                        send_event(WsEvent::Error(format!("Receive error: {}", e)));
                        break;
                    }
                    None => {
                        info!("[ws:{}] WebSocket stream ended", id);
                        break;
                    }
                }
            }

            // Send outbound messages
            msg = outbound_rx.recv() => {
                if let Some(out_msg) = msg {
                    let data = match out_msg {
                        OutboundMsg::SyncRequest => {
                            debug!("[ws:{}] Sending SyncRequest", id);
                            ClientMsg::sync_request()
                        }
                        OutboundMsg::Update(update) => {
                            debug!("[ws:{}] Sending Update ({} bytes)", id, update.len());
                            ClientMsg::update(update)
                        }
                        OutboundMsg::EncryptedUpdate(encrypted) => {
                            debug!("[ws:{}] Sending EncryptedUpdate ({} bytes)", id, encrypted.len());
                            ClientMsg::encrypted_update(encrypted)
                        }
                        OutboundMsg::Awareness(value) => {
                            debug!("[ws:{}] Sending Awareness", id);
                            ClientMsg::awareness(value)
                        }
                    };
                    if let Err(e) = ws_tx.send(Message::Binary(data.into())).await {
                        error!("[ws:{}] Send error: {}", id, e);
                        send_event(WsEvent::Error(format!("Send error: {}", e)));
                    }
                }
            }

            // Handle close request
            _ = close_rx.recv() => {
                info!("[ws:{}] Close requested", id);
                let _ = ws_tx.send(Message::Close(None)).await;
                break;
            }
        }
    }

    Ok(())
}

// ============================================================================
// FFI Functions
// ============================================================================

/// Connect to a WebSocket URL with optional E2E encryption.
/// IMPORTANT: Callbacks must be registered in _G["_TANDEM_NVIM"].ws.callbacks[client_id] BEFORE calling this.
/// Args: (client_id, url, encryption_key) - encryption_key is empty string if not using E2EE
fn ws_connect((client_id, url, encryption_key): (String, String, String)) -> bool {
    let id = match Uuid::parse_str(&client_id) {
        Ok(id) => id,
        Err(e) => {
            error!("Invalid client ID '{}': {}", client_id, e);
            return false;
        }
    };

    // Convert empty string to None for encryption key
    let key = if encryption_key.is_empty() {
        None
    } else {
        Some(encryption_key)
    };

    match WsClient::new(id, url, key.clone()) {
        Ok(client) => {
            let is_encrypted = client.encryption_key.is_some();
            CLIENTS.lock().insert(id, client);
            info!(
                "[ws:{}] Client created and connecting (encrypted: {})",
                id, is_encrypted
            );
            true
        }
        Err(e) => {
            error!("[ws:{}] Failed to create client: {}", id, e);
            false
        }
    }
}

/// Disconnect a WebSocket client by ID.
fn ws_disconnect(client_id: String) {
    let id = match Uuid::parse_str(&client_id) {
        Ok(id) => id,
        Err(e) => {
            warn!("Invalid client ID '{}': {}", client_id, e);
            return;
        }
    };

    let clients = CLIENTS.lock();
    if let Some(client) = clients.get(&id) {
        client.disconnect();
    }
}

/// Send a sync request
fn ws_send_sync_request(client_id: String) {
    let id = match Uuid::parse_str(&client_id) {
        Ok(id) => id,
        Err(e) => {
            warn!("Invalid client ID '{}': {}", client_id, e);
            return;
        }
    };

    let clients = CLIENTS.lock();
    if let Some(client) = clients.get(&id) {
        client.send_sync_request();
    }
}

/// Send a CRDT update (base64-encoded, decoded here to raw binary)
fn ws_send_update((client_id, data_b64): (String, String)) {
    let id = match Uuid::parse_str(&client_id) {
        Ok(id) => id,
        Err(e) => {
            warn!("Invalid client ID '{}': {}", client_id, e);
            return;
        }
    };

    let data = match base64::engine::general_purpose::STANDARD.decode(&data_b64) {
        Ok(d) => d,
        Err(e) => {
            error!("Invalid base64 data: {}", e);
            return;
        }
    };

    let clients = CLIENTS.lock();
    if let Some(client) = clients.get(&id) {
        client.send_update(data);
    }
}

/// Send awareness update (as MessagePack value)
fn ws_send_awareness((client_id, awareness_json): (String, String)) {
    let id = match Uuid::parse_str(&client_id) {
        Ok(id) => id,
        Err(e) => {
            warn!("Invalid client ID '{}': {}", client_id, e);
            return;
        }
    };

    let value: rmpv::Value = match serde_json::from_str(&awareness_json) {
        Ok(v) => v,
        Err(e) => {
            error!("Invalid awareness JSON: {}", e);
            return;
        }
    };

    let clients = CLIENTS.lock();
    if let Some(client) = clients.get(&id) {
        client.send_awareness(value);
    }
}

/// Check if a client exists in registry
fn ws_is_connected(client_id: String) -> bool {
    let id = match Uuid::parse_str(&client_id) {
        Ok(id) => id,
        Err(_) => return false,
    };

    CLIENTS.lock().contains_key(&id)
}

/// Generate a new UUID for a client (called from Lua before registering callbacks)
fn ws_generate_client_id() -> String {
    Uuid::new_v4().to_string()
}

/// WebSocket FFI module
pub fn ws_ffi() -> Dictionary {
    Dictionary::from_iter([
        (
            "generate_client_id",
            Object::from(Function::<(), String>::from_fn(
                |_| -> Result<String, nvim_oxi::Error> { Ok(ws_generate_client_id()) },
            )),
        ),
        (
            "connect",
            Object::from(Function::<(String, String, String), bool>::from_fn(
                |args| -> Result<bool, nvim_oxi::Error> { Ok(ws_connect(args)) },
            )),
        ),
        (
            "disconnect",
            Object::from(Function::<String, ()>::from_fn(
                |id| -> Result<(), nvim_oxi::Error> {
                    ws_disconnect(id);
                    Ok(())
                },
            )),
        ),
        (
            "send_sync_request",
            Object::from(Function::<String, ()>::from_fn(
                |id| -> Result<(), nvim_oxi::Error> {
                    ws_send_sync_request(id);
                    Ok(())
                },
            )),
        ),
        (
            "send_update",
            Object::from(Function::<(String, String), ()>::from_fn(
                |args| -> Result<(), nvim_oxi::Error> {
                    ws_send_update(args);
                    Ok(())
                },
            )),
        ),
        (
            "send_awareness",
            Object::from(Function::<(String, String), ()>::from_fn(
                |args| -> Result<(), nvim_oxi::Error> {
                    ws_send_awareness(args);
                    Ok(())
                },
            )),
        ),
        (
            "is_connected",
            Object::from(Function::<String, bool>::from_fn(
                |id| -> Result<bool, nvim_oxi::Error> { Ok(ws_is_connected(id)) },
            )),
        ),
    ])
}

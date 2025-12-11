//! Iroh P2P client module with callback-based event delivery
//!
//! Uses `AsyncHandle` to immediately deliver P2P events to Lua callbacks,
//! mirroring the pattern from ws.rs but for direct peer connections via Iroh.
//!
//! QUIC/TLS 1.3 provides E2E encryption automatically - no manual crypto needed.

use base64::Engine;
use iroh::{Endpoint, EndpointAddr, RelayMode, RelayUrl, SecretKey, TransportAddr};
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
use uuid::Uuid;

use crate::runtime;

/// ALPN protocol identifier for tandem CRDT sync
const TANDEM_ALPN: &[u8] = b"tandem/crdt/1";

/// Global registry of Iroh clients
static CLIENTS: LazyLock<Mutex<HashMap<Uuid, IrohClient>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

/// Events received from Iroh P2P
#[derive(Debug, Clone)]
pub enum IrohEvent {
    /// Endpoint is online and ready
    Ready {
        endpoint_id: String,
        relay_url: String,
    },
    /// A peer connected (host only)
    PeerConnected { peer_id: String },
    /// A peer disconnected
    PeerDisconnected { peer_id: String },
    /// Received full CRDT state (base64 encoded)
    FullState(String),
    /// Received CRDT update (base64 encoded)
    Update(String),
    /// Error occurred
    Error(String),
}

/// Outbound message types
#[derive(Debug, Clone)]
enum OutboundMsg {
    /// Send full CRDT state to peer
    FullState(Vec<u8>),
    /// Send incremental CRDT update
    Update(Vec<u8>),
}

/// Helper to invoke a Lua callback by name from the global registry
/// Must be called from within a schedule() block
fn invoke_callback(client_id: &str, callback_name: &str, args: impl nvim_oxi::mlua::IntoLuaMulti) {
    let lua_state = lua();
    let result: Result<(), String> = (|| {
        let callbacks = lua_state
            .globals()
            .get::<LuaTable>("_TANDEM_NVIM")
            .map_err(|e| format!("No _TANDEM_NVIM: {}", e))?
            .get::<LuaTable>("iroh")
            .map_err(|e| format!("No iroh: {}", e))?
            .get::<LuaTable>("callbacks")
            .map_err(|e| format!("No callbacks: {}", e))?
            .get::<LuaTable>(client_id)
            .map_err(|e| format!("No callbacks for {}: {}", client_id, e))?;

        if let Ok(Some(cb)) = callbacks.get::<Option<LuaFunction>>(callback_name)
            && let Err(e) = cb.call::<()>(args)
        {
            error!("[iroh] {} callback error: {}", callback_name, e);
        }
        Ok(())
    })();

    if let Err(e) = result {
        debug!("[iroh] Failed to invoke {}: {}", callback_name, e);
    }
}

/// An Iroh P2P client instance
struct IrohClient {
    id: Uuid,
    outbound_tx: UnboundedSender<OutboundMsg>,
    close_tx: UnboundedSender<()>,
    #[allow(dead_code)]
    lua_handle: AsyncHandle, // Keep alive to receive async notifications
}

impl IrohClient {
    fn new_host(client_id: Uuid) -> Result<Self, String> {
        info!("[iroh:{}] Creating host client", client_id);
        Self::new(client_id, true, None)
    }

    fn new_joiner(client_id: Uuid, session_code: String) -> Result<Self, String> {
        info!("[iroh:{}] Creating joiner client", client_id);
        Self::new(client_id, false, Some(session_code))
    }

    fn new(client_id: Uuid, is_host: bool, session_code: Option<String>) -> Result<Self, String> {
        info!(
            "[iroh:{}] Initializing client (is_host={})",
            client_id, is_host
        );

        // Channel for inbound events (from Iroh task to AsyncHandle)
        let (inbound_tx, mut inbound_rx) = mpsc::unbounded_channel::<IrohEvent>();

        // Channel for outbound messages (from FFI to Iroh task)
        let (outbound_tx, outbound_rx) = mpsc::unbounded_channel::<OutboundMsg>();

        // Channel for close signal
        let (close_tx, close_rx) = mpsc::unbounded_channel::<()>();

        // Create AsyncHandle that will invoke Lua callbacks when events arrive
        // Callbacks are looked up lazily inside schedule() to avoid holding LuaFunction across threads
        let id_str = client_id.to_string();
        let lua_handle = AsyncHandle::new(move || {
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
                "[iroh:{}] AsyncHandle draining {} event(s)",
                id_str,
                events.len()
            );

            let client_id_for_schedule = id_str.clone();

            // Schedule callback invocations on Neovim's main thread
            // Look up callbacks fresh each time (safer than holding LuaFunction)
            schedule(move |_| {
                for event in events {
                    let id = client_id_for_schedule.clone();
                    match event {
                        IrohEvent::Ready {
                            endpoint_id,
                            relay_url,
                        } => {
                            invoke_callback(&id, "on_ready", (id.clone(), endpoint_id, relay_url));
                        }
                        IrohEvent::PeerConnected { peer_id } => {
                            invoke_callback(&id, "on_peer_connected", (id.clone(), peer_id));
                        }
                        IrohEvent::PeerDisconnected { peer_id } => {
                            invoke_callback(&id, "on_peer_disconnected", (id.clone(), peer_id));
                        }
                        IrohEvent::FullState(data_b64) => {
                            invoke_callback(&id, "on_full_state", (id.clone(), data_b64));
                        }
                        IrohEvent::Update(data_b64) => {
                            invoke_callback(&id, "on_update", (id.clone(), data_b64));
                        }
                        IrohEvent::Error(err) => {
                            invoke_callback(&id, "on_error", (id.clone(), err));
                        }
                    }
                }
                Ok::<(), nvim_oxi::Error>(())
            });

            Ok::<_, nvim_oxi::Error>(())
        })
        .map_err(|e| format!("Failed to create AsyncHandle: {}", e))?;

        info!("[iroh:{}] AsyncHandle created", client_id);

        // Clone for async task
        let lua_handle_clone = lua_handle.clone();
        let inbound_tx_clone = inbound_tx.clone();
        let id = client_id;

        // Spawn Iroh task
        runtime().spawn(async move {
            info!("[iroh:{}] Async task started", id);
            let result = if is_host {
                run_host(
                    id,
                    inbound_tx_clone.clone(),
                    &lua_handle_clone,
                    outbound_rx,
                    close_rx,
                )
                .await
            } else {
                let code = session_code.expect("session_code required for joiner");
                run_joiner(
                    id,
                    code,
                    inbound_tx_clone.clone(),
                    &lua_handle_clone,
                    outbound_rx,
                    close_rx,
                )
                .await
            };

            if let Err(e) = result {
                error!("[iroh:{}] Error: {}", id, e);
                let _ = inbound_tx_clone.send(IrohEvent::Error(e.to_string()));
                let _ = lua_handle_clone.send();
            }

            // Remove from registry
            CLIENTS.lock().remove(&id);
            info!("[iroh:{}] Client removed from registry", id);
        });

        info!("[iroh:{}] Client initialization complete", client_id);

        Ok(Self {
            id: client_id,
            outbound_tx,
            close_tx,
            lua_handle,
        })
    }

    fn send_full_state(&self, data: Vec<u8>) {
        if let Err(e) = self.outbound_tx.send(OutboundMsg::FullState(data)) {
            error!("[iroh:{}] Failed to queue full state: {}", self.id, e);
        }
    }

    fn send_update(&self, data: Vec<u8>) {
        if let Err(e) = self.outbound_tx.send(OutboundMsg::Update(data)) {
            error!("[iroh:{}] Failed to queue update: {}", self.id, e);
        }
    }

    fn close(&self) {
        let _ = self.close_tx.send(());
    }
}

/// Run the host (listening) endpoint
async fn run_host(
    id: Uuid,
    event_tx: UnboundedSender<IrohEvent>,
    lua_handle: &AsyncHandle,
    mut outbound_rx: UnboundedReceiver<OutboundMsg>,
    mut close_rx: UnboundedReceiver<()>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    info!("[iroh:{}] Starting host endpoint", id);

    let send_event = |event: IrohEvent| {
        if let Err(e) = event_tx.send(event) {
            error!("[iroh:{}] Failed to send event: {}", id, e);
        }
        if let Err(e) = lua_handle.send() {
            error!("[iroh:{}] Failed to notify Lua: {}", id, e);
        }
    };

    // Generate secret key for this endpoint
    let secret_key = SecretKey::generate(&mut rand::rng());

    // Build endpoint
    let endpoint = Endpoint::builder()
        .secret_key(secret_key)
        .alpns(vec![TANDEM_ALPN.to_vec()])
        .relay_mode(RelayMode::Default)
        .bind()
        .await?;

    // Wait for endpoint to be online
    endpoint.online().await;

    let endpoint_id = endpoint.id().to_string();
    let endpoint_addr = endpoint.addr();
    let relay_url = endpoint_addr
        .relay_urls()
        .next()
        .map(|u| u.to_string())
        .unwrap_or_default();

    info!(
        "[iroh:{}] Host ready: endpoint_id={}, relay_url={}",
        id, endpoint_id, relay_url
    );

    send_event(IrohEvent::Ready {
        endpoint_id,
        relay_url,
    });

    // Track connected peers and their send channels
    let peers: Arc<Mutex<HashMap<String, UnboundedSender<OutboundMsg>>>> =
        Arc::new(Mutex::new(HashMap::new()));

    loop {
        tokio::select! {
            // Accept incoming connections
            incoming = endpoint.accept() => {
                if let Some(incoming) = incoming {
                    match incoming.accept() {
                        Ok(accepting) => {
                            let event_tx = event_tx.clone();
                            let lua_handle = lua_handle.clone();
                            let host_id = id;

                            // Create per-peer channel
                            let (peer_tx, peer_rx) = mpsc::unbounded_channel::<OutboundMsg>();
                            let peer_id_holder: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));

                            // Clone for the connection handler
                            let peer_id_holder_for_handler = peer_id_holder.clone();
                            let peers_for_handler = peers.clone();

                            tokio::spawn(async move {
                                if let Err(e) = handle_peer_connection(
                                    host_id,
                                    accepting,
                                    event_tx,
                                    &lua_handle,
                                    peer_rx,
                                    peer_id_holder_for_handler.clone(),
                                ).await {
                                    error!("[iroh:{}] Peer connection error: {}", host_id, e);
                                }
                                // Cleanup: remove from peers map
                                if let Some(peer_id) = peer_id_holder_for_handler.lock().take() {
                                    peers_for_handler.lock().remove(&peer_id);
                                }
                            });

                            // Store sender with temporary key
                            let temp_key = format!("pending_{}", uuid::Uuid::new_v4());
                            peers.lock().insert(temp_key.clone(), peer_tx);

                            // Spawn a task to update the key once peer_id is known
                            let peers_for_update = peers.clone();
                            let peer_id_holder_for_update = peer_id_holder.clone();
                            tokio::spawn(async move {
                                // Wait a bit for the peer_id to be set
                                tokio::time::sleep(std::time::Duration::from_millis(100)).await;
                                if let Some(real_peer_id) = peer_id_holder_for_update.lock().clone() {
                                    let mut peers_guard = peers_for_update.lock();
                                    if let Some(tx) = peers_guard.remove(&temp_key) {
                                        peers_guard.insert(real_peer_id, tx);
                                    }
                                }
                            });
                        }
                        Err(e) => {
                            warn!("[iroh:{}] Failed to accept connection: {}", id, e);
                        }
                    }
                }
            }

            // Handle outbound messages (broadcast to all peers)
            msg = outbound_rx.recv() => {
                if let Some(msg) = msg {
                    let peers_guard = peers.lock();
                    for (peer_id, tx) in peers_guard.iter() {
                        if let Err(e) = tx.send(msg.clone()) {
                            warn!("[iroh:{}] Failed to send to peer {}: {}", id, peer_id, e);
                        }
                    }
                }
            }

            // Handle close request
            _ = close_rx.recv() => {
                info!("[iroh:{}] Close requested", id);
                break;
            }
        }
    }

    endpoint.close().await;
    Ok(())
}

/// Read a length-prefixed message from stream
async fn read_message(
    recv: &mut iroh::endpoint::RecvStream,
) -> Result<Vec<u8>, Box<dyn std::error::Error + Send + Sync>> {
    let mut len_buf = [0u8; 4];
    recv.read_exact(&mut len_buf).await?;
    let len = u32::from_be_bytes(len_buf) as usize;

    if len == 0 {
        return Ok(Vec::new());
    }

    let mut data = vec![0u8; len];
    recv.read_exact(&mut data).await?;
    Ok(data)
}

/// Write a length-prefixed message to stream
async fn write_message(
    send: &mut iroh::endpoint::SendStream,
    data: &[u8],
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let len = data.len() as u32;
    send.write_all(&len.to_be_bytes()).await?;
    if !data.is_empty() {
        send.write_all(data).await?;
    }
    Ok(())
}

/// Handle a peer connection (host side)
async fn handle_peer_connection(
    host_id: Uuid,
    accepting: iroh::endpoint::Accepting,
    event_tx: UnboundedSender<IrohEvent>,
    lua_handle: &AsyncHandle,
    mut peer_rx: UnboundedReceiver<OutboundMsg>,
    peer_id_out: Arc<Mutex<Option<String>>>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let conn = accepting.await?;
    let peer_id = conn.remote_id().to_string();

    info!("[iroh:{}] Peer connected: {}", host_id, peer_id);

    // Store peer_id so caller can clean up
    *peer_id_out.lock() = Some(peer_id.clone());

    // Notify Lua - this triggers on_peer_connected which calls send_full_state
    let _ = event_tx.send(IrohEvent::PeerConnected {
        peer_id: peer_id.clone(),
    });
    let _ = lua_handle.send();

    // Host opens the bidirectional stream (joiner will accept it)
    info!("[iroh:{}] Opening bi stream to peer", host_id);
    let (mut send, mut recv) = conn.open_bi().await?;
    info!("[iroh:{}] Bi stream opened", host_id);

    // Wait for initial state from Lua callback (with timeout)
    // The on_peer_connected callback calls send_full_state which queues the message
    info!("[iroh:{}] Waiting for initial state from Lua...", host_id);
    let initial = tokio::time::timeout(std::time::Duration::from_secs(5), peer_rx.recv()).await;

    match initial {
        Ok(Some(msg)) => {
            let data = match msg {
                OutboundMsg::FullState(d) | OutboundMsg::Update(d) => d,
            };
            info!(
                "[iroh:{}] Sending initial state to peer ({} bytes)",
                host_id,
                data.len()
            );
            write_message(&mut send, &data).await?;
        }
        Ok(None) => {
            warn!(
                "[iroh:{}] Outbound channel closed before initial state",
                host_id
            );
            write_message(&mut send, &[]).await?;
        }
        Err(_) => {
            warn!(
                "[iroh:{}] Timeout waiting for initial state, sending empty",
                host_id
            );
            write_message(&mut send, &[]).await?;
        }
    }

    loop {
        tokio::select! {
            // Receive from peer (length-prefixed)
            result = read_message(&mut recv) => {
                match result {
                    Ok(data) => {
                        if !data.is_empty() {
                            info!("[iroh:{}] Received update from peer ({} bytes)", host_id, data.len());
                            let b64 = base64::engine::general_purpose::STANDARD.encode(&data);
                            let _ = event_tx.send(IrohEvent::Update(b64));
                            let _ = lua_handle.send();
                        }
                    }
                    Err(e) => {
                        warn!("[iroh:{}] Peer {} read error: {}", host_id, peer_id, e);
                        break;
                    }
                }
            }

            // Send to peer (length-prefixed)
            msg = peer_rx.recv() => {
                if let Some(msg) = msg {
                    let data = match msg {
                        OutboundMsg::FullState(d) => d,
                        OutboundMsg::Update(d) => d,
                    };
                    info!("[iroh:{}] Sending update to peer ({} bytes)", host_id, data.len());
                    if let Err(e) = write_message(&mut send, &data).await {
                        error!("[iroh:{}] Failed to send to peer {}: {}", host_id, peer_id, e);
                        break;
                    }
                }
            }
        }
    }

    // Cleanup
    let _ = event_tx.send(IrohEvent::PeerDisconnected { peer_id });
    let _ = lua_handle.send();

    Ok(())
}

/// Run the joiner (connecting) endpoint
async fn run_joiner(
    id: Uuid,
    session_code: String,
    event_tx: UnboundedSender<IrohEvent>,
    lua_handle: &AsyncHandle,
    mut outbound_rx: UnboundedReceiver<OutboundMsg>,
    mut close_rx: UnboundedReceiver<()>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    info!("[iroh:{}] Starting joiner endpoint", id);

    let send_event = |event: IrohEvent| {
        if let Err(e) = event_tx.send(event) {
            error!("[iroh:{}] Failed to send event: {}", id, e);
        }
        if let Err(e) = lua_handle.send() {
            error!("[iroh:{}] Failed to notify Lua: {}", id, e);
        }
    };

    // Decode session code to get host's endpoint_id and relay_url
    let (host_endpoint_id, host_relay_url) = crate::code::decode_p2p_session_code(&session_code)
        .map_err(|e| format!("Invalid session code: {}", e))?;

    info!(
        "[iroh:{}] Connecting to host: endpoint_id={}, relay_url={}",
        id, host_endpoint_id, host_relay_url
    );

    // Generate our own secret key
    let secret_key = SecretKey::generate(&mut rand::rng());

    // Build endpoint
    let endpoint = Endpoint::builder()
        .secret_key(secret_key)
        .alpns(vec![TANDEM_ALPN.to_vec()])
        .relay_mode(RelayMode::Default)
        .bind()
        .await?;

    endpoint.online().await;

    let our_endpoint_id = endpoint.id().to_string();
    let our_addr = endpoint.addr();
    let our_relay_url = our_addr
        .relay_urls()
        .next()
        .map(|u| u.to_string())
        .unwrap_or_default();

    send_event(IrohEvent::Ready {
        endpoint_id: our_endpoint_id,
        relay_url: our_relay_url,
    });

    // Parse host's endpoint ID
    let host_id: iroh::EndpointId = host_endpoint_id
        .parse()
        .map_err(|e| format!("Invalid endpoint ID: {}", e))?;

    // Parse host's relay URL
    let relay_url: RelayUrl = host_relay_url
        .parse()
        .map_err(|e| format!("Invalid relay URL: {}", e))?;

    // Build address for the host
    let addr = EndpointAddr::from_parts(host_id, std::iter::once(TransportAddr::Relay(relay_url)));

    // Connect to host
    let conn = endpoint.connect(addr, TANDEM_ALPN).await?;
    let peer_id = conn.remote_id().to_string();

    info!("[iroh:{}] Connected to host: {}", id, peer_id);
    send_event(IrohEvent::PeerConnected {
        peer_id: peer_id.clone(),
    });

    // Accept bidirectional stream from host
    info!("[iroh:{}] Waiting for host to open bi stream...", id);
    let (mut send, mut recv) = conn.accept_bi().await?;
    info!("[iroh:{}] Bi stream accepted", id);

    // First, receive full state from host (length-prefixed)
    info!("[iroh:{}] Waiting for initial state from host...", id);
    let initial_data = read_message(&mut recv).await?;
    info!(
        "[iroh:{}] Received initial state ({} bytes)",
        id,
        initial_data.len()
    );
    if !initial_data.is_empty() {
        let b64 = base64::engine::general_purpose::STANDARD.encode(&initial_data);
        send_event(IrohEvent::FullState(b64));
    }

    loop {
        tokio::select! {
            // Receive updates from host (length-prefixed)
            result = read_message(&mut recv) => {
                match result {
                    Ok(data) => {
                        if !data.is_empty() {
                            info!("[iroh:{}] Received update from host ({} bytes)", id, data.len());
                            let b64 = base64::engine::general_purpose::STANDARD.encode(&data);
                            send_event(IrohEvent::Update(b64));
                        }
                    }
                    Err(e) => {
                        warn!("[iroh:{}] Host read error: {}", id, e);
                        break;
                    }
                }
            }

            // Send outbound messages (length-prefixed)
            msg = outbound_rx.recv() => {
                if let Some(msg) = msg {
                    let data = match msg {
                        OutboundMsg::FullState(d) => d,
                        OutboundMsg::Update(d) => d,
                    };
                    info!("[iroh:{}] Sending update to host ({} bytes)", id, data.len());
                    if let Err(e) = write_message(&mut send, &data).await {
                        error!("[iroh:{}] Failed to send: {}", id, e);
                        break;
                    }
                }
            }

            // Handle close request
            _ = close_rx.recv() => {
                info!("[iroh:{}] Close requested", id);
                break;
            }
        }
    }

    send_event(IrohEvent::PeerDisconnected { peer_id });
    endpoint.close().await;
    Ok(())
}

// ============================================================================
// FFI Functions
// ============================================================================

/// Start hosting a P2P session
/// IMPORTANT: Callbacks must be registered in _G["_TANDEM_NVIM"].iroh.callbacks[client_id] BEFORE calling
fn iroh_host(client_id: String) -> bool {
    let id = match Uuid::parse_str(&client_id) {
        Ok(id) => id,
        Err(e) => {
            error!("Invalid client ID '{}': {}", client_id, e);
            return false;
        }
    };

    match IrohClient::new_host(id) {
        Ok(client) => {
            CLIENTS.lock().insert(id, client);
            info!("[iroh:{}] Host client created", id);
            true
        }
        Err(e) => {
            error!("[iroh:{}] Failed to create host: {}", id, e);
            false
        }
    }
}

/// Join a P2P session using a session code
/// IMPORTANT: Callbacks must be registered BEFORE calling
fn iroh_join((client_id, session_code): (String, String)) -> bool {
    let id = match Uuid::parse_str(&client_id) {
        Ok(id) => id,
        Err(e) => {
            error!("Invalid client ID '{}': {}", client_id, e);
            return false;
        }
    };

    match IrohClient::new_joiner(id, session_code) {
        Ok(client) => {
            CLIENTS.lock().insert(id, client);
            info!("[iroh:{}] Joiner client created", id);
            true
        }
        Err(e) => {
            error!("[iroh:{}] Failed to create joiner: {}", id, e);
            false
        }
    }
}

/// Send full CRDT state to peers (base64 encoded)
fn iroh_send_full_state((client_id, data_b64): (String, String)) {
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
        client.send_full_state(data);
    }
}

/// Send CRDT update to peers (base64 encoded)
fn iroh_send_update((client_id, data_b64): (String, String)) {
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

/// Close an Iroh client
fn iroh_close(client_id: String) {
    let id = match Uuid::parse_str(&client_id) {
        Ok(id) => id,
        Err(e) => {
            warn!("Invalid client ID '{}': {}", client_id, e);
            return;
        }
    };

    let clients = CLIENTS.lock();
    if let Some(client) = clients.get(&id) {
        client.close();
    }
}

/// Check if a client exists
fn iroh_is_connected(client_id: String) -> bool {
    let id = match Uuid::parse_str(&client_id) {
        Ok(id) => id,
        Err(_) => return false,
    };

    CLIENTS.lock().contains_key(&id)
}

/// Generate a new UUID for a client
fn iroh_generate_client_id() -> String {
    Uuid::new_v4().to_string()
}

/// Iroh FFI module
pub fn iroh_ffi() -> Dictionary {
    Dictionary::from_iter([
        (
            "generate_client_id",
            Object::from(Function::<(), String>::from_fn(
                |_| -> Result<String, nvim_oxi::Error> { Ok(iroh_generate_client_id()) },
            )),
        ),
        (
            "host",
            Object::from(Function::<String, bool>::from_fn(
                |id| -> Result<bool, nvim_oxi::Error> { Ok(iroh_host(id)) },
            )),
        ),
        (
            "join",
            Object::from(Function::<(String, String), bool>::from_fn(
                |args| -> Result<bool, nvim_oxi::Error> { Ok(iroh_join(args)) },
            )),
        ),
        (
            "send_full_state",
            Object::from(Function::<(String, String), ()>::from_fn(
                |args| -> Result<(), nvim_oxi::Error> {
                    iroh_send_full_state(args);
                    Ok(())
                },
            )),
        ),
        (
            "send_update",
            Object::from(Function::<(String, String), ()>::from_fn(
                |args| -> Result<(), nvim_oxi::Error> {
                    iroh_send_update(args);
                    Ok(())
                },
            )),
        ),
        (
            "close",
            Object::from(Function::<String, ()>::from_fn(
                |id| -> Result<(), nvim_oxi::Error> {
                    iroh_close(id);
                    Ok(())
                },
            )),
        ),
        (
            "is_connected",
            Object::from(Function::<String, bool>::from_fn(
                |id| -> Result<bool, nvim_oxi::Error> { Ok(iroh_is_connected(id)) },
            )),
        ),
    ])
}

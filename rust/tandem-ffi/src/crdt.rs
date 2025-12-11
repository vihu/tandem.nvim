use base64::Engine;
use log::{debug, error, info, warn};
use loro::{
    ContainerID, EventTriggerKind, ExportMode, LoroDoc, LoroText, Subscription, TextDelta,
    VersionVector, event::Diff,
};
use nvim_oxi::{Dictionary, Function, Object};
use parking_lot::Mutex;
use std::{
    collections::HashMap,
    sync::{Arc, LazyLock},
};
use uuid::Uuid;

/// Container ID for our root "content" text container
const CONTENT_CONTAINER_ID: &str = "cid:root-content:Text";

/// Global registry of CRDT documents
static DOCS: LazyLock<Mutex<HashMap<Uuid, CrdtDoc>>> = LazyLock::new(|| Mutex::new(HashMap::new()));

/// A TextDelta event for FFI serialization
/// Represents a single operation in the Quill delta format
#[derive(Debug, Clone)]
pub enum TextDeltaEvent {
    /// Skip forward by `len` bytes (no change)
    Retain { len: usize },
    /// Insert `text` at current position
    Insert { text: String },
    /// Delete `len` bytes at current position
    Delete { len: usize },
}

impl TextDeltaEvent {
    /// Serialize to JSON string for FFI
    fn to_json(&self) -> String {
        match self {
            TextDeltaEvent::Retain { len } => {
                format!("{{\"type\":\"retain\",\"len\":{}}}", len)
            }
            TextDeltaEvent::Insert { text } => {
                format!(
                    "{{\"type\":\"insert\",\"text\":{}}}",
                    serde_json::to_string(text).unwrap_or_else(|_| "\"\"".to_string())
                )
            }
            TextDeltaEvent::Delete { len } => {
                format!("{{\"type\":\"delete\",\"len\":{}}}", len)
            }
        }
    }
}

impl From<&TextDelta> for TextDeltaEvent {
    fn from(delta: &TextDelta) -> Self {
        match delta {
            TextDelta::Retain { retain, .. } => TextDeltaEvent::Retain { len: *retain },
            TextDelta::Insert { insert, .. } => TextDeltaEvent::Insert {
                text: insert.clone(),
            },
            TextDelta::Delete { delete } => TextDeltaEvent::Delete { len: *delete },
        }
    }
}

/// Thread-safe queue for pending TextDelta events from subscriptions
type DeltaQueue = Arc<Mutex<Vec<TextDeltaEvent>>>;

/// A CRDT document instance wrapping LoroDoc with LoroText
struct CrdtDoc {
    id: Uuid,
    doc: LoroDoc,
    /// Pending TextDelta events from remote updates (for Lua to poll)
    /// Uses Arc<Mutex<>> for thread-safe access from subscription callback
    pending_deltas: DeltaQueue,
    /// Subscription handle - must be kept alive for callbacks to fire
    #[allow(dead_code)]
    subscription: Option<Subscription>,
    /// Flag to track if we're applying a local edit (to avoid echoing)
    applying_local: bool,
    /// Last known text content (for debugging)
    last_text: String,
}

impl CrdtDoc {
    fn new(id: Uuid) -> Self {
        // Create empty LoroDoc - do NOT initialize containers
        // Containers are created lazily when first accessed for write,
        // or when importing from another peer's state
        let doc = LoroDoc::new();
        let pending_deltas: DeltaQueue = Arc::new(Mutex::new(Vec::new()));

        // Set up subscription to capture TextDelta events from imports
        let subscription = Self::setup_subscription(&doc, id, Arc::clone(&pending_deltas));

        Self {
            id,
            doc,
            pending_deltas,
            subscription: Some(subscription),
            applying_local: false,
            last_text: String::new(),
        }
    }

    /// Set up subscription to the root containers to capture TextDelta events
    fn setup_subscription(doc: &LoroDoc, id: Uuid, pending: DeltaQueue) -> Subscription {
        // Subscribe to all root containers - we'll filter for "content" text container
        doc.subscribe_root(Arc::new(move |event| {
            // Only process events from Import (remote updates)
            // Skip Local commits (our own edits) and Checkout (time travel)
            if !matches!(event.triggered_by, EventTriggerKind::Import) {
                return;
            }

            for container_diff in &event.events {
                // Check if this is our "content" text container
                // The container ID for root text is "cid:root-content:Text"
                let is_content = match &container_diff.target {
                    ContainerID::Root { name, .. } => name.as_str() == "content",
                    ContainerID::Normal { .. } => false,
                };

                if !is_content {
                    continue;
                }

                // Extract TextDelta events
                if let Diff::Text(deltas) = &container_diff.diff {
                    let delta_events: Vec<TextDeltaEvent> =
                        deltas.iter().map(TextDeltaEvent::from).collect();

                    if !delta_events.is_empty() {
                        debug!(
                            "[crdt:{}] Subscription received {} delta events from import",
                            id,
                            delta_events.len()
                        );
                        pending.lock().extend(delta_events);
                    }
                }
            }
        }))
    }

    /// Check if the "content" container exists in the document
    fn has_content(&self) -> bool {
        let container_id: ContainerID = CONTENT_CONTAINER_ID
            .try_into()
            .expect("invalid container ID constant");
        self.doc.has_container(&container_id)
    }

    /// Get the "content" text container, creating it if it doesn't exist.
    /// WARNING: This creates the container with this peer's ID if it doesn't exist.
    /// Only call this when you intend to write to the container.
    fn text_for_write(&self) -> LoroText {
        self.doc.get_text("content")
    }

    /// Get the text content. Returns empty string if container doesn't exist yet.
    fn get_text(&self) -> String {
        if self.has_content() {
            self.doc.get_text("content").to_string()
        } else {
            String::new()
        }
    }

    fn set_text(&mut self, content: &str) {
        self.applying_local = true;

        // Use text_for_write since we're modifying
        let text = self.text_for_write();
        let current_len = text.len_utf8();

        // Delete all existing content
        if current_len > 0
            && let Err(e) = text.delete_utf8(0, current_len)
        {
            error!("[crdt:{}] Failed to delete text: {}", self.id, e);
            self.applying_local = false;
            return;
        }

        // Insert new content
        if !content.is_empty()
            && let Err(e) = text.insert_utf8(0, content)
        {
            error!("[crdt:{}] Failed to insert text: {}", self.id, e);
            self.applying_local = false;
            return;
        }

        // Commit to trigger subscription (but we filter out local events)
        self.doc.commit();
        self.last_text = content.to_string();
        self.applying_local = false;
    }

    fn apply_edit(&mut self, start_byte: usize, end_byte: usize, new_text: &str) {
        self.applying_local = true;

        // Use text_for_write since we're modifying
        let text = self.text_for_write();
        let current_len = text.len_utf8();

        // Clamp start and end to valid range
        let start = start_byte.min(current_len);
        let end = end_byte.min(current_len);

        // Delete the range if non-empty and valid
        if end > start {
            let delete_len = end - start;
            if let Err(e) = text.delete_utf8(start, delete_len) {
                error!("[crdt:{}] Failed to delete range: {}", self.id, e);
                self.applying_local = false;
                return;
            }
        }

        // Insert new text at the (possibly clamped) start position
        if !new_text.is_empty()
            && let Err(e) = text.insert_utf8(start, new_text)
        {
            error!("[crdt:{}] Failed to insert text: {}", self.id, e);
            self.applying_local = false;
            return;
        }

        // Commit to finalize the transaction
        self.doc.commit();
        self.last_text = self.get_text();
        self.applying_local = false;
    }

    fn version_vector(&self) -> VersionVector {
        self.doc.oplog_vv()
    }

    fn version_vector_b64(&self) -> String {
        let vv = self.version_vector();
        let bytes = vv.encode();
        base64::engine::general_purpose::STANDARD.encode(&bytes)
    }

    fn apply_update_b64(&mut self, update_b64: &str) -> bool {
        let update_bytes = match base64::engine::general_purpose::STANDARD.decode(update_b64) {
            Ok(bytes) => bytes,
            Err(e) => {
                error!("[crdt:{}] Failed to decode update base64: {}", self.id, e);
                return false;
            }
        };

        // Import the update - this triggers the subscription callback
        // which will queue any TextDelta events to pending_deltas
        if let Err(e) = self.doc.import(&update_bytes) {
            error!("[crdt:{}] Failed to import update: {}", self.id, e);
            return false;
        }

        // Update last_text for debugging
        self.last_text = self.get_text();
        debug!(
            "[crdt:{}] Applied update, text now {} bytes",
            self.id,
            self.last_text.len()
        );

        true
    }

    fn encode_update_b64(&self, remote_vv_b64: &str) -> String {
        let remote_vv_bytes = match base64::engine::general_purpose::STANDARD.decode(remote_vv_b64)
        {
            Ok(bytes) => bytes,
            Err(e) => {
                error!(
                    "[crdt:{}] Failed to decode version vector base64: {}",
                    self.id, e
                );
                return String::new();
            }
        };

        let remote_vv = match VersionVector::decode(&remote_vv_bytes) {
            Ok(vv) => vv,
            Err(e) => {
                error!("[crdt:{}] Failed to decode version vector: {}", self.id, e);
                return String::new();
            }
        };

        match self.doc.export(ExportMode::updates(&remote_vv)) {
            Ok(bytes) => base64::engine::general_purpose::STANDARD.encode(&bytes),
            Err(e) => {
                error!("[crdt:{}] Failed to export updates: {}", self.id, e);
                String::new()
            }
        }
    }

    fn encode_full_state_b64(&self) -> String {
        match self.doc.export(ExportMode::all_updates()) {
            Ok(bytes) => base64::engine::general_purpose::STANDARD.encode(&bytes),
            Err(e) => {
                error!("[crdt:{}] Failed to export full state: {}", self.id, e);
                String::new()
            }
        }
    }

    /// Poll for pending TextDelta events from remote updates
    fn poll_deltas(&mut self) -> Vec<TextDeltaEvent> {
        self.pending_deltas.lock().drain(..).collect()
    }

    /// Clear any pending deltas (used after initial sync to avoid double-application)
    fn clear_pending_deltas(&mut self) {
        self.pending_deltas.lock().clear();
    }
}

// ============================================================================
// FFI Functions
// ============================================================================

/// Create a new CRDT document. Returns doc_id.
fn doc_create() -> String {
    let id = Uuid::new_v4();
    let doc = CrdtDoc::new(id);

    info!("[crdt:{}] Document created with subscription", id);
    DOCS.lock().insert(id, doc);

    id.to_string()
}

/// Destroy a CRDT document.
fn doc_destroy(doc_id: String) {
    let id = match Uuid::parse_str(&doc_id) {
        Ok(id) => id,
        Err(e) => {
            warn!("Invalid doc ID '{}': {}", doc_id, e);
            return;
        }
    };

    if DOCS.lock().remove(&id).is_some() {
        info!("[crdt:{}] Document destroyed", id);
    }
}

/// Get the full text content of a document.
fn doc_get_text(doc_id: String) -> String {
    let id = match Uuid::parse_str(&doc_id) {
        Ok(id) => id,
        Err(e) => {
            warn!("Invalid doc ID '{}': {}", doc_id, e);
            return String::new();
        }
    };

    let docs = DOCS.lock();
    if let Some(doc) = docs.get(&id) {
        doc.get_text()
    } else {
        warn!("[crdt:{}] Document not found", id);
        String::new()
    }
}

/// Set the full text content of a document (replaces everything).
fn doc_set_text((doc_id, content): (String, String)) {
    let id = match Uuid::parse_str(&doc_id) {
        Ok(id) => id,
        Err(e) => {
            warn!("Invalid doc ID '{}': {}", doc_id, e);
            return;
        }
    };

    let mut docs = DOCS.lock();
    if let Some(doc) = docs.get_mut(&id) {
        doc.set_text(&content);
        debug!("[crdt:{}] Set text ({} bytes)", id, content.len());
    } else {
        warn!("[crdt:{}] Document not found", id);
    }
}

/// Apply a local edit to the document.
/// Args: (doc_id, start_byte, end_byte, new_text)
fn doc_apply_edit((doc_id, start_byte, end_byte, new_text): (String, usize, usize, String)) {
    let id = match Uuid::parse_str(&doc_id) {
        Ok(id) => id,
        Err(e) => {
            warn!("Invalid doc ID '{}': {}", doc_id, e);
            return;
        }
    };

    let mut docs = DOCS.lock();
    if let Some(doc) = docs.get_mut(&id) {
        debug!(
            "[crdt:{}] Apply edit: [{}, {}) -> '{}'",
            id, start_byte, end_byte, new_text
        );
        doc.apply_edit(start_byte, end_byte, &new_text);
    } else {
        warn!("[crdt:{}] Document not found", id);
    }
}

/// Get the version vector as base64.
fn doc_state_vector(doc_id: String) -> String {
    let id = match Uuid::parse_str(&doc_id) {
        Ok(id) => id,
        Err(e) => {
            warn!("Invalid doc ID '{}': {}", doc_id, e);
            return String::new();
        }
    };

    let docs = DOCS.lock();
    if let Some(doc) = docs.get(&id) {
        doc.version_vector_b64()
    } else {
        warn!("[crdt:{}] Document not found", id);
        String::new()
    }
}

/// Apply a remote update (base64-encoded).
fn doc_apply_update((doc_id, update_b64): (String, String)) -> bool {
    let id = match Uuid::parse_str(&doc_id) {
        Ok(id) => id,
        Err(e) => {
            warn!("Invalid doc ID '{}': {}", doc_id, e);
            return false;
        }
    };

    let mut docs = DOCS.lock();
    if let Some(doc) = docs.get_mut(&id) {
        debug!("[crdt:{}] Applying remote update", id);
        doc.apply_update_b64(&update_b64)
    } else {
        warn!("[crdt:{}] Document not found", id);
        false
    }
}

/// Encode update diff from remote version vector (both base64).
fn doc_encode_update((doc_id, remote_vv_b64): (String, String)) -> String {
    let id = match Uuid::parse_str(&doc_id) {
        Ok(id) => id,
        Err(e) => {
            warn!("Invalid doc ID '{}': {}", doc_id, e);
            return String::new();
        }
    };

    let docs = DOCS.lock();
    if let Some(doc) = docs.get(&id) {
        doc.encode_update_b64(&remote_vv_b64)
    } else {
        warn!("[crdt:{}] Document not found", id);
        String::new()
    }
}

/// Encode full document state as base64 update.
fn doc_encode_full_state(doc_id: String) -> String {
    let id = match Uuid::parse_str(&doc_id) {
        Ok(id) => id,
        Err(e) => {
            warn!("Invalid doc ID '{}': {}", doc_id, e);
            return String::new();
        }
    };

    let docs = DOCS.lock();
    if let Some(doc) = docs.get(&id) {
        doc.encode_full_state_b64()
    } else {
        warn!("[crdt:{}] Document not found", id);
        String::new()
    }
}

/// Poll for pending TextDelta events from remote updates.
/// Returns list of delta events as JSON strings.
/// Format: {"type":"retain"|"insert"|"delete", "len":N} or {"type":"insert", "text":"..."}
fn doc_poll_deltas(doc_id: String) -> Vec<String> {
    let id = match Uuid::parse_str(&doc_id) {
        Ok(id) => id,
        Err(e) => {
            warn!("Invalid doc ID '{}': {}", doc_id, e);
            return Vec::new();
        }
    };

    let mut docs = DOCS.lock();
    if let Some(doc) = docs.get_mut(&id) {
        let deltas = doc.poll_deltas();
        if !deltas.is_empty() {
            debug!("[crdt:{}] Polling {} deltas", id, deltas.len());
        }
        deltas.into_iter().map(|d| d.to_json()).collect()
    } else {
        Vec::new()
    }
}

/// Clear any pending deltas.
/// Call this after initial sync to avoid double-application of the snapshot.
fn doc_clear_deltas(doc_id: String) {
    let id = match Uuid::parse_str(&doc_id) {
        Ok(id) => id,
        Err(e) => {
            warn!("Invalid doc ID '{}': {}", doc_id, e);
            return;
        }
    };

    let mut docs = DOCS.lock();
    if let Some(doc) = docs.get_mut(&id) {
        doc.clear_pending_deltas();
        debug!("[crdt:{}] Cleared pending deltas", id);
    }
}

/// CRDT FFI module
pub fn crdt_ffi() -> Dictionary {
    Dictionary::from_iter([
        (
            "doc_create",
            Object::from(Function::<(), String>::from_fn(
                |_| -> Result<String, nvim_oxi::Error> { Ok(doc_create()) },
            )),
        ),
        (
            "doc_destroy",
            Object::from(Function::<String, ()>::from_fn(
                |id| -> Result<(), nvim_oxi::Error> {
                    doc_destroy(id);
                    Ok(())
                },
            )),
        ),
        (
            "doc_get_text",
            Object::from(Function::<String, String>::from_fn(
                |id| -> Result<String, nvim_oxi::Error> { Ok(doc_get_text(id)) },
            )),
        ),
        (
            "doc_set_text",
            Object::from(Function::<(String, String), ()>::from_fn(
                |args| -> Result<(), nvim_oxi::Error> {
                    doc_set_text(args);
                    Ok(())
                },
            )),
        ),
        (
            "doc_apply_edit",
            Object::from(Function::<(String, usize, usize, String), ()>::from_fn(
                |args| -> Result<(), nvim_oxi::Error> {
                    doc_apply_edit(args);
                    Ok(())
                },
            )),
        ),
        (
            "doc_state_vector",
            Object::from(Function::<String, String>::from_fn(
                |id| -> Result<String, nvim_oxi::Error> { Ok(doc_state_vector(id)) },
            )),
        ),
        (
            "doc_apply_update",
            Object::from(Function::<(String, String), bool>::from_fn(
                |args| -> Result<bool, nvim_oxi::Error> { Ok(doc_apply_update(args)) },
            )),
        ),
        (
            "doc_encode_update",
            Object::from(Function::<(String, String), String>::from_fn(
                |args| -> Result<String, nvim_oxi::Error> { Ok(doc_encode_update(args)) },
            )),
        ),
        (
            "doc_encode_full_state",
            Object::from(Function::<String, String>::from_fn(
                |id| -> Result<String, nvim_oxi::Error> { Ok(doc_encode_full_state(id)) },
            )),
        ),
        (
            "doc_poll_deltas",
            Object::from(Function::<String, Vec<String>>::from_fn(
                |id| -> Result<Vec<String>, nvim_oxi::Error> { Ok(doc_poll_deltas(id)) },
            )),
        ),
        (
            "doc_clear_deltas",
            Object::from(Function::<String, ()>::from_fn(
                |id| -> Result<(), nvim_oxi::Error> {
                    doc_clear_deltas(id);
                    Ok(())
                },
            )),
        ),
    ])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_loro_sync_roundtrip() {
        // Create doc A with content
        let doc_a = LoroDoc::new();
        let text_a = doc_a.get_text("content");
        text_a.insert_utf8(0, "Hello World").unwrap();

        assert_eq!(text_a.to_string(), "Hello World");

        // Export all updates from A
        let updates = doc_a
            .export(ExportMode::all_updates())
            .expect("export failed");
        let updates_b64 = base64::engine::general_purpose::STANDARD.encode(&updates);

        println!(
            "Export size: {} bytes, b64 len: {}",
            updates.len(),
            updates_b64.len()
        );

        // Create doc B and import
        let doc_b = LoroDoc::new();
        let updates_decoded = base64::engine::general_purpose::STANDARD
            .decode(&updates_b64)
            .expect("decode failed");
        doc_b.import(&updates_decoded).expect("import failed");

        let text_b = doc_b.get_text("content");
        assert_eq!(text_b.to_string(), "Hello World");
    }

    #[test]
    fn test_textdelta_subscription() {
        use std::sync::atomic::{AtomicUsize, Ordering};

        // Create doc A with content
        let doc_a = LoroDoc::new();
        let text_a = doc_a.get_text("content");
        text_a.insert_utf8(0, "Hello").unwrap();
        doc_a.commit();

        // Export from A
        let updates_a = doc_a
            .export(ExportMode::all_updates())
            .expect("export failed");

        // Create doc B with subscription
        let doc_b = LoroDoc::new();
        let delta_count = Arc::new(AtomicUsize::new(0));
        let delta_count_clone = Arc::clone(&delta_count);

        let _sub = doc_b.subscribe_root(Arc::new(move |event| {
            if matches!(event.triggered_by, EventTriggerKind::Import) {
                for diff in &event.events {
                    if let Diff::Text(deltas) = &diff.diff {
                        delta_count_clone.fetch_add(deltas.len(), Ordering::SeqCst);
                    }
                }
            }
        }));

        // Import into B - should trigger subscription
        doc_b.import(&updates_a).expect("import failed");

        // Verify we got delta events
        assert!(
            delta_count.load(Ordering::SeqCst) > 0,
            "Should have received delta events"
        );

        let text_b = doc_b.get_text("content");
        assert_eq!(text_b.to_string(), "Hello");
    }

    #[test]
    fn test_textdelta_event_serialization() {
        let retain = TextDeltaEvent::Retain { len: 5 };
        assert_eq!(retain.to_json(), r#"{"type":"retain","len":5}"#);

        let insert = TextDeltaEvent::Insert {
            text: "hello".to_string(),
        };
        assert_eq!(insert.to_json(), r#"{"type":"insert","text":"hello"}"#);

        let delete = TextDeltaEvent::Delete { len: 3 };
        assert_eq!(delete.to_json(), r#"{"type":"delete","len":3}"#);

        // Test with special characters
        let insert_special = TextDeltaEvent::Insert {
            text: "hello\nworld".to_string(),
        };
        assert_eq!(
            insert_special.to_json(),
            r#"{"type":"insert","text":"hello\nworld"}"#
        );
    }
}

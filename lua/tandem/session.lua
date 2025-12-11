-- Session module for tandem.nvim
-- Manages connection lifecycle and sync loop
--
-- Binary MessagePack protocol over WebSocket:
-- - Connect to ws://host:port/ws/{document_id}?token=JWT
-- - Once connected, you're already in the room
-- - Send sync_request to get initial state
-- - Send/receive update messages for CRDT sync (raw Loro binary)
-- - No handshake needed (JWT auth is in URL)
--
-- WebSocket events are handled via callbacks (not polling) to prevent race conditions.
-- CRDT delta application uses a reduced poll timer.

local M = {}

local buffer = require("tandem.buffer")
local cursor = require("tandem.cursor")

--- Check if a string looks like valid base64url (used for encrypted data)
--- @param s string
--- @return boolean
local function is_valid_base64url(s)
	if type(s) ~= "string" or s == "" then
		return false
	end
	if s:find("[+/=]") then
		return false
	end
	if s:find("[^A-Za-z0-9_-]") then
		return false
	end
	if #s < 38 then
		return false
	end
	return true
end

-- Silence unused warning
local _ = is_valid_base64url

-- Session state
local session = {
	ws_client_id = nil,
	doc_id = nil,
	bufnr = nil,
	crdt_poll_timer = nil, -- Only for CRDT delta application
	connected = false,
	synced = false,
	ffi = nil,
	-- Track last sent state vector to avoid redundant updates
	last_sent_sv = nil,
	-- Reconnection state
	server_url = nil,
	reconnect_attempts = 0,
	reconnect_timer = nil,
	intentional_disconnect = false,
	-- Connection timeout
	connect_timer = nil,
	connect_start_time = nil,
	-- Awareness state
	last_cursor_line = nil,
	last_cursor_col = nil,
	awareness_interval_counter = 0,
	-- E2EE state (UX v2)
	encryption_key = nil, -- Base64url-encoded 256-bit key
	session_code = nil, -- Full session code for sharing
	document_name = nil, -- Human-readable document name
	-- Role: "host" can initialize from buffer on empty sync, "joiner" cannot
	role = nil, -- "host" or "joiner"
	-- Debounce state for batching local edits
	last_edit_time = 0, -- Time of last local edit
	pending_update = false, -- Whether we have unsent changes
	-- Deferred remote update flag - set when we receive a remote update while user is editing
	has_deferred_remote_update = false,
	-- Local dirty flag - set ONLY when on_bytes processes a real local edit
	-- This prevents echoing remote changes back (Codex fix)
	has_local_edits = false,
	-- Sync lockout - prevents spurious on_bytes from setting has_local_edits
	-- during/after buffer.set_content (autocmds, formatters, etc.)
	sync_lockout_until = 0,
	-- Reconciliation loop counter - check buffer-CRDT consistency periodically
	integrity_check_counter = 0,
}

-- Configuration
local config = {
	crdt_poll_interval_ms = 50, -- How often to poll CRDT for delta application
	user_name = "nvim-user",
	default_server = nil, -- e.g., "wss://tandem.example.com"
	-- Reconnection settings
	reconnect_max_retries = 10,
	reconnect_base_delay_ms = 1000, -- 1 second
	reconnect_max_delay_ms = 30000, -- 30 seconds
	connection_timeout_ms = 10000, -- 10 seconds
	-- Edit batching/debounce settings
	-- This prevents character-by-character updates which cause interleaving
	edit_debounce_ms = 100, -- Wait this long after last edit before sending
}

--- Log a message
local function log(level, msg)
	local prefix = "[tandem:" .. level .. "] "
	if level == "ERROR" then
		vim.notify(prefix .. msg, vim.log.levels.ERROR)
	elseif level == "WARN" then
		vim.notify(prefix .. msg, vim.log.levels.WARN)
	elseif level == "INFO" or level == "DEBUG" then
		-- Only show INFO/DEBUG when debug mode is enabled
		if config.debug then
			vim.notify(prefix .. msg, vim.log.levels.INFO)
		end
	end
end

--- Cancel connection timeout timer
local function cancel_connect_timeout()
	if session.connect_timer then
		session.connect_timer:stop()
		session.connect_timer:close()
		session.connect_timer = nil
	end
	session.connect_start_time = nil
end

--- Cancel reconnection timer
local function cancel_reconnect_timer()
	if session.reconnect_timer then
		session.reconnect_timer:stop()
		session.reconnect_timer:close()
		session.reconnect_timer = nil
	end
end

--- Calculate reconnection delay with exponential backoff
local function get_reconnect_delay()
	local delay = config.reconnect_base_delay_ms * math.pow(2, session.reconnect_attempts - 1)
	return math.min(delay, config.reconnect_max_delay_ms)
end

-- Forward declarations
local attempt_reconnect
local register_ws_callbacks
local start_crdt_poll_timer

--- Send local CRDT updates to server (with debouncing to batch edits)
--- @param force boolean|nil If true, skip debounce and send immediately
local function send_local_updates(force)
	if not session.connected or not session.synced or not session.doc_id then
		return
	end

	-- IMPORTANT: Only send if we have REAL local edits (Codex fix)
	-- This prevents echoing remote changes back due to SV churn
	if not session.has_local_edits then
		session.pending_update = false
		return
	end

	-- We have local edits - mark pending
	session.pending_update = true

	-- Check if enough time has passed since last edit (debounce)
	-- Skip debounce check if force=true (used before applying remote updates)
	if not force then
		local now = vim.uv.now()
		local elapsed = now - session.last_edit_time
		log(
			"DEBUG",
			string.format(
				"Debounce check: now=%d, last_edit=%d, elapsed=%d, threshold=%d",
				now,
				session.last_edit_time,
				elapsed,
				config.edit_debounce_ms
			)
		)
		if elapsed < config.edit_debounce_ms then
			-- Still within debounce window, wait for next poll
			log("DEBUG", "Debounce: waiting, elapsed < threshold")
			return
		end
		log("DEBUG", "Debounce: sending, elapsed >= threshold")
	end

	-- Get current state vector for incremental update
	local current_sv = session.ffi.crdt.doc_state_vector(session.doc_id)

	-- Debounce window passed (or forced), send the batched update
	local update_b64
	if session.last_sent_sv and session.last_sent_sv ~= "" then
		-- Incremental: only send diff from last known state
		update_b64 = session.ffi.crdt.doc_encode_update(session.doc_id, session.last_sent_sv)
	else
		-- First update or no previous state: send full state
		update_b64 = session.ffi.crdt.doc_encode_full_state(session.doc_id)
	end

	if update_b64 and update_b64 ~= "" then
		-- Note: E2E encryption is handled transparently in Rust FFI layer
		session.ffi.ws.send_update(session.ws_client_id, update_b64)
		session.last_sent_sv = current_sv
		session.pending_update = false
		-- Clear local edits flag after successful send
		session.has_local_edits = false
	end
end

--- Handle sync_response callback
--- @param _client_id string Client ID (ignored, we use session.ws_client_id)
--- @param snapshot_b64 string Base64-encoded compacted snapshot from server
local function handle_sync_response(_client_id, snapshot_b64)
	log("INFO", "Received sync_response (snapshot: " .. (snapshot_b64 and #snapshot_b64 or 0) .. " bytes b64)")

	-- Validate buffer still exists
	if not session.bufnr or not vim.api.nvim_buf_is_valid(session.bufnr) then
		log("ERROR", "Buffer no longer valid during sync")
		M.leave()
		return
	end

	-- Note: E2E decryption is handled transparently in Rust FFI layer
	-- Apply snapshot if present (even if just metadata, won't hurt)
	if snapshot_b64 and snapshot_b64 ~= "" then
		log("DEBUG", "Applying server snapshot")
		local ok, err = pcall(function()
			return session.ffi.crdt.doc_apply_update(session.doc_id, snapshot_b64)
		end)
		if not ok then
			log("ERROR", "Failed to apply snapshot: " .. tostring(err))
		end
	end

	-- Check the actual text content after applying snapshot
	local server_content = session.ffi.crdt.doc_get_text(session.doc_id)
	log("DEBUG", "CRDT content after sync: '" .. server_content:sub(1, 100) .. "' (" .. #server_content .. " bytes)")

	if server_content ~= "" then
		-- Server has actual text content - use it (authoritative)
		-- IMPORTANT: Clear pending deltas BEFORE setting buffer content
		session.ffi.crdt.doc_clear_deltas(session.doc_id)

		-- Check if buffer already has this content (avoid unnecessary set)
		local current_buf_content = buffer.get_content(session.bufnr)
		if current_buf_content == server_content then
			log("INFO", "Buffer already matches server content (" .. #server_content .. " bytes)")
		else
			log(
				"INFO",
				string.format(
					"Buffer differs from server (buf=%d, server=%d), updating",
					#current_buf_content,
					#server_content
				)
			)
			-- Set sync lockout to ignore spurious on_bytes from autocmds/formatters
			-- that may fire after set_content (100ms window)
			session.sync_lockout_until = vim.uv.now() + 100

			local set_ok, set_err = pcall(function()
				buffer.set_content(session.bufnr, server_content)
			end)
			if set_ok then
				log("INFO", "Applied server content (" .. #server_content .. " bytes)")
			else
				log("ERROR", "Failed to set buffer content: " .. tostring(set_err))
			end
		end
	elseif session.role == "host" then
		-- Empty sync response AND we are the host - initialize CRDT from buffer
		local buf_content = buffer.get_content(session.bufnr)
		if buf_content and buf_content ~= "" then
			log("INFO", "Empty sync response (host), initializing from buffer (" .. #buf_content .. " bytes)")
			session.ffi.crdt.doc_set_text(session.doc_id, buf_content)

			-- Push our state to server for future joiners
			-- Note: E2E encryption is handled transparently in Rust FFI layer
			local state_b64 = session.ffi.crdt.doc_encode_full_state(session.doc_id)
			if state_b64 and state_b64 ~= "" then
				log("INFO", "Pushing initial document state to server")
				session.ffi.ws.send_update(session.ws_client_id, state_b64)
			end
		else
			log("INFO", "Empty sync response (host), empty buffer (new document)")
		end
	else
		-- Empty sync response AND we are a joiner - wait for host state
		local buf_content = buffer.get_content(session.bufnr)
		-- Check if buffer has real content (not just a trailing newline from empty buffer)
		local has_real_content = buf_content and buf_content ~= "" and buf_content ~= "\n"
		if has_real_content then
			log("INFO", "Empty sync response (joiner), waiting 500ms for host state...")
			vim.defer_fn(function()
				local current_content = session.ffi.crdt.doc_get_text(session.doc_id)
				if current_content == "" then
					log("INFO", "No host state received, initializing from buffer")
					local content = buffer.get_content(session.bufnr)
					-- Only initialize if we have real content
					if content and content ~= "" and content ~= "\n" then
						session.ffi.crdt.doc_set_text(session.doc_id, content)
						local state_b64 = session.ffi.crdt.doc_encode_full_state(session.doc_id)
						if state_b64 and state_b64 ~= "" then
							session.ffi.ws.send_update(session.ws_client_id, state_b64)
						end
					else
						log("INFO", "Buffer is empty, waiting for host updates")
					end
				else
					log("INFO", "Received host state while waiting (" .. #current_content .. " bytes)")
				end
			end, 500)
		else
			log("INFO", "Empty sync response (joiner), empty buffer, waiting for updates")
		end
	end

	-- Mark synced AFTER applying
	-- IMPORTANT: Get state vector AFTER all content operations
	local sv_before = session.ffi.crdt.doc_state_vector(session.doc_id)
	session.last_sent_sv = sv_before
	session.synced = true
	log("INFO", "Session synced, ready for edits (sv_len=" .. #sv_before .. ")")
end

--- Handle update callback
--- @param _client_id string Client ID (ignored)
--- @param update_b64 string Base64-encoded CRDT update
local function handle_update(_client_id, update_b64)
	local b64_len = update_b64 and #update_b64 or 0
	log("INFO", "RECV update, b64_len=" .. b64_len)

	-- Log warning for empty updates (could indicate decryption failure)
	if not update_b64 or update_b64 == "" then
		log("WARN", "Received empty update - possible decryption failure")
		return
	end

	if update_b64 and update_b64 ~= "" then
		-- Validate buffer still exists
		if not session.bufnr or not vim.api.nvim_buf_is_valid(session.bufnr) then
			log("WARN", "Buffer no longer valid, ignoring remote update")
			return
		end

		-- Check if user is actively editing (recent local edit within debounce window)
		local now = vim.uv.now()
		local time_since_edit = now - session.last_edit_time
		local user_is_editing = time_since_edit < config.edit_debounce_ms

		-- Send any pending local updates first to ensure they're in CRDT before merge
		-- Use force=true to skip debounce - we must send before applying remote
		send_local_updates(true)

		-- Log CRDT state before apply
		local crdt_before = session.ffi.crdt.doc_get_text(session.doc_id)
		log("DEBUG", "CRDT before apply: " .. #crdt_before .. " bytes")

		-- Apply remote update to CRDT (this always happens - CRDT handles merge)
		local ok, result = pcall(function()
			return session.ffi.crdt.doc_apply_update(session.doc_id, update_b64)
		end)

		if not ok then
			log("ERROR", "CRDT apply exception: " .. tostring(result))
			return
		end

		-- Check if import actually succeeded (doc_apply_update returns bool)
		if result == false then
			log("ERROR", "CRDT import failed (returned false) - update may be invalid")
			return
		end

		-- Log CRDT state after apply
		local crdt_after = session.ffi.crdt.doc_get_text(session.doc_id)
		log("DEBUG", "CRDT after apply: " .. #crdt_after .. " bytes")

		-- Update last_sent_sv to prevent echoing this update back
		session.last_sent_sv = session.ffi.crdt.doc_state_vector(session.doc_id)

		-- Only update buffer if user is NOT actively editing
		-- If user is editing, their local changes are in the CRDT and will sync
		-- on the next poll when they pause typing
		if user_is_editing then
			vim.notify("[tandem] DEFER buffer update (user editing)", vim.log.levels.DEBUG)
			session.has_deferred_remote_update = true
			return
		end

		-- User is idle - safe to update buffer from CRDT
		local crdt_content = session.ffi.crdt.doc_get_text(session.doc_id)
		local buf_content = buffer.get_content(session.bufnr)

		if crdt_content ~= buf_content then
			-- Clear deltas since we're doing full sync
			session.ffi.crdt.doc_clear_deltas(session.doc_id)

			-- Set sync lockout to ignore spurious on_bytes from autocmds/formatters
			-- that may fire after set_content (100ms window)
			session.sync_lockout_until = vim.uv.now() + 100

			local set_ok, set_err = pcall(function()
				buffer.set_content(session.bufnr, crdt_content)
			end)
			if not set_ok then
				log("ERROR", "set_content failed: " .. tostring(set_err))
			end
		end
	end
end

--- Handle awareness callback
--- @param _client_id string Client ID (ignored)
--- @param awareness_json string JSON-encoded awareness data
local function handle_awareness(_client_id, awareness_json)
	log("DEBUG", "Received awareness from peer: " .. awareness_json:sub(1, 100))
	-- TODO: Parse and display remote cursor/presence
end

--- Handle connected callback
--- @param _client_id string Client ID
local function handle_connected(_client_id)
	log("INFO", "Connected to server (callback)")
	session.connected = true

	-- Cancel connection timeout
	cancel_connect_timeout()

	-- Reset reconnection attempts on successful connection
	session.reconnect_attempts = 0

	-- Request initial sync
	session.synced = false
	session.ffi.ws.send_sync_request(session.ws_client_id)
	log("INFO", "Sent sync_request")
end

--- Handle disconnected callback
--- @param _client_id string Client ID
local function handle_disconnected(_client_id)
	log("WARN", "Disconnected from server (callback)")
	session.connected = false
	session.synced = false

	-- Don't clear ws_client_id here - it's needed for reconnection comparison
	-- Attempt reconnection unless this was intentional
	if not session.intentional_disconnect then
		attempt_reconnect()
	end
end

--- Handle server error callback
--- @param _client_id string Client ID
--- @param code string Error code
--- @param message string Error message
local function handle_server_error(_client_id, code, message)
	log("ERROR", "Server error [" .. code .. "]: " .. message)
	vim.notify("[tandem] Server error: " .. message, vim.log.levels.WARN)
end

--- Handle connection/transport error callback
--- @param _client_id string Client ID
--- @param err string Error message
local function handle_error(_client_id, err)
	log("ERROR", "WebSocket error: " .. err)
	session.connected = false
	session.synced = false

	if session.ws_client_id and session.ffi then
		session.ffi.ws.disconnect(session.ws_client_id)
	end

	if not session.intentional_disconnect then
		attempt_reconnect()
	end
end

--- Register WebSocket callbacks in Lua globals
--- @param client_id string Client UUID
register_ws_callbacks = function(client_id)
	-- Ensure global table exists
	_G["_TANDEM_NVIM"] = _G["_TANDEM_NVIM"] or {}
	_G["_TANDEM_NVIM"].ws = _G["_TANDEM_NVIM"].ws or { callbacks = {} }

	-- Register callbacks for this client
	_G["_TANDEM_NVIM"].ws.callbacks[client_id] = {
		on_connect = handle_connected,
		on_disconnect = handle_disconnected,
		on_sync_response = handle_sync_response,
		on_update = handle_update,
		on_awareness = handle_awareness,
		on_server_error = handle_server_error,
		on_error = handle_error,
	}

	log("DEBUG", "Registered callbacks for client " .. client_id)
end

--- Callback for buffer edits (updates last_edit_time for debouncing)
--- This is ONLY called when on_bytes processes a real local edit (not ignored)
local function on_buffer_edit()
	local now = vim.uv.now()

	-- Check for sync lockout - ignore spurious edits from autocmds/formatters
	-- that fire after buffer.set_content during sync or remote update application
	if now < session.sync_lockout_until then
		log("DEBUG", "on_buffer_edit IGNORED (sync lockout active)")
		return
	end

	log("DEBUG", "on_buffer_edit called, setting last_edit_time to " .. now)
	session.last_edit_time = now
	-- Mark that we have real local edits to send (Codex fix)
	session.has_local_edits = true
end

--- Unregister WebSocket callbacks
--- @param client_id string Client UUID
local function unregister_ws_callbacks(client_id)
	if _G["_TANDEM_NVIM"] and _G["_TANDEM_NVIM"].ws and _G["_TANDEM_NVIM"].ws.callbacks then
		_G["_TANDEM_NVIM"].ws.callbacks[client_id] = nil
	end
end

--- Attempt to reconnect to the server
attempt_reconnect = function()
	if session.intentional_disconnect then
		return
	end

	if session.reconnect_attempts >= config.reconnect_max_retries then
		log("ERROR", "Max reconnection attempts reached (" .. config.reconnect_max_retries .. ")")
		vim.notify("[tandem] Connection lost. Use :TandemJoin to reconnect.", vim.log.levels.ERROR)
		M.leave()
		return
	end

	session.reconnect_attempts = session.reconnect_attempts + 1
	local delay = get_reconnect_delay()
	log(
		"INFO",
		string.format(
			"Reconnecting in %dms (attempt %d/%d)...",
			delay,
			session.reconnect_attempts,
			config.reconnect_max_retries
		)
	)

	cancel_reconnect_timer()
	session.reconnect_timer = vim.uv.new_timer()
	session.reconnect_timer:start(
		delay,
		0,
		vim.schedule_wrap(function()
			cancel_reconnect_timer()

			if session.intentional_disconnect or not session.server_url then
				return
			end

			log("INFO", "Attempting to reconnect...")

			-- Generate new client ID for reconnection
			local new_client_id = session.ffi.ws.generate_client_id()

			-- Unregister old callbacks if any
			if session.ws_client_id then
				unregister_ws_callbacks(session.ws_client_id)
			end

			-- Register callbacks for new client
			register_ws_callbacks(new_client_id)

			-- Connect with new client ID (pass encryption key if present)
			local ok = session.ffi.ws.connect(new_client_id, session.server_url, session.encryption_key or "")
			if not ok then
				log("WARN", "Reconnect failed, will retry...")
				unregister_ws_callbacks(new_client_id)
				attempt_reconnect()
				return
			end

			session.ws_client_id = new_client_id

			-- Start connection timeout
			session.connect_start_time = vim.uv.now()
			session.connect_timer = vim.uv.new_timer()
			session.connect_timer:start(
				config.connection_timeout_ms,
				0,
				vim.schedule_wrap(function()
					cancel_connect_timeout()
					if not session.connected then
						log("WARN", "Connection timeout, will retry...")
						if session.ws_client_id then
							session.ffi.ws.disconnect(session.ws_client_id)
							unregister_ws_callbacks(session.ws_client_id)
							session.ws_client_id = nil
						end
						attempt_reconnect()
					end
				end)
			)
		end)
	)
end

--- Send awareness update if cursor position changed
local function send_awareness_update()
	if not session.connected or not session.synced then
		return
	end

	-- Only send awareness every 5 poll cycles (250ms at 50ms interval)
	session.awareness_interval_counter = session.awareness_interval_counter + 1
	if session.awareness_interval_counter < 5 then
		return
	end
	session.awareness_interval_counter = 0

	-- Get current cursor state
	local state = cursor.get_local_state()
	if not state or not state.cursor then
		return
	end

	-- Check if cursor moved
	if state.cursor.line == session.last_cursor_line and state.cursor.col == session.last_cursor_col then
		return
	end

	-- Update and send
	session.last_cursor_line = state.cursor.line
	session.last_cursor_col = state.cursor.col

	log("DEBUG", string.format("Sending awareness: line=%d col=%d", state.cursor.line, state.cursor.col))
	local awareness_json = vim.fn.json_encode(state)
	session.ffi.ws.send_awareness(session.ws_client_id, awareness_json)
end

--- Sync buffer from CRDT if they differ (called when user is idle)
local function sync_buffer_from_crdt()
	if not session.bufnr or not vim.api.nvim_buf_is_valid(session.bufnr) then
		return
	end

	local crdt_content = session.ffi.crdt.doc_get_text(session.doc_id)
	local buf_content = buffer.get_content(session.bufnr)

	if crdt_content ~= buf_content then
		session.ffi.crdt.doc_clear_deltas(session.doc_id)
		-- Set sync lockout to ignore spurious on_bytes from autocmds/formatters
		session.sync_lockout_until = vim.uv.now() + 100
		buffer.set_content(session.bufnr, crdt_content)
	end
end

--- CRDT poll loop callback
--- Used for: checking buffer validity, sending local updates, syncing buffer, awareness
local function crdt_poll_loop()
	-- Check if buffer still exists
	if session.bufnr and not vim.api.nvim_buf_is_valid(session.bufnr) then
		log("WARN", "Buffer was deleted, leaving session")
		M.leave()
		return
	end

	-- Send local updates if connected and synced
	if session.connected and session.synced then
		send_local_updates()

		-- If we have a deferred remote update AND user has stopped editing,
		-- sync buffer from CRDT now.
		-- This handles the case where a remote update arrived while user was typing.
		-- Note: We check pending_update flag (set by on_buffer_edit) rather than
		-- comparing state vectors, because remote updates also change the SV.
		if session.has_deferred_remote_update then
			local now = vim.uv.now()
			local time_since_edit = now - session.last_edit_time

			if time_since_edit >= config.edit_debounce_ms and not session.pending_update then
				sync_buffer_from_crdt()
				session.has_deferred_remote_update = false
			end
		end

		-- Reconciliation loop: periodically verify buffer-CRDT consistency
		-- This catches any divergence caused by autocmds, formatters, etc. that
		-- slipped through despite eventignore. CRDT is authoritative.
		-- Check every ~1 second (20 polls at 50ms interval)
		session.integrity_check_counter = session.integrity_check_counter + 1
		if session.integrity_check_counter >= 20 then
			session.integrity_check_counter = 0

			local crdt_text = session.ffi.crdt.doc_get_text(session.doc_id)
			local buf_text = buffer.get_content(session.bufnr)

			if crdt_text ~= buf_text then
				log(
					"WARN",
					string.format("Desync detected! CRDT=%d bytes, buf=%d bytes. Reconciling...", #crdt_text, #buf_text)
				)
				session.sync_lockout_until = vim.uv.now() + 100
				buffer.set_content(session.bufnr, crdt_text)
			end
		end

		send_awareness_update()
	end
end

--- Start CRDT poll timer
start_crdt_poll_timer = function()
	if session.crdt_poll_timer then
		session.crdt_poll_timer:stop()
		session.crdt_poll_timer:close()
	end
	session.crdt_poll_timer = vim.uv.new_timer()
	session.crdt_poll_timer:start(0, config.crdt_poll_interval_ms, vim.schedule_wrap(crdt_poll_loop))
end

--- Join a collaborative session
--- @param server_url string WebSocket URL
--- @param doc_id string Document ID (for display)
--- @param ffi_ref table Reference to tandem_ffi
--- @return boolean Success
function M.join(server_url, doc_id, ffi_ref)
	if session.ws_client_id or session.reconnect_timer then
		log("WARN", "Already in a session, leave first")
		return false
	end

	session.ffi = ffi_ref
	session.server_url = server_url
	session.intentional_disconnect = false
	session.reconnect_attempts = 0
	session.role = "joiner"

	-- Get current buffer
	session.bufnr = vim.api.nvim_get_current_buf()
	if not vim.api.nvim_buf_is_valid(session.bufnr) then
		log("ERROR", "Invalid buffer")
		return false
	end

	-- Create CRDT document
	session.doc_id = session.ffi.crdt.doc_create()
	log("INFO", "Created CRDT doc: " .. session.doc_id)

	-- Attach buffer to CRDT
	if not buffer.attach(session.bufnr, session.doc_id, session.ffi) then
		log("ERROR", "Failed to attach buffer")
		session.ffi.crdt.doc_destroy(session.doc_id)
		session.doc_id = nil
		return false
	end
	log("INFO", "Attached buffer " .. session.bufnr)

	-- Set up edit callback for debouncing
	buffer.set_on_edit_callback(on_buffer_edit)

	-- Set up cursor tracking
	cursor.setup(session.bufnr, config.user_name)

	-- Generate client ID and register callbacks BEFORE connecting
	session.ws_client_id = session.ffi.ws.generate_client_id()
	register_ws_callbacks(session.ws_client_id)

	-- Connect WebSocket (callbacks will be invoked on events)
	-- Note: M.join doesn't use E2EE, use M.host/M.join_with_code for encrypted sessions
	local ok = session.ffi.ws.connect(session.ws_client_id, server_url, "")
	if not ok then
		log("ERROR", "Failed to connect to " .. server_url)
		unregister_ws_callbacks(session.ws_client_id)
		buffer.detach(session.bufnr)
		session.ffi.crdt.doc_destroy(session.doc_id)
		session.doc_id = nil
		session.ws_client_id = nil
		session.server_url = nil
		return false
	end
	log("INFO", "Connecting to " .. server_url)

	-- Start connection timeout timer
	session.connect_start_time = vim.uv.now()
	session.connect_timer = vim.uv.new_timer()
	session.connect_timer:start(
		config.connection_timeout_ms,
		0,
		vim.schedule_wrap(function()
			cancel_connect_timeout()
			if not session.connected then
				log("ERROR", "Connection timeout after " .. config.connection_timeout_ms .. "ms")
				if session.ws_client_id then
					session.ffi.ws.disconnect(session.ws_client_id)
					unregister_ws_callbacks(session.ws_client_id)
					session.ws_client_id = nil
				end
				attempt_reconnect()
			end
		end)
	)

	-- Start CRDT poll timer (for local updates and awareness only)
	start_crdt_poll_timer()

	return true
end

--- Leave the current session
function M.leave()
	-- Mark as intentional to prevent reconnection
	session.intentional_disconnect = true

	-- Cancel all timers
	cancel_connect_timeout()
	cancel_reconnect_timer()

	-- Stop CRDT poll timer
	if session.crdt_poll_timer then
		session.crdt_poll_timer:stop()
		session.crdt_poll_timer:close()
		session.crdt_poll_timer = nil
	end

	-- Disconnect WebSocket and unregister callbacks
	if session.ws_client_id then
		if session.ffi then
			session.ffi.ws.disconnect(session.ws_client_id)
		end
		unregister_ws_callbacks(session.ws_client_id)
		session.ws_client_id = nil
	end

	-- Clean up cursor tracking
	cursor.cleanup()

	-- Clear edit callback and detach buffer
	buffer.set_on_edit_callback(nil)
	if session.bufnr then
		buffer.detach(session.bufnr)
		session.bufnr = nil
	end

	-- Destroy CRDT doc
	if session.doc_id and session.ffi then
		session.ffi.crdt.doc_destroy(session.doc_id)
		session.doc_id = nil
	end

	session.connected = false
	session.synced = false
	session.last_sent_sv = nil
	session.server_url = nil
	session.reconnect_attempts = 0
	session.last_cursor_line = nil
	session.last_cursor_col = nil
	session.awareness_interval_counter = 0
	-- Debounce state
	session.last_edit_time = 0
	session.pending_update = false
	session.has_deferred_remote_update = false
	session.has_local_edits = false
	session.sync_lockout_until = 0
	session.integrity_check_counter = 0
	-- E2EE state
	session.encryption_key = nil
	session.session_code = nil
	session.document_name = nil
	session.role = nil
	log("INFO", "Left session")
end

--- Check if currently in a session
--- @return boolean
function M.is_active()
	return session.ws_client_id ~= nil or session.reconnect_timer ~= nil
end

--- Get session info
--- @return table
function M.info()
	local state = "disconnected"
	if session.connected and session.synced then
		state = "synced"
	elseif session.connected then
		state = "connected"
	elseif session.reconnect_timer then
		state = "reconnecting"
	elseif session.ws_client_id then
		state = "connecting"
	end

	return {
		active = M.is_active(),
		state = state,
		connected = session.connected,
		synced = session.synced,
		bufnr = session.bufnr,
		server_url = session.server_url,
		reconnect_attempts = session.reconnect_attempts,
		user_name = config.user_name,
		-- E2EE info
		encrypted = session.encryption_key ~= nil,
		session_code = session.session_code,
		document_name = session.document_name,
	}
end

--- Get a short status string for statusline integration
--- @return string
function M.statusline()
	-- Check P2P first, then regular session
	local info
	local mode_prefix
	if M.is_p2p_active() then
		info = M.p2p_info()
		mode_prefix = "P2P"
	elseif M.is_active() then
		info = M.info()
		mode_prefix = "WS"
	else
		return ""
	end

	local lock = info.encrypted and "[E2E]" or ""

	if info.state == "synced" then
		return "[Tandem " .. mode_prefix .. ": synced" .. lock .. "]"
	elseif info.state == "connected" then
		return "[Tandem " .. mode_prefix .. ": connected" .. lock .. "]"
	elseif info.state == "reconnecting" then
		return string.format(
			"[Tandem %s: reconnecting %d/%d]",
			mode_prefix,
			info.reconnect_attempts or 0,
			config.reconnect_max_retries
		)
	elseif info.state == "connecting" then
		return "[Tandem " .. mode_prefix .. ": connecting...]"
	else
		return "[Tandem " .. mode_prefix .. ": disconnected]"
	end
end

--- Configure session
--- @param opts table Configuration options
function M.setup(opts)
	opts = opts or {}
	if opts.poll_interval_ms then
		config.crdt_poll_interval_ms = opts.poll_interval_ms
	end
	if opts.user_name then
		config.user_name = opts.user_name
	end
	if opts.default_server then
		config.default_server = opts.default_server
	end
	if opts.reconnect_max_retries then
		config.reconnect_max_retries = opts.reconnect_max_retries
	end
	if opts.reconnect_base_delay_ms then
		config.reconnect_base_delay_ms = opts.reconnect_base_delay_ms
	end
	if opts.reconnect_max_delay_ms then
		config.reconnect_max_delay_ms = opts.reconnect_max_delay_ms
	end
	if opts.connection_timeout_ms then
		config.connection_timeout_ms = opts.connection_timeout_ms
	end
end

--- Get configured default server
--- @return string|nil
function M.get_default_server()
	return config.default_server
end

--- Get configured username
--- @return string
function M.get_user_name()
	return config.user_name
end

--- Generate a short document name (8 hex chars)
--- @return string
local function generate_doc_name()
	local chars = "0123456789abcdef"
	local result = {}
	for _ = 1, 8 do
		local idx = math.random(1, 16)
		table.insert(result, chars:sub(idx, idx))
	end
	return table.concat(result)
end

--- Host a new collaborative session (UX v2)
--- @param doc_name string|nil Optional document name (generated if nil)
--- @param ffi_ref table Reference to tandem_ffi
--- @return boolean success
--- @return string|nil session_code The session code to share (nil on failure)
function M.host(doc_name, ffi_ref)
	if session.ws_client_id or session.reconnect_timer then
		log("WARN", "Already in a session, leave first")
		return false, nil
	end

	if not config.default_server then
		log("ERROR", "No default_server configured. Set it in require('tandem').setup({ default_server = '...' })")
		return false, nil
	end

	session.ffi = ffi_ref
	session.intentional_disconnect = false
	session.reconnect_attempts = 0
	session.role = "host"

	-- Generate document name if not provided
	session.document_name = doc_name or generate_doc_name()

	-- Generate encryption key
	session.encryption_key = session.ffi.crypto.generate_key()

	-- Generate session code
	local ok_encode, code = pcall(function()
		return session.ffi.code.encode(session.document_name, session.encryption_key)
	end)
	if not ok_encode then
		log("ERROR", "Failed to encode session code: " .. tostring(code))
		session.encryption_key = nil
		session.document_name = nil
		return false, nil
	end
	session.session_code = code

	-- Generate JWT token
	local token = session.ffi.auth.generate_token(config.user_name)

	-- Build WebSocket URL
	local ws_url = config.default_server .. "/ws/" .. session.document_name .. "?token=" .. token
	session.server_url = ws_url

	-- Get current buffer
	session.bufnr = vim.api.nvim_get_current_buf()
	if not vim.api.nvim_buf_is_valid(session.bufnr) then
		log("ERROR", "Invalid buffer")
		session.encryption_key = nil
		session.session_code = nil
		session.document_name = nil
		return false, nil
	end

	-- Create CRDT document
	session.doc_id = session.ffi.crdt.doc_create()
	log("INFO", "Created CRDT doc: " .. session.doc_id)

	-- Attach buffer to CRDT
	if not buffer.attach(session.bufnr, session.doc_id, session.ffi) then
		log("ERROR", "Failed to attach buffer")
		session.ffi.crdt.doc_destroy(session.doc_id)
		session.doc_id = nil
		session.encryption_key = nil
		session.session_code = nil
		session.document_name = nil
		return false, nil
	end
	log("INFO", "Attached buffer " .. session.bufnr)

	-- Set up edit callback for debouncing
	buffer.set_on_edit_callback(on_buffer_edit)

	-- Set up cursor tracking
	cursor.setup(session.bufnr, config.user_name)

	-- Generate client ID and register callbacks BEFORE connecting
	session.ws_client_id = session.ffi.ws.generate_client_id()
	register_ws_callbacks(session.ws_client_id)

	-- Connect WebSocket with E2E encryption key
	local ok = session.ffi.ws.connect(session.ws_client_id, ws_url, session.encryption_key)
	if not ok then
		log("ERROR", "Failed to connect to " .. ws_url)
		unregister_ws_callbacks(session.ws_client_id)
		buffer.detach(session.bufnr)
		session.ffi.crdt.doc_destroy(session.doc_id)
		session.doc_id = nil
		session.ws_client_id = nil
		session.server_url = nil
		session.encryption_key = nil
		session.session_code = nil
		session.document_name = nil
		return false, nil
	end
	log("INFO", "Connecting to " .. ws_url .. " (E2EE enabled)")

	-- Start connection timeout timer
	session.connect_start_time = vim.uv.now()
	session.connect_timer = vim.uv.new_timer()
	session.connect_timer:start(
		config.connection_timeout_ms,
		0,
		vim.schedule_wrap(function()
			cancel_connect_timeout()
			if not session.connected then
				log("ERROR", "Connection timeout after " .. config.connection_timeout_ms .. "ms")
				if session.ws_client_id then
					session.ffi.ws.disconnect(session.ws_client_id)
					unregister_ws_callbacks(session.ws_client_id)
					session.ws_client_id = nil
				end
				attempt_reconnect()
			end
		end)
	)

	-- Start CRDT poll timer
	start_crdt_poll_timer()

	return true, session.session_code
end

--- Join a session using a session code (UX v2)
--- @param code string The session code
--- @param ffi_ref table Reference to tandem_ffi
--- @return boolean success
function M.join_with_code(code, ffi_ref)
	if session.ws_client_id or session.reconnect_timer then
		log("WARN", "Already in a session, leave first")
		return false
	end

	if not config.default_server then
		log("ERROR", "No default_server configured. Set it in require('tandem').setup({ default_server = '...' })")
		return false
	end

	session.ffi = ffi_ref
	session.intentional_disconnect = false
	session.reconnect_attempts = 0
	session.role = "joiner"

	-- Decode session code
	local ok_decode, doc_name, enc_key = pcall(function()
		return session.ffi.code.decode(code)
	end)
	if not ok_decode then
		log("ERROR", "Invalid session code: " .. tostring(doc_name))
		return false
	end

	if not doc_name or not enc_key then
		log("ERROR", "Invalid decode result: doc_name=" .. tostring(doc_name) .. ", key=" .. tostring(enc_key))
		return false
	end

	session.document_name = doc_name
	session.encryption_key = enc_key
	session.session_code = code

	-- Generate JWT token
	local token = session.ffi.auth.generate_token(config.user_name)

	-- Build WebSocket URL
	local ws_url = config.default_server .. "/ws/" .. session.document_name .. "?token=" .. token
	session.server_url = ws_url

	-- Get current buffer
	session.bufnr = vim.api.nvim_get_current_buf()
	if not vim.api.nvim_buf_is_valid(session.bufnr) then
		log("ERROR", "Invalid buffer")
		session.encryption_key = nil
		session.session_code = nil
		session.document_name = nil
		return false
	end

	-- Create CRDT document
	session.doc_id = session.ffi.crdt.doc_create()
	log("INFO", "Created CRDT doc: " .. session.doc_id)

	-- Attach buffer to CRDT
	if not buffer.attach(session.bufnr, session.doc_id, session.ffi) then
		log("ERROR", "Failed to attach buffer")
		session.ffi.crdt.doc_destroy(session.doc_id)
		session.doc_id = nil
		session.encryption_key = nil
		session.session_code = nil
		session.document_name = nil
		return false
	end
	log("INFO", "Attached buffer " .. session.bufnr)

	-- Set up edit callback for debouncing
	buffer.set_on_edit_callback(on_buffer_edit)

	-- Set up cursor tracking
	cursor.setup(session.bufnr, config.user_name)

	-- Generate client ID and register callbacks BEFORE connecting
	session.ws_client_id = session.ffi.ws.generate_client_id()
	register_ws_callbacks(session.ws_client_id)

	-- Connect WebSocket with E2E encryption key
	local ok = session.ffi.ws.connect(session.ws_client_id, ws_url, session.encryption_key)
	if not ok then
		log("ERROR", "Failed to connect to " .. ws_url)
		unregister_ws_callbacks(session.ws_client_id)
		buffer.detach(session.bufnr)
		session.ffi.crdt.doc_destroy(session.doc_id)
		session.doc_id = nil
		session.ws_client_id = nil
		session.server_url = nil
		session.encryption_key = nil
		session.session_code = nil
		session.document_name = nil
		return false
	end
	log("INFO", "Connecting to " .. ws_url .. " (E2EE enabled)")

	-- Start connection timeout timer
	session.connect_start_time = vim.uv.now()
	session.connect_timer = vim.uv.new_timer()
	session.connect_timer:start(
		config.connection_timeout_ms,
		0,
		vim.schedule_wrap(function()
			cancel_connect_timeout()
			if not session.connected then
				log("ERROR", "Connection timeout after " .. config.connection_timeout_ms .. "ms")
				if session.ws_client_id then
					session.ffi.ws.disconnect(session.ws_client_id)
					unregister_ws_callbacks(session.ws_client_id)
					session.ws_client_id = nil
				end
				attempt_reconnect()
			end
		end)
	)

	-- Start CRDT poll timer
	start_crdt_poll_timer()

	return true
end

--- Get the current session code
--- @return string|nil
function M.get_session_code()
	return session.session_code
end

-- ============================================================================
-- P2P Mode (Iroh)
-- ============================================================================

--- Register Iroh P2P callbacks in Lua globals
--- @param client_id string Client UUID
local function register_iroh_callbacks(client_id)
	-- Ensure global table exists
	_G["_TANDEM_NVIM"] = _G["_TANDEM_NVIM"] or {}
	_G["_TANDEM_NVIM"].iroh = _G["_TANDEM_NVIM"].iroh or { callbacks = {} }

	-- Callbacks for P2P mode
	_G["_TANDEM_NVIM"].iroh.callbacks[client_id] = {
		on_ready = function(_id, endpoint_id, relay_url)
			log("INFO", "P2P endpoint ready: " .. endpoint_id)

			-- Generate session code for sharing
			local ok_encode, code = pcall(function()
				return session.ffi.code.encode_p2p(endpoint_id, relay_url)
			end)
			if ok_encode then
				session.session_code = code
				session.endpoint_id = endpoint_id
				session.relay_url = relay_url
				log("INFO", "Session code generated: " .. code:sub(1, 20) .. "...")
			else
				log("ERROR", "Failed to encode P2P session code: " .. tostring(code))
			end
		end,

		on_peer_connected = function(_id, peer_id)
			log("INFO", "Peer connected: " .. peer_id)
			session.connected = true

			-- If we're the host and have content, send full state to new peer
			if session.role == "host" then
				local state_b64 = session.ffi.crdt.doc_encode_full_state(session.doc_id)
				if state_b64 and state_b64 ~= "" then
					log("INFO", "Sending full state to peer (" .. #state_b64 .. " bytes)")
					session.ffi.iroh.send_full_state(session.iroh_client_id, state_b64)
				end
			end

			session.synced = true
		end,

		on_peer_disconnected = function(_id, peer_id)
			log("WARN", "Peer disconnected: " .. peer_id)
			-- Don't set connected=false if we're host (other peers may still connect)
			if session.role ~= "host" then
				session.connected = false
				session.synced = false
			end
		end,

		on_full_state = function(_id, state_b64)
			log("INFO", "Received full state (" .. #state_b64 .. " bytes)")

			if not session.bufnr or not vim.api.nvim_buf_is_valid(session.bufnr) then
				log("ERROR", "Buffer no longer valid")
				return
			end

			-- Apply full state to CRDT
			local ok, err = pcall(function()
				return session.ffi.crdt.doc_apply_update(session.doc_id, state_b64)
			end)
			if not ok then
				log("ERROR", "Failed to apply full state: " .. tostring(err))
				return
			end

			-- Update buffer from CRDT
			local crdt_content = session.ffi.crdt.doc_get_text(session.doc_id)
			session.sync_lockout_until = vim.uv.now() + 100
			buffer.set_content(session.bufnr, crdt_content)
			session.last_sent_sv = session.ffi.crdt.doc_state_vector(session.doc_id)
			session.synced = true
			log("INFO", "Applied full state (" .. #crdt_content .. " bytes)")
		end,

		on_update = function(_id, update_b64)
			log("DEBUG", "Received update (" .. #update_b64 .. " bytes)")

			if not session.bufnr or not vim.api.nvim_buf_is_valid(session.bufnr) then
				return
			end

			-- Send pending local updates first
			send_local_updates(true)

			-- Apply remote update to CRDT
			local ok, result = pcall(function()
				return session.ffi.crdt.doc_apply_update(session.doc_id, update_b64)
			end)
			if not ok or result == false then
				log("ERROR", "Failed to apply update: " .. tostring(result))
				return
			end

			-- Update state vector
			session.last_sent_sv = session.ffi.crdt.doc_state_vector(session.doc_id)

			-- Check if user is editing
			local now = vim.uv.now()
			local time_since_edit = now - session.last_edit_time
			if time_since_edit < config.edit_debounce_ms then
				session.has_deferred_remote_update = true
				return
			end

			-- Update buffer from CRDT
			local crdt_content = session.ffi.crdt.doc_get_text(session.doc_id)
			local buf_content = buffer.get_content(session.bufnr)
			if crdt_content ~= buf_content then
				session.ffi.crdt.doc_clear_deltas(session.doc_id)
				session.sync_lockout_until = vim.uv.now() + 100
				buffer.set_content(session.bufnr, crdt_content)
			end
		end,

		on_error = function(_id, err)
			log("ERROR", "P2P error: " .. err)
			session.connected = false
			session.synced = false
		end,
	}

	log("DEBUG", "Registered Iroh callbacks for client " .. client_id)
end

--- Unregister Iroh callbacks
--- @param client_id string Client UUID
local function unregister_iroh_callbacks(client_id)
	if _G["_TANDEM_NVIM"] and _G["_TANDEM_NVIM"].iroh and _G["_TANDEM_NVIM"].iroh.callbacks then
		_G["_TANDEM_NVIM"].iroh.callbacks[client_id] = nil
	end
end

--- Send local CRDT updates via P2P
local function send_p2p_updates(force)
	if not session.connected or not session.synced or not session.doc_id then
		return
	end

	if not session.has_local_edits then
		session.pending_update = false
		return
	end

	session.pending_update = true

	if not force then
		local now = vim.uv.now()
		local elapsed = now - session.last_edit_time
		if elapsed < config.edit_debounce_ms then
			return
		end
	end

	local current_sv = session.ffi.crdt.doc_state_vector(session.doc_id)

	local update_b64
	if session.last_sent_sv and session.last_sent_sv ~= "" then
		update_b64 = session.ffi.crdt.doc_encode_update(session.doc_id, session.last_sent_sv)
	else
		update_b64 = session.ffi.crdt.doc_encode_full_state(session.doc_id)
	end

	if update_b64 and update_b64 ~= "" then
		session.ffi.iroh.send_update(session.iroh_client_id, update_b64)
		session.last_sent_sv = current_sv
		session.pending_update = false
		session.has_local_edits = false
	end
end

--- P2P poll loop
local function p2p_poll_loop()
	if session.bufnr and not vim.api.nvim_buf_is_valid(session.bufnr) then
		log("WARN", "Buffer was deleted, leaving P2P session")
		M.leave_p2p()
		return
	end

	if session.connected and session.synced then
		send_p2p_updates()

		if session.has_deferred_remote_update then
			local now = vim.uv.now()
			local time_since_edit = now - session.last_edit_time
			if time_since_edit >= config.edit_debounce_ms and not session.pending_update then
				sync_buffer_from_crdt()
				session.has_deferred_remote_update = false
			end
		end
	end
end

--- Start P2P poll timer
local function start_p2p_poll_timer()
	if session.crdt_poll_timer then
		session.crdt_poll_timer:stop()
		session.crdt_poll_timer:close()
	end
	session.crdt_poll_timer = vim.uv.new_timer()
	session.crdt_poll_timer:start(0, config.crdt_poll_interval_ms, vim.schedule_wrap(p2p_poll_loop))
end

--- Host a P2P session (no server required)
--- @param ffi_ref table Reference to tandem_ffi
--- @return boolean success
--- @return string|nil session_code The session code to share (available after on_ready callback)
function M.host_p2p(ffi_ref)
	if session.iroh_client_id then
		log("WARN", "Already in a P2P session, leave first")
		return false, nil
	end

	session.ffi = ffi_ref
	session.intentional_disconnect = false
	session.role = "host"

	-- Get current buffer
	session.bufnr = vim.api.nvim_get_current_buf()
	if not vim.api.nvim_buf_is_valid(session.bufnr) then
		log("ERROR", "Invalid buffer")
		return false, nil
	end

	-- Create CRDT document
	session.doc_id = session.ffi.crdt.doc_create()
	log("INFO", "Created CRDT doc: " .. session.doc_id)

	-- Initialize CRDT from buffer content
	local buf_content = buffer.get_content(session.bufnr)
	if buf_content and buf_content ~= "" and buf_content ~= "\n" then
		session.ffi.crdt.doc_set_text(session.doc_id, buf_content)
		log("INFO", "Initialized CRDT from buffer (" .. #buf_content .. " bytes)")
	end

	-- Attach buffer to CRDT
	if not buffer.attach(session.bufnr, session.doc_id, session.ffi) then
		log("ERROR", "Failed to attach buffer")
		session.ffi.crdt.doc_destroy(session.doc_id)
		session.doc_id = nil
		return false, nil
	end

	-- Set up edit callback
	buffer.set_on_edit_callback(on_buffer_edit)

	-- Set up cursor tracking
	cursor.setup(session.bufnr, config.user_name)

	-- Generate client ID and register callbacks
	session.iroh_client_id = session.ffi.iroh.generate_client_id()
	register_iroh_callbacks(session.iroh_client_id)

	-- Start hosting
	local ok = session.ffi.iroh.host(session.iroh_client_id)
	if not ok then
		log("ERROR", "Failed to start P2P host")
		unregister_iroh_callbacks(session.iroh_client_id)
		buffer.detach(session.bufnr)
		session.ffi.crdt.doc_destroy(session.doc_id)
		session.doc_id = nil
		session.iroh_client_id = nil
		return false, nil
	end

	log("INFO", "P2P host started, waiting for endpoint ready...")

	-- Start poll timer
	start_p2p_poll_timer()

	-- Session code will be available after on_ready callback
	return true, nil
end

--- Join a P2P session using a session code
--- @param code string The P2P session code
--- @param ffi_ref table Reference to tandem_ffi
--- @return boolean success
function M.join_p2p(code, ffi_ref)
	if session.iroh_client_id then
		log("WARN", "Already in a P2P session, leave first")
		return false
	end

	session.ffi = ffi_ref
	session.intentional_disconnect = false
	session.role = "joiner"
	session.session_code = code

	-- Get current buffer
	session.bufnr = vim.api.nvim_get_current_buf()
	if not vim.api.nvim_buf_is_valid(session.bufnr) then
		log("ERROR", "Invalid buffer")
		return false
	end

	-- Create CRDT document
	session.doc_id = session.ffi.crdt.doc_create()
	log("INFO", "Created CRDT doc: " .. session.doc_id)

	-- Attach buffer to CRDT
	if not buffer.attach(session.bufnr, session.doc_id, session.ffi) then
		log("ERROR", "Failed to attach buffer")
		session.ffi.crdt.doc_destroy(session.doc_id)
		session.doc_id = nil
		return false
	end

	-- Set up edit callback
	buffer.set_on_edit_callback(on_buffer_edit)

	-- Set up cursor tracking
	cursor.setup(session.bufnr, config.user_name)

	-- Generate client ID and register callbacks
	session.iroh_client_id = session.ffi.iroh.generate_client_id()
	register_iroh_callbacks(session.iroh_client_id)

	-- Join the session
	local ok = session.ffi.iroh.join(session.iroh_client_id, code)
	if not ok then
		log("ERROR", "Failed to join P2P session")
		unregister_iroh_callbacks(session.iroh_client_id)
		buffer.detach(session.bufnr)
		session.ffi.crdt.doc_destroy(session.doc_id)
		session.doc_id = nil
		session.iroh_client_id = nil
		session.session_code = nil
		return false
	end

	log("INFO", "Joining P2P session...")

	-- Start poll timer
	start_p2p_poll_timer()

	return true
end

--- Leave a P2P session
function M.leave_p2p()
	session.intentional_disconnect = true

	-- Stop poll timer
	if session.crdt_poll_timer then
		session.crdt_poll_timer:stop()
		session.crdt_poll_timer:close()
		session.crdt_poll_timer = nil
	end

	-- Close Iroh client
	if session.iroh_client_id then
		if session.ffi then
			session.ffi.iroh.close(session.iroh_client_id)
		end
		unregister_iroh_callbacks(session.iroh_client_id)
		session.iroh_client_id = nil
	end

	-- Clean up cursor tracking
	cursor.cleanup()

	-- Detach buffer
	buffer.set_on_edit_callback(nil)
	if session.bufnr then
		buffer.detach(session.bufnr)
		session.bufnr = nil
	end

	-- Destroy CRDT doc
	if session.doc_id and session.ffi then
		session.ffi.crdt.doc_destroy(session.doc_id)
		session.doc_id = nil
	end

	-- Reset state
	session.connected = false
	session.synced = false
	session.last_sent_sv = nil
	session.last_edit_time = 0
	session.pending_update = false
	session.has_deferred_remote_update = false
	session.has_local_edits = false
	session.sync_lockout_until = 0
	session.session_code = nil
	session.endpoint_id = nil
	session.relay_url = nil
	session.role = nil

	log("INFO", "Left P2P session")
end

--- Check if in a P2P session
--- @return boolean
function M.is_p2p_active()
	return session.iroh_client_id ~= nil
end

--- Get P2P session info
--- @return table
function M.p2p_info()
	local state = "disconnected"
	if session.connected and session.synced then
		state = "synced"
	elseif session.connected then
		state = "connected"
	elseif session.iroh_client_id then
		state = "connecting"
	end

	return {
		active = M.is_p2p_active(),
		state = state,
		connected = session.connected,
		synced = session.synced,
		bufnr = session.bufnr,
		session_code = session.session_code,
		endpoint_id = session.endpoint_id,
		role = session.role,
		encrypted = true, -- P2P always uses QUIC/TLS
	}
end

return M

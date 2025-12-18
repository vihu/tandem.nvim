-- Session module for tandem.nvim
-- Manages P2P connection lifecycle and CRDT sync
--
-- Uses Iroh for direct peer-to-peer connections with QUIC/TLS 1.3 encryption.
-- No server required - peers connect directly via relay for NAT traversal.

local M = {}

local buffer = require("tandem.buffer")
local cursor = require("tandem.cursor")

-- Session state
local session = {
	iroh_client_id = nil,
	doc_id = nil,
	bufnr = nil,
	poll_timer = nil,
	connected = false,
	synced = false,
	ffi = nil,
	-- Track last sent state vector for incremental updates
	last_sent_sv = nil,
	-- Session info
	session_code = nil,
	endpoint_id = nil,
	relay_url = nil,
	role = nil, -- "host" or "joiner"
	-- Debounce state for batching local edits
	last_edit_time = 0,
	pending_update = false,
	has_local_edits = false,
	-- Deferred remote update flag
	has_deferred_remote_update = false,
	-- Sync lockout - prevents spurious edits during buffer sync
	sync_lockout_until = 0,
	-- Integrity check counter
	integrity_check_counter = 0,
	-- Presence state
	last_cursor_line = nil,
	last_cursor_col = nil,
	presence_interval_counter = 0,
	-- Connected peers (for cursor cleanup)
	peers = {},
}

-- Configuration
local config = {
	poll_interval_ms = 50, -- How often to poll for updates
	edit_debounce_ms = 100, -- Wait after last edit before sending
	debug = false,
}

-- Seed RNG with time + PID for uniqueness across Neovim instances
math.randomseed(os.time() + vim.fn.getpid())

--- Generate a username from $USER with a random suffix
--- @return string
local function generate_username()
	local user = os.getenv("USER") or "user"
	-- 24-bit suffix (16M values) for better collision resistance
	local suffix = string.format("%06x", math.random(0, 0xFFFFFF))
	return user .. "-" .. suffix
end

-- Auto-generated username for this session
local username = generate_username()

--- Log a message
--- @param level string Log level
--- @param msg string Message
local function log(level, msg)
	local prefix = "[tandem:" .. level .. "] "
	if level == "ERROR" then
		vim.notify(prefix .. msg, vim.log.levels.ERROR)
	elseif level == "WARN" then
		vim.notify(prefix .. msg, vim.log.levels.WARN)
	elseif level == "INFO" or level == "DEBUG" then
		if config.debug then
			vim.notify(prefix .. msg, vim.log.levels.INFO)
		end
	end
end

--- Sync buffer from CRDT if they differ
local function sync_buffer_from_crdt()
	if not session.bufnr or not vim.api.nvim_buf_is_valid(session.bufnr) then
		return
	end

	local crdt_content = session.ffi.crdt.doc_get_text(session.doc_id)
	local buf_content = buffer.get_content(session.bufnr)

	if crdt_content ~= buf_content then
		session.ffi.crdt.doc_clear_deltas(session.doc_id)
		session.sync_lockout_until = vim.uv.now() + 100
		buffer.set_content(session.bufnr, crdt_content)
	end
end

--- Callback for buffer edits (updates last_edit_time for debouncing)
local function on_buffer_edit()
	local now = vim.uv.now()

	-- Check for sync lockout
	if now < session.sync_lockout_until then
		log("DEBUG", "on_buffer_edit IGNORED (sync lockout)")
		return
	end

	log("DEBUG", "on_buffer_edit called")
	session.last_edit_time = now
	session.has_local_edits = true
end

--- Send local CRDT updates to peers
--- @param force boolean|nil If true, skip debounce
local function send_local_updates(force)
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

--- Register Iroh P2P callbacks
--- @param client_id string Client UUID
local function register_callbacks(client_id)
	_G["_TANDEM_NVIM"] = _G["_TANDEM_NVIM"] or {}
	_G["_TANDEM_NVIM"].iroh = _G["_TANDEM_NVIM"].iroh or { callbacks = {} }

	_G["_TANDEM_NVIM"].iroh.callbacks[client_id] = {
		on_ready = function(_id, endpoint_id, relay_url)
			log("INFO", "P2P endpoint ready: " .. endpoint_id)

			local ok, code = pcall(function()
				return session.ffi.code.encode(endpoint_id, relay_url)
			end)
			if ok then
				session.session_code = code
				session.endpoint_id = endpoint_id
				session.relay_url = relay_url
				log("INFO", "Session code: " .. code:sub(1, 20) .. "...")
			else
				log("ERROR", "Failed to encode session code: " .. tostring(code))
			end
		end,

		on_peer_connected = function(_id, peer_id)
			log("INFO", "Peer connected: " .. peer_id)
			session.connected = true
			session.peers[peer_id] = true

			-- Host sends full state to new peer
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
			session.peers[peer_id] = nil

			-- Clean up remote cursor
			cursor.remove_remote(peer_id)

			-- Check if all peers have disconnected
			if next(session.peers) == nil then
				-- No peers remaining - mark as disconnected
				session.connected = false
				-- Host remains synced (local CRDT is authoritative)
				-- Joiner loses sync since host is gone
				if session.role ~= "host" then
					session.synced = false
				end
			end
		end,

		on_full_state = function(_id, state_b64)
			log("INFO", "Received full state (" .. #state_b64 .. " bytes)")

			if not session.bufnr or not vim.api.nvim_buf_is_valid(session.bufnr) then
				log("ERROR", "Buffer no longer valid")
				return
			end

			local ok, err = pcall(function()
				return session.ffi.crdt.doc_apply_update(session.doc_id, state_b64)
			end)
			if not ok then
				log("ERROR", "Failed to apply full state: " .. tostring(err))
				return
			end

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

			local ok, result = pcall(function()
				return session.ffi.crdt.doc_apply_update(session.doc_id, update_b64)
			end)
			if not ok or result == false then
				log("ERROR", "Failed to apply update: " .. tostring(result))
				return
			end

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

		on_presence = function(_id, peer_id, presence_json)
			log("DEBUG", "Received presence from " .. peer_id)
			local ok, state = pcall(vim.fn.json_decode, presence_json)
			if ok and state then
				cursor.update_remote(peer_id, state)
			else
				log("WARN", "Failed to parse presence JSON: " .. tostring(state))
			end
		end,
	}

	log("DEBUG", "Registered callbacks for client " .. client_id)
end

--- Unregister callbacks
--- @param client_id string Client UUID
local function unregister_callbacks(client_id)
	if _G["_TANDEM_NVIM"] and _G["_TANDEM_NVIM"].iroh and _G["_TANDEM_NVIM"].iroh.callbacks then
		_G["_TANDEM_NVIM"].iroh.callbacks[client_id] = nil
	end
end

--- Send cursor/presence update to peers (throttled)
local function send_presence_update()
	if not session.connected or not session.synced or not session.iroh_client_id then
		return
	end

	-- Throttle: send every 250ms (5 poll cycles at 50ms)
	session.presence_interval_counter = session.presence_interval_counter + 1
	if session.presence_interval_counter < 5 then
		return
	end
	session.presence_interval_counter = 0

	-- Get current cursor state
	local state = cursor.get_local_state()
	if not state or not state.cursor then
		return
	end

	-- Only send if cursor moved
	if state.cursor.line == session.last_cursor_line and state.cursor.col == session.last_cursor_col then
		return
	end

	session.last_cursor_line = state.cursor.line
	session.last_cursor_col = state.cursor.col

	-- Send presence to peers
	local presence_json = vim.fn.json_encode(state)
	session.ffi.iroh.send_presence(session.iroh_client_id, presence_json)
end

--- Poll loop for sending updates and checking buffer state
local function poll_loop()
	if session.bufnr and not vim.api.nvim_buf_is_valid(session.bufnr) then
		log("WARN", "Buffer deleted, leaving session")
		M.leave()
		return
	end

	if session.connected and session.synced then
		send_local_updates()
		send_presence_update()

		-- Handle deferred remote updates
		if session.has_deferred_remote_update then
			local now = vim.uv.now()
			local time_since_edit = now - session.last_edit_time
			if time_since_edit >= config.edit_debounce_ms and not session.pending_update then
				sync_buffer_from_crdt()
				session.has_deferred_remote_update = false
			end
		end

		-- Periodic integrity check (every ~1 second)
		session.integrity_check_counter = session.integrity_check_counter + 1
		if session.integrity_check_counter >= 20 then
			session.integrity_check_counter = 0

			local crdt_text = session.ffi.crdt.doc_get_text(session.doc_id)
			local buf_text = buffer.get_content(session.bufnr)

			if crdt_text ~= buf_text then
				log("WARN", "Desync detected, reconciling...")
				session.sync_lockout_until = vim.uv.now() + 100
				buffer.set_content(session.bufnr, crdt_text)
			end
		end
	end
end

--- Start poll timer
local function start_poll_timer()
	if session.poll_timer then
		session.poll_timer:stop()
		session.poll_timer:close()
	end
	session.poll_timer = vim.uv.new_timer()
	session.poll_timer:start(0, config.poll_interval_ms, vim.schedule_wrap(poll_loop))
end

--- Host a P2P session
--- @param ffi_ref table Reference to tandem_ffi
--- @return boolean success
--- @return string|nil session_code (available after on_ready callback)
function M.host(ffi_ref)
	if session.iroh_client_id then
		log("WARN", "Already in a session, leave first")
		return false, nil
	end

	session.ffi = ffi_ref
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

	-- Initialize CRDT from buffer
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

	-- Set up callbacks
	buffer.set_on_edit_callback(on_buffer_edit)
	cursor.setup(session.bufnr, username)

	-- Generate client ID and register callbacks
	session.iroh_client_id = session.ffi.iroh.generate_client_id()
	register_callbacks(session.iroh_client_id)

	-- Start hosting
	local ok = session.ffi.iroh.host(session.iroh_client_id)
	if not ok then
		log("ERROR", "Failed to start P2P host")
		unregister_callbacks(session.iroh_client_id)
		buffer.detach(session.bufnr)
		session.ffi.crdt.doc_destroy(session.doc_id)
		session.doc_id = nil
		session.iroh_client_id = nil
		return false, nil
	end

	log("INFO", "P2P host started, waiting for endpoint ready...")
	start_poll_timer()

	return true, nil
end

--- Join a P2P session
--- @param code string Session code
--- @param ffi_ref table Reference to tandem_ffi
--- @return boolean success
function M.join(code, ffi_ref)
	if session.iroh_client_id then
		log("WARN", "Already in a session, leave first")
		return false
	end

	session.ffi = ffi_ref
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

	-- Set up callbacks
	buffer.set_on_edit_callback(on_buffer_edit)
	cursor.setup(session.bufnr, username)

	-- Generate client ID and register callbacks
	session.iroh_client_id = session.ffi.iroh.generate_client_id()
	register_callbacks(session.iroh_client_id)

	-- Join session
	local ok = session.ffi.iroh.join(session.iroh_client_id, code)
	if not ok then
		log("ERROR", "Failed to join P2P session")
		unregister_callbacks(session.iroh_client_id)
		buffer.detach(session.bufnr)
		session.ffi.crdt.doc_destroy(session.doc_id)
		session.doc_id = nil
		session.iroh_client_id = nil
		session.session_code = nil
		return false
	end

	log("INFO", "Joining P2P session...")
	start_poll_timer()

	return true
end

--- Leave the current session
function M.leave()
	-- Stop poll timer
	if session.poll_timer then
		session.poll_timer:stop()
		session.poll_timer:close()
		session.poll_timer = nil
	end

	-- Close Iroh client
	if session.iroh_client_id then
		if session.ffi then
			session.ffi.iroh.close(session.iroh_client_id)
		end
		unregister_callbacks(session.iroh_client_id)
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
	session.integrity_check_counter = 0
	session.session_code = nil
	session.endpoint_id = nil
	session.relay_url = nil
	session.role = nil
	session.last_cursor_line = nil
	session.last_cursor_col = nil
	session.presence_interval_counter = 0
	session.peers = {}

	log("INFO", "Left session")
end

--- Check if in a session
--- @return boolean
function M.is_active()
	return session.iroh_client_id ~= nil
end

--- Get session info
--- @return table
function M.info()
	local state = "disconnected"
	if session.connected and session.synced then
		state = "synced"
	elseif session.connected then
		state = "connected"
	elseif session.iroh_client_id then
		state = "connecting"
	end

	return {
		active = M.is_active(),
		state = state,
		connected = session.connected,
		synced = session.synced,
		bufnr = session.bufnr,
		session_code = session.session_code,
		endpoint_id = session.endpoint_id,
		role = session.role,
		encrypted = true, -- P2P always uses QUIC/TLS
		user_name = username,
	}
end

--- Get statusline string
--- @return string
function M.statusline()
	if not M.is_active() then
		return ""
	end

	local info = M.info()

	if info.state == "synced" then
		return "[Tandem: synced]"
	elseif info.state == "connected" then
		return "[Tandem: connected]"
	elseif info.state == "connecting" then
		return "[Tandem: connecting...]"
	else
		return "[Tandem: disconnected]"
	end
end

--- Get session code
--- @return string|nil
function M.get_session_code()
	return session.session_code
end

--- Get username
--- @return string
function M.get_user_name()
	return username
end

--- Configure session
--- @param opts table Configuration options
function M.setup(opts)
	opts = opts or {}
	if opts.poll_interval_ms then
		config.poll_interval_ms = opts.poll_interval_ms
	end
	if opts.debug ~= nil then
		config.debug = opts.debug
	end
end

return M

-- tandem.nvim - Real-time collaborative editing for Neovim
-- Uses Loro CRDT for document synchronization via WebSocket relay

local M = {}

-- Get the plugin's root directory
local function get_plugin_root()
	local source = debug.getinfo(1, "S").source:sub(2)
	-- source is /path/to/tandem/lua/tandem/init.lua
	-- we want /path/to/tandem
	return vim.fn.fnamemodify(source, ":h:h:h")
end

-- Load the FFI module
local function load_ffi()
	local root = get_plugin_root()

	-- Search paths in order of preference:
	-- 1. bin/lua/ - pre-built binaries from GitHub releases
	-- 2. rust/tandem-ffi/lua/ - local development build
	local search_paths = {
		root .. "/bin/lua",
		root .. "/rust/tandem-ffi/lua",
	}

	for _, ffi_path in ipairs(search_paths) do
		if not package.cpath:find(ffi_path, 1, true) then
			package.cpath = ffi_path .. "/?.so;" .. package.cpath
		end
	end

	local ok, ffi = pcall(require, "tandem_ffi")
	if not ok then
		error(
			"[tandem] Failed to load tandem_ffi: "
				.. tostring(ffi)
				.. "\nRun: require('tandem.build').install()"
				.. "\nOr build from source: make build"
		)
	end
	return ffi
end

-- Configuration defaults
M.config = {
	debug = false,
	user_name = vim.env.USER or "nvim-user",
	default_server = "ws://127.0.0.1:8080", -- Local tandem-server
	poll_interval_ms = 50,
	reconnect_max_retries = 10,
	reconnect_base_delay_ms = 1000,
	reconnect_max_delay_ms = 30000,
	connection_timeout_ms = 10000,
}

-- FFI module (loaded on setup)
M.ffi = nil

-- Session module (lazy loaded)
local session = nil

local function get_session()
	if not session then
		session = require("tandem.session")
	end
	return session
end

function M.setup(opts)
	opts = opts or {}
	M.config = vim.tbl_deep_extend("force", M.config, opts)

	-- Initialize global callback registry for WebSocket events
	-- This must be set up BEFORE loading FFI or connecting
	_G["_TANDEM_NVIM"] = _G["_TANDEM_NVIM"] or {}
	_G["_TANDEM_NVIM"].ws = _G["_TANDEM_NVIM"].ws or { callbacks = {} }

	-- Load FFI
	M.ffi = load_ffi()

	-- Configure session module with our settings
	local sess = get_session()
	sess.setup({
		poll_interval_ms = M.config.poll_interval_ms,
		user_name = M.config.user_name,
		default_server = M.config.default_server,
		reconnect_max_retries = M.config.reconnect_max_retries,
		reconnect_base_delay_ms = M.config.reconnect_base_delay_ms,
		reconnect_max_delay_ms = M.config.reconnect_max_delay_ms,
		connection_timeout_ms = M.config.connection_timeout_ms,
	})

	if M.config.debug then
		print("[tandem] Plugin loaded successfully")
	end
end

-- Commands

--- Host a new collaborative session
vim.api.nvim_create_user_command("TandemHost", function(args)
	if not M.ffi then
		vim.notify("[tandem] Plugin not initialized. Call require('tandem').setup() first.", vim.log.levels.ERROR)
		return
	end

	local sess = get_session()
	if sess.is_active() then
		vim.notify("[tandem] Already in a session. Use :TandemLeave first.", vim.log.levels.WARN)
		return
	end

	local doc_name = args.fargs[1] -- Optional document name

	local ok, code = sess.host(doc_name, M.ffi)
	if ok and code then
		-- Copy to clipboard
		vim.fn.setreg("+", code)
		vim.fn.setreg("*", code)
		vim.notify("[tandem] Session hosted! Code copied to clipboard:", vim.log.levels.INFO)
		vim.notify(code, vim.log.levels.INFO)
	else
		vim.notify("[tandem] Failed to host session", vim.log.levels.ERROR)
	end
end, { nargs = "?", desc = "Host a new collaborative session" })

--- Join a session using a session code
vim.api.nvim_create_user_command("TandemJoin", function(args)
	if not M.ffi then
		vim.notify("[tandem] Plugin not initialized. Call require('tandem').setup() first.", vim.log.levels.ERROR)
		return
	end

	local sess = get_session()
	if sess.is_active() then
		vim.notify("[tandem] Already in a session. Use :TandemLeave first.", vim.log.levels.WARN)
		return
	end

	local fargs = args.fargs
	if #fargs < 1 then
		vim.notify("Usage: :TandemJoin <session_code>", vim.log.levels.ERROR)
		vim.notify("Get a session code from someone running :TandemHost", vim.log.levels.INFO)
		return
	end

	local code = fargs[1]

	vim.notify("[tandem] Joining session...", vim.log.levels.INFO)
	local ok = sess.join_with_code(code, M.ffi)
	if not ok then
		vim.notify("[tandem] Failed to join session", vim.log.levels.ERROR)
	end
end, { nargs = 1, desc = "Join a collaborative session using a session code" })

vim.api.nvim_create_user_command("TandemLeave", function()
	local sess = get_session()
	if not sess.is_active() then
		vim.notify("[tandem] Not in a session", vim.log.levels.WARN)
		return
	end

	sess.leave()
	vim.notify("[tandem] Left session", vim.log.levels.INFO)
end, { desc = "Leave the current collaborative session" })

vim.api.nvim_create_user_command("TandemInfo", function()
	local sess = get_session()
	local info = sess.info()
	if info.active then
		vim.notify(
			string.format(
				"[tandem] Session active\n  Document: %s\n  Buffer: %d\n  Connected: %s",
				info.doc_id or "?",
				info.bufnr or -1,
				info.connected and "yes" or "no"
			),
			vim.log.levels.INFO
		)
	else
		vim.notify("[tandem] No active session", vim.log.levels.INFO)
	end
end, { desc = "Show tandem session info" })

vim.api.nvim_create_user_command("TandemStatus", function()
	local sess = get_session()
	local info = sess.info()

	local lines = {
		"Tandem Status",
		"=============",
		"State: " .. info.state,
		"Buffer: " .. (info.bufnr or "none"),
		"Connected: " .. (info.connected and "yes" or "no"),
		"Synced: " .. (info.synced and "yes" or "no"),
		"User: " .. (info.user_name or "unknown"),
		"Encrypted: " .. (info.encrypted and "yes (E2EE)" or "no"),
	}

	if info.document_name then
		table.insert(lines, "Document: " .. info.document_name)
	end

	if info.server_url then
		table.insert(lines, "Server: " .. info.server_url)
	end

	if info.reconnect_attempts > 0 then
		table.insert(lines, "Reconnect attempts: " .. info.reconnect_attempts)
	end

	vim.api.nvim_echo({ { table.concat(lines, "\n"), "Normal" } }, true, {})
end, { desc = "Show detailed tandem status" })

vim.api.nvim_create_user_command("TandemCode", function()
	local sess = get_session()
	if not sess.is_active() then
		vim.notify("[tandem] Not in a session", vim.log.levels.WARN)
		return
	end

	local code = sess.get_session_code()
	if code then
		-- Copy to clipboard
		vim.fn.setreg("+", code)
		vim.fn.setreg("*", code)
		vim.notify("[tandem] Session code copied to clipboard:", vim.log.levels.INFO)
		vim.notify(code, vim.log.levels.INFO)
	else
		vim.notify("[tandem] No session code available (legacy session?)", vim.log.levels.WARN)
	end
end, { desc = "Show and copy current session code" })

--- Get statusline string for lualine/etc integration
--- @return string
function M.statusline()
	local sess = get_session()
	return sess.statusline()
end

--- Get current configuration (for health checks)
--- @return table
function M.get_config()
	return M.config
end

return M

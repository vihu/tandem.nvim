-- tandem.nvim - Real-time collaborative editing for Neovim
-- Uses Loro CRDT for document synchronization via P2P (Iroh/QUIC)

local M = {}

-- Get the plugin's root directory
local function get_plugin_root()
	local source = debug.getinfo(1, "S").source:sub(2)
	return vim.fn.fnamemodify(source, ":h:h:h")
end

-- Load the FFI module
local function load_ffi()
	local root = get_plugin_root()

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
	poll_interval_ms = 50,
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

	-- Initialize global callback registry
	_G["_TANDEM_NVIM"] = _G["_TANDEM_NVIM"] or {}
	_G["_TANDEM_NVIM"].iroh = _G["_TANDEM_NVIM"].iroh or { callbacks = {} }

	-- Load FFI
	M.ffi = load_ffi()

	-- Configure session module
	local sess = get_session()
	sess.setup({
		poll_interval_ms = M.config.poll_interval_ms,
		debug = M.config.debug,
	})

	if M.config.debug then
		print("[tandem] Plugin loaded successfully")
	end
end

-- Commands

--- Host a new collaborative P2P session
vim.api.nvim_create_user_command("TandemHost", function()
	if not M.ffi then
		vim.notify("[tandem] Plugin not initialized. Call require('tandem').setup() first.", vim.log.levels.ERROR)
		return
	end

	local sess = get_session()
	if sess.is_active() then
		vim.notify("[tandem] Already in a session. Use :TandemLeave first.", vim.log.levels.WARN)
		return
	end

	local ok, _ = sess.host(M.ffi)
	if ok then
		vim.notify("[tandem] P2P host started. Waiting for endpoint ready...", vim.log.levels.INFO)
		-- Poll for session code and copy to clipboard when ready
		local attempts = 0
		local timer = vim.uv.new_timer()
		timer:start(
			500,
			500,
			vim.schedule_wrap(function()
				attempts = attempts + 1
				local code = sess.get_session_code()
				if code then
					timer:stop()
					timer:close()
					vim.fn.setreg("+", code)
					vim.fn.setreg("*", code)
					vim.notify("[tandem] Ready! Code copied: " .. code:sub(1, 30) .. "...", vim.log.levels.INFO)
				elseif attempts > 20 then -- 10 seconds timeout
					timer:stop()
					timer:close()
					vim.notify("[tandem] Endpoint ready but no session code generated", vim.log.levels.WARN)
				end
			end)
		)
	else
		vim.notify("[tandem] Failed to start P2P host", vim.log.levels.ERROR)
	end
end, { desc = "Host a new P2P collaborative session" })

--- Join a P2P session using a session code
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
		vim.notify("[tandem] Usage: :TandemJoin <session_code>", vim.log.levels.ERROR)
		return
	end

	local code = fargs[1]
	local ok = sess.join(code, M.ffi)
	if ok then
		vim.notify("[tandem] Joining session...", vim.log.levels.INFO)
	else
		vim.notify("[tandem] Failed to join session", vim.log.levels.ERROR)
	end
end, { nargs = 1, desc = "Join a P2P collaborative session using a session code" })

vim.api.nvim_create_user_command("TandemLeave", function()
	local sess = get_session()
	if sess.is_active() then
		sess.leave()
		vim.notify("[tandem] Left session", vim.log.levels.INFO)
	else
		vim.notify("[tandem] Not in a session", vim.log.levels.WARN)
	end
end, { desc = "Leave the current collaborative session" })

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
		"Encrypted: yes (QUIC/TLS 1.3)",
	}

	if info.role then
		table.insert(lines, "Role: " .. info.role)
	end

	if info.endpoint_id then
		table.insert(lines, "Endpoint: " .. info.endpoint_id:sub(1, 20) .. "...")
	end

	if info.session_code then
		table.insert(lines, "Session Code: " .. info.session_code:sub(1, 30) .. "...")
	end

	if info.user_name then
		table.insert(lines, "User: " .. info.user_name)
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
		vim.fn.setreg("+", code)
		vim.fn.setreg("*", code)
		vim.notify("[tandem] Code copied: " .. code, vim.log.levels.INFO)
	else
		vim.notify("[tandem] No session code available", vim.log.levels.WARN)
	end
end, { desc = "Show and copy current session code" })

--- Get statusline string for lualine/etc integration
--- @return string
function M.statusline()
	local sess = get_session()
	return sess.statusline()
end

--- Get current configuration
--- @return table
function M.get_config()
	return M.config
end

return M

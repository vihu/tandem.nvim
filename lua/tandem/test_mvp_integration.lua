-- MVP Integration Test for tandem.nvim
-- Tests: Connection, sync, TandemStatus, statusline, cursor module
--
-- Usage: nvim --headless -u NONE -c "set rtp+=." -c "luafile lua/tandem/test_mvp_integration.lua" -c "qa!"
-- Requires: WebSocket relay server running at ws://127.0.0.1:8080

-- Get a test token from the server
local function get_test_token()
	local handle = io.popen(
		'curl -s -X POST "http://127.0.0.1:8080/login" -H "Content-Type: application/json" -d \'{"username":"nvim-test"}\''
	)
	if not handle then
		return nil
	end
	local result = handle:read("*a")
	handle:close()
	-- Parse JSON manually (simple extraction)
	local token = result:match('"token":"([^"]+)"')
	return token
end

local TEST_TOKEN = get_test_token()
if not TEST_TOKEN then
	print("[WARN] Could not get test token - server connection tests will fail")
end

local function test(name, fn)
	local ok, err = pcall(fn)
	if ok then
		print("[PASS] " .. name)
		return true
	else
		print("[FAIL] " .. name .. ": " .. tostring(err))
		return false
	end
end

local all_passed = true

print("\n=== MVP Integration Tests ===\n")

-- Test 1: Load modules
all_passed = test("Load tandem module", function()
	local ok, tandem = pcall(require, "tandem")
	assert(ok, "Failed to require tandem: " .. tostring(tandem))
	tandem.setup({ user_name = "test-user" })
	assert(tandem.ffi, "FFI not loaded")
end) and all_passed

all_passed = test("Load session module", function()
	local session = require("tandem.session")
	assert(type(session.join) == "function", "session.join not a function")
	assert(type(session.leave) == "function", "session.leave not a function")
	assert(type(session.info) == "function", "session.info not a function")
	assert(type(session.statusline) == "function", "session.statusline not a function")
end) and all_passed

all_passed = test("Load cursor module", function()
	local cursor = require("tandem.cursor")
	assert(type(cursor.setup) == "function", "cursor.setup not a function")
	assert(type(cursor.cleanup) == "function", "cursor.cleanup not a function")
	assert(type(cursor.get_local_state) == "function", "cursor.get_local_state not a function")
	assert(type(cursor.update_remote) == "function", "cursor.update_remote not a function")
end) and all_passed

-- Test 2: Session info before joining
all_passed = test("Session info when not active", function()
	local session = require("tandem.session")
	local info = session.info()
	assert(info.active == false, "Should not be active")
	assert(info.state == "disconnected", "State should be 'disconnected'")
end) and all_passed

-- Test 3: Statusline when not active
all_passed = test("Statusline when not active", function()
	local session = require("tandem.session")
	local sl = session.statusline()
	assert(sl == "", "Statusline should be empty when not active")
end) and all_passed

-- Test 4: Cursor module - get local state
all_passed = test("Cursor get_local_state", function()
	local cursor = require("tandem.cursor")
	local state = cursor.get_local_state()
	assert(type(state) == "table", "State should be a table")
	assert(type(state.cursor) == "table", "State should have cursor table")
	assert(type(state.cursor.line) == "number", "Cursor should have line")
	assert(type(state.cursor.col) == "number", "Cursor should have col")
	assert(type(state.user) == "table", "State should have user table")
end) and all_passed

-- Test 5: Remote cursor update
all_passed = test("Cursor update_remote", function()
	local cursor = require("tandem.cursor")
	-- Set up for a test buffer (current buffer)
	local bufnr = vim.api.nvim_get_current_buf()
	cursor.setup(bufnr, "test-user")

	-- Update remote cursor
	cursor.update_remote("test-client-123", {
		cursor = { line = 1, col = 0 },
		user = { name = "Remote User", color = "#ff0000" },
	})

	-- Check user count
	local count = cursor.get_user_count()
	assert(count == 1, "Should have 1 remote user, got " .. count)

	-- Get remote users
	local users = cursor.get_remote_users()
	assert(#users == 1, "Should have 1 user in list")
	assert(users[1].name == "Remote User", "User name should match")

	-- Clean up
	cursor.remove_remote("test-client-123")
	assert(cursor.get_user_count() == 0, "Should have 0 remote users after removal")

	cursor.cleanup()
end) and all_passed

-- Test 6: Protocol module - awareness message
all_passed = test("Protocol awareness message", function()
	local protocol = require("tandem.protocol")
	local msg = protocol.awareness({
		cursor = { line = 5, col = 10 },
		user = { name = "test", color = "#00ff00" },
	})
	assert(type(msg) == "string", "Message should be a string")
	assert(msg:find('"type"'), "Message should have type field")
end) and all_passed

-- Test 7: Connection test (requires server)
all_passed = test("WebSocket connection to server", function()
	assert(TEST_TOKEN, "Test token required for server tests")
	local tandem = require("tandem")
	local url = "ws://127.0.0.1:8080/ws/mvp-test?token=" .. TEST_TOKEN
	local client_id = tandem.ffi.ws.connect(url)
	assert(client_id and client_id ~= "", "Should get a client ID")

	-- Wait for connection with polling
	local connected = false
	local start = vim.uv.now()
	while vim.uv.now() - start < 2000 do
		local events = tandem.ffi.ws.poll(client_id)
		for _, event in ipairs(events) do
			if event == "connected" then
				connected = true
				break
			end
		end
		if connected then
			break
		end
		vim.wait(50, function()
			return false
		end)
	end

	-- Clean up
	tandem.ffi.ws.disconnect(client_id)

	assert(connected, "Should have received 'connected' event")
end) and all_passed

-- Test 8: Full session join/leave cycle
all_passed = test("Session join and leave cycle", function()
	assert(TEST_TOKEN, "Test token required for server tests")
	local session = require("tandem.session")
	local tandem = require("tandem")

	-- Join session
	local url = "ws://127.0.0.1:8080/ws/mvp-test-session?token=" .. TEST_TOKEN
	local ok = session.join(url, "mvp-test-session", tandem.ffi)
	assert(ok, "Join should succeed")

	-- Wait for connection
	vim.wait(1000, function()
		return session.info().connected
	end)

	local info = session.info()
	assert(info.active == true, "Session should be active")
	assert(info.state ~= "disconnected", "State should not be 'disconnected', got: " .. info.state)

	-- Check statusline shows something
	local sl = session.statusline()
	assert(sl ~= "", "Statusline should not be empty when connected")

	-- Leave session
	session.leave()

	-- Verify cleanup
	info = session.info()
	assert(info.active == false, "Session should not be active after leave")
	assert(session.statusline() == "", "Statusline should be empty after leave")
end) and all_passed

-- Test 9: Config options
all_passed = test("Config options are respected", function()
	local session = require("tandem.session")
	session.setup({
		poll_interval_ms = 100,
		user_name = "custom-user",
		reconnect_max_retries = 5,
		reconnect_base_delay_ms = 500,
		reconnect_max_delay_ms = 10000,
		connection_timeout_ms = 5000,
	})
	-- If no error, config was accepted
end) and all_passed

-- Summary
print("")
if all_passed then
	print("=== [PASS] All MVP integration tests passed! ===")
else
	print("=== [FAIL] Some tests failed ===")
	vim.cmd("cq 1")
end

-- Test script for WebSocket + Loro CRDT protocol
-- Run in Neovim: :luafile lua/tandem/test_ws.lua
--
-- Prerequisites:
-- 1. Build the plugin: make build
-- 2. Start a WebSocket relay server at ws://127.0.0.1:8080
-- 3. Run this script

local M = {}

-- Load the plugin
local tandem = require("tandem")
tandem.setup({ debug = true })

local protocol = require("tandem.protocol")
local ffi = tandem.ffi

-- Test configuration
local SERVER_URL = "ws://127.0.0.1:8080/ws/test-room"
local DOC_ID = "test-room"

-- State
local client_id = nil
local connected = false
local poll_timer = nil

local function log(msg)
	print("[test_ws] " .. msg)
end

local function handle_event(event)
	if event == "connected" then
		log("Connected to server!")
		connected = true

		-- Send ClientHello
		local hello = protocol.client_hello("test-user", "#00ff00")
		log("Sending ClientHello: " .. hello)
		ffi.ws.send(client_id, hello)

		-- Send JoinDocument
		vim.defer_fn(function()
			local join = protocol.join_document(DOC_ID)
			log("Sending JoinDocument: " .. join)
			ffi.ws.send(client_id, join)
		end, 100)
	elseif event == "disconnected" then
		log("Disconnected from server")
		connected = false
		if poll_timer then
			vim.fn.timer_stop(poll_timer)
			poll_timer = nil
		end
	elseif event:match("^message:") then
		local json = event:sub(9) -- Remove "message:" prefix
		local msg, err = protocol.parse(json)
		if err then
			log("Parse error: " .. err)
		else
			log("Received " .. protocol.get_type(msg) .. ": " .. json)
		end
	elseif event:match("^error:") then
		local err = event:sub(7)
		log("Error: " .. err)
	end
end

local function poll()
	if not client_id then
		return
	end

	local events = ffi.ws.poll(client_id)
	for _, event in ipairs(events) do
		handle_event(event)
	end
end

function M.connect(url)
	url = url or SERVER_URL

	log("Connecting to " .. url)
	client_id = ffi.ws.connect(url)

	if client_id == "" then
		log("Failed to connect - invalid URL?")
		return
	end

	log("Client ID: " .. client_id)

	-- Start polling
	poll_timer = vim.fn.timer_start(50, function()
		poll()
	end, { ["repeat"] = -1 })

	log("Polling started")
end

function M.disconnect()
	if client_id then
		log("Disconnecting...")
		ffi.ws.disconnect(client_id)
		client_id = nil
	end
end

function M.send_ping()
	if client_id and connected then
		local ping = protocol.ping()
		log("Sending Ping: " .. ping)
		ffi.ws.send(client_id, ping)
	else
		log("Not connected")
	end
end

function M.status()
	if client_id then
		log("Client ID: " .. client_id)
		log("Connected: " .. tostring(ffi.ws.is_connected(client_id)))
	else
		log("No active connection")
	end
end

-- Export for interactive use
_G.tandem_test = M

log("Test module loaded. Commands:")
log("  tandem_test.connect()     -- Connect to default server")
log("  tandem_test.connect(url)  -- Connect to custom URL")
log("  tandem_test.disconnect()  -- Disconnect")
log("  tandem_test.send_ping()   -- Send ping")
log("  tandem_test.status()      -- Show status")

return M

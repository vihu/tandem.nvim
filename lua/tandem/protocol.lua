-- tandem/protocol.lua - WebSocket relay protocol message builders and parsers
--
-- Server expects these client message types (snake_case):
--   - sync_request: Request full document state
--   - update: Send CRDT update (Loro binary, base64 encoded in 'data' field)
--   - awareness: Send cursor/presence info
--   - chat: Send chat message
--
-- Server sends these message types:
--   - sync_response: Full document state (Loro binary, base64 in 'data' field)
--   - update: CRDT update broadcast (Loro binary, base64 in 'data' field)
--   - awareness: Presence update
--   - chat: Chat message broadcast

local M = {}

--- Build a sync_request message to get current document state
---@return string JSON message
function M.sync_request()
	return vim.fn.json_encode({
		type = "sync_request",
	})
end

--- Build an update message with CRDT data
---@param update_b64 string Base64-encoded Loro update
---@return string JSON message
function M.update(update_b64)
	return vim.fn.json_encode({
		type = "update",
		data = update_b64,
	})
end

--- Build an awareness message for cursor/presence
---@param data table Awareness data (e.g., { cursor = 42, user = "name" })
---@return string JSON message
function M.awareness(data)
	return vim.fn.json_encode({
		type = "awareness",
		data = data,
	})
end

--- Build a chat message
---@param message string Chat text
---@return string JSON message
function M.chat(message)
	return vim.fn.json_encode({
		type = "chat",
		message = message,
	})
end

--- Convert a JSON byte array to binary string
---@param byte_array table Array of byte values [0-255]
---@return string Binary string
local function bytes_to_string(byte_array)
	if not byte_array or #byte_array == 0 then
		return ""
	end
	local chars = {}
	for i, b in ipairs(byte_array) do
		chars[i] = string.char(b)
	end
	return table.concat(chars)
end

--- Convert a JSON byte array to base64 string
---@param byte_array table Array of byte values [0-255]
---@return string Base64 encoded string
local function bytes_to_base64(byte_array)
	local binary = bytes_to_string(byte_array)
	if binary == "" then
		return ""
	end
	return vim.base64.encode(binary)
end

--- Parse a message received from the server
--- Server uses two formats:
--- 1. Direct response: {"type": "sync_response", "data": "<base64>"}
--- 2. Broadcast (enum-style): {"Update": {"document_id": "...", "update": [byte array]}}
---@param json_str string JSON message string
---@return table|nil Parsed message table, or nil on error
---@return string|nil Error message if parsing failed
function M.parse(json_str)
	local ok, msg = pcall(vim.fn.json_decode, json_str)
	if not ok then
		return nil, "JSON parse error: " .. tostring(msg)
	end
	if type(msg) ~= "table" then
		return nil, "Expected JSON object"
	end

	-- Handle direct format: {"type": "..."}
	if msg.type then
		return msg, nil
	end

	-- Handle enum-style broadcast format: {"Update": {...}}
	-- Convert to normalized format with base64-encoded data
	if msg.Update then
		return {
			type = "update",
			document_id = msg.Update.document_id,
			-- update field is a byte array, convert to base64 for our CRDT module
			data = bytes_to_base64(msg.Update.update),
		},
			nil
	end

	if msg.Awareness then
		return {
			type = "awareness",
			document_id = msg.Awareness.document_id,
			data = bytes_to_base64(msg.Awareness.update),
		},
			nil
	end

	if msg.Chat then
		return {
			type = "chat",
			document_id = msg.Chat.document_id,
			from = msg.Chat.from,
			message = msg.Chat.message,
		},
			nil
	end

	if msg.System then
		return {
			type = "system",
			message = msg.System,
		}, nil
	end

	return nil, "Unknown message format"
end

--- Check if a message is of a specific type
---@param msg table Parsed message
---@param msg_type string Expected type (e.g., "sync_response")
---@return boolean
function M.is_type(msg, msg_type)
	return msg and msg.type == msg_type
end

--- Get the message type
---@param msg table Parsed message
---@return string|nil Message type
function M.get_type(msg)
	return msg and msg.type
end

return M

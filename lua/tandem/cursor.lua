-- Cursor tracking and remote cursor display module
-- Handles awareness protocol for cursor positions

local M = {}

-- Remote cursor state: { [client_id] = { line, col, name, color, extmark_id } }
local remote_cursors = {}

-- Local cursor state
local local_state = {
	line = 1,
	col = 0,
	name = "user",
	color = "#ffff00",
}

-- Extmark namespace for remote cursors
local ns_id = nil

-- Buffer we're tracking
local tracked_bufnr = nil

-- Color palette for remote users (8 distinct colors)
local color_palette = {
	"#ff6b6b", -- red
	"#4ecdc4", -- teal
	"#ffe66d", -- yellow
	"#95e1d3", -- mint
	"#f38181", -- coral
	"#aa96da", -- lavender
	"#fcbad3", -- pink
	"#a8d8ea", -- sky blue
}

--- Hash a string to a number for consistent color assignment
local function hash_string(str)
	local h = 0
	for i = 1, #str do
		h = (h * 31 + str:byte(i)) % 2147483647
	end
	return h
end

--- Get a color for a client ID
local function get_color_for_client(client_id)
	local idx = (hash_string(client_id) % #color_palette) + 1
	return color_palette[idx]
end

--- Initialize the cursor module
--- @param bufnr number Buffer number to track
--- @param user_name string Local user's name
function M.setup(bufnr, user_name)
	tracked_bufnr = bufnr
	local_state.name = user_name or "user"

	-- Create namespace for extmarks
	if not ns_id then
		ns_id = vim.api.nvim_create_namespace("tandem_cursors")
	end

	-- Set up autocmds to track local cursor
	local group = vim.api.nvim_create_augroup("TandemCursor", { clear = true })

	vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
		group = group,
		buffer = bufnr,
		callback = function()
			local pos = vim.api.nvim_win_get_cursor(0)
			local_state.line = pos[1]
			local_state.col = pos[2]
		end,
	})
end

--- Clean up cursor tracking
function M.cleanup()
	-- Clear extmarks
	if ns_id and tracked_bufnr and vim.api.nvim_buf_is_valid(tracked_bufnr) then
		vim.api.nvim_buf_clear_namespace(tracked_bufnr, ns_id, 0, -1)
	end

	-- Clear remote cursors
	remote_cursors = {}

	-- Remove autocmds
	pcall(vim.api.nvim_del_augroup_by_name, "TandemCursor")

	tracked_bufnr = nil
end

--- Get local cursor state for awareness broadcast
--- @return table Local cursor state
function M.get_local_state()
	return {
		cursor = {
			line = local_state.line,
			col = local_state.col,
		},
		user = {
			name = local_state.name,
			color = local_state.color,
		},
	}
end

--- Update remote cursor state from awareness message
--- @param client_id string Remote client ID
--- @param state table Cursor state { cursor = { line, col }, user = { name, color } }
function M.update_remote(client_id, state)
	if not state or not state.cursor then
		return
	end

	local cursor = state.cursor
	local user = state.user or {}

	-- Get or create remote cursor entry
	local entry = remote_cursors[client_id]
	if not entry then
		entry = {
			line = 1,
			col = 0,
			name = user.name or ("User " .. client_id:sub(1, 4)),
			color = user.color or get_color_for_client(client_id),
			extmark_id = nil,
		}
		remote_cursors[client_id] = entry
	end

	-- Update cursor position
	entry.line = cursor.line or entry.line
	entry.col = cursor.col or entry.col
	entry.name = user.name or entry.name
	if user.color then
		entry.color = user.color
	end

	-- Render the cursor
	M.render_cursor(client_id, entry)
end

--- Remove a remote cursor
--- @param client_id string Remote client ID
function M.remove_remote(client_id)
	local entry = remote_cursors[client_id]
	if entry then
		-- Remove extmark
		if entry.extmark_id and tracked_bufnr and vim.api.nvim_buf_is_valid(tracked_bufnr) then
			pcall(vim.api.nvim_buf_del_extmark, tracked_bufnr, ns_id, entry.extmark_id)
		end
		remote_cursors[client_id] = nil
	end
end

--- Render a remote cursor as an extmark
--- @param client_id string Remote client ID
--- @param entry table Cursor entry
function M.render_cursor(client_id, entry)
	if not tracked_bufnr or not vim.api.nvim_buf_is_valid(tracked_bufnr) then
		return
	end

	-- Remove old extmark if exists
	if entry.extmark_id then
		pcall(vim.api.nvim_buf_del_extmark, tracked_bufnr, ns_id, entry.extmark_id)
		entry.extmark_id = nil
	end

	-- Convert 1-indexed line to 0-indexed
	local line = entry.line - 1
	local col = entry.col

	-- Ensure line is within buffer bounds
	local line_count = vim.api.nvim_buf_line_count(tracked_bufnr)
	if line < 0 then
		line = 0
	end
	if line >= line_count then
		line = line_count - 1
	end

	-- Ensure col is within line bounds
	local line_text = vim.api.nvim_buf_get_lines(tracked_bufnr, line, line + 1, false)[1] or ""
	if col > #line_text then
		col = #line_text
	end

	-- Create highlight group for this user if it doesn't exist
	local hl_name = "TandemCursor_" .. client_id:gsub("-", "_"):sub(1, 16)
	pcall(vim.api.nvim_set_hl, 0, hl_name, { bg = entry.color, fg = "#000000" })

	local hl_name_text = "TandemCursorText_" .. client_id:gsub("-", "_"):sub(1, 16)
	pcall(vim.api.nvim_set_hl, 0, hl_name_text, { fg = entry.color, bold = true })

	-- Create extmark with virtual text showing username
	local ok, id = pcall(vim.api.nvim_buf_set_extmark, tracked_bufnr, ns_id, line, col, {
		virt_text = { { " " .. entry.name .. " ", hl_name_text } },
		virt_text_pos = "eol",
		hl_mode = "combine",
		priority = 100,
	})

	if ok then
		entry.extmark_id = id
	end
end

--- Render all remote cursors
function M.render_all()
	for client_id, entry in pairs(remote_cursors) do
		M.render_cursor(client_id, entry)
	end
end

--- Get list of remote users
--- @return table List of { client_id, name, color }
function M.get_remote_users()
	local users = {}
	for client_id, entry in pairs(remote_cursors) do
		table.insert(users, {
			client_id = client_id,
			name = entry.name,
			color = entry.color,
		})
	end
	return users
end

--- Get count of remote users
--- @return number
function M.get_user_count()
	local count = 0
	for _ in pairs(remote_cursors) do
		count = count + 1
	end
	return count
end

return M

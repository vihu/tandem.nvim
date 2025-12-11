-- Buffer synchronization module
-- Bridges Neovim buffer changes to/from CRDT document using TextDelta events
--
-- Uses on_lines callback (not on_bytes) because the buffer is already updated
-- when on_lines fires, making text extraction reliable. Maintains a shadow copy
-- of previous buffer state to compute byte offsets for CRDT operations.

local M = {}

-- State per buffer
-- Key: bufnr, Value: { doc_id, is_applying_remote, prev_lines }
-- prev_lines: shadow copy of buffer lines for computing what changed
local attached_buffers = {}

-- Reference to FFI (set by attach)
local ffi = nil

-- Callback for edit notifications (set by session.lua)
local on_edit_callback = nil

--- Convert line number to byte offset in buffer content
--- @param lines table Array of lines
--- @param line_num number 0-indexed line number
--- @return number Byte offset
local function line_to_byte_offset(lines, line_num)
	local offset = 0
	for i = 1, line_num do
		if lines[i] then
			offset = offset + #lines[i] + 1 -- +1 for newline
		end
	end
	return offset
end

--- Convert byte offset to row/col position
--- @param bufnr number Buffer number
--- @param byte_offset number Byte offset from start of buffer
--- @return number, number Row and column (0-indexed)
local function byte_to_row_col(bufnr, byte_offset)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, true)
	local bytes = 0

	for row, line in ipairs(lines) do
		local line_len = #line + 1 -- +1 for newline (except last line, handled below)

		-- Check if we're on the last line (no trailing newline)
		if row == #lines then
			line_len = #line
		end

		if bytes + line_len > byte_offset then
			-- Found the line
			local col = byte_offset - bytes
			return row - 1, col -- Convert to 0-indexed
		end

		bytes = bytes + line_len
	end

	-- Past end of buffer - return end position
	if #lines == 0 then
		return 0, 0
	end
	return #lines - 1, #(lines[#lines] or "")
end

--- on_lines callback for nvim_buf_attach
--- Called AFTER buffer content changes - buffer state is already updated.
---
--- Parameters from nvim_buf_attach on_lines:
--- - firstline: first line that changed (0-indexed)
--- - lastline: last line in the OLD buffer that was replaced (exclusive, 0-indexed)
--- - new_lastline: last line in the NEW range (exclusive, 0-indexed)
--- - old_byte_count: byte count of the OLD text that was replaced (Neovim 0.11+)
local function on_lines(_event, bufnr, _changedtick, firstline, lastline, new_lastline, old_byte_count)
	local state = attached_buffers[bufnr]
	if not state then
		return
	end

	-- Ignore changes while we're applying remote updates
	if state.is_applying_remote then
		return
	end

	-- Get the new lines from the buffer (buffer is already updated)
	local new_lines = vim.api.nvim_buf_get_lines(bufnr, firstline, new_lastline, true)

	-- Get the old lines from our shadow copy
	local prev_lines = state.prev_lines or {}
	local old_lines = {}
	for i = firstline + 1, lastline do -- Lua is 1-indexed
		if prev_lines[i] then
			table.insert(old_lines, prev_lines[i])
		end
	end

	-- Compute byte offset where the change starts
	local start_byte = line_to_byte_offset(prev_lines, firstline)

	-- Determine if lines were added/removed or just modified in place
	-- If lastline == new_lastline, the same lines exist but content changed (in-line edit)
	-- If lastline != new_lastline, lines were added or removed
	local lines_changed = (lastline ~= new_lastline)

	-- Compute the old text that was deleted
	local old_text = table.concat(old_lines, "\n")
	-- Only add trailing newline if lines were actually removed (not in-line edit)
	if lines_changed and #old_lines > 0 then
		old_text = old_text .. "\n"
	end

	-- Compute the new text that was inserted
	local new_text = table.concat(new_lines, "\n")
	-- Only add trailing newline if lines were actually added (not in-line edit)
	if lines_changed and #new_lines > 0 then
		new_text = new_text .. "\n"
	end

	-- Compute old byte length
	-- For line-changing edits, trust Neovim's old_byte_count (includes newlines)
	-- For in-line edits, use our computed old_text length (more reliable)
	local old_byte_len
	if lines_changed and old_byte_count then
		old_byte_len = old_byte_count
	else
		old_byte_len = #old_text
	end

	-- Update shadow copy with current buffer state
	state.prev_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, true)

	-- Apply to CRDT: delete old_byte_len bytes at start_byte, insert new_text
	local end_byte = start_byte + old_byte_len
	ffi.crdt.doc_apply_edit(state.doc_id, start_byte, end_byte, new_text)

	-- Notify session about the edit (for debouncing)
	if on_edit_callback then
		on_edit_callback()
	end
end

--- Attach buffer to CRDT document
--- @param bufnr number Buffer number
--- @param doc_id string CRDT document ID
--- @param ffi_ref table FFI module reference
--- @return boolean Success
function M.attach(bufnr, doc_id, ffi_ref)
	if attached_buffers[bufnr] then
		return false -- Already attached
	end

	ffi = ffi_ref

	-- Initialize shadow copy with current buffer content
	local initial_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, true)

	local state = {
		doc_id = doc_id,
		is_applying_remote = false,
		prev_lines = initial_lines, -- Shadow copy for computing changes
	}

	-- Attach to buffer with on_lines callback (not on_bytes)
	-- on_lines fires AFTER the buffer is updated, making text extraction reliable
	local ok = vim.api.nvim_buf_attach(bufnr, false, {
		on_lines = on_lines,
		on_detach = function()
			attached_buffers[bufnr] = nil
		end,
	})

	if not ok then
		return false
	end

	attached_buffers[bufnr] = state
	return true
end

--- Detach buffer from CRDT
--- @param bufnr number Buffer number
function M.detach(bufnr)
	local state = attached_buffers[bufnr]
	if not state then
		return
	end

	-- nvim_buf_attach returns false to detach when called in on_bytes
	-- For explicit detach, we just remove from our tracking
	-- The actual detach happens via returning true from a callback
	attached_buffers[bufnr] = nil
end

--- Apply TextDelta events to buffer incrementally
--- This is the core of the Loro integration - deltas give us precise operations
--- Format: {"type":"retain"|"insert"|"delete", "len":N} or {"type":"insert", "text":"..."}
--- @param bufnr number Buffer number
--- @param deltas table List of TextDelta events
function M.apply_deltas(bufnr, deltas)
	local state = attached_buffers[bufnr]
	if not state then
		return
	end

	state.is_applying_remote = true

	-- CRITICAL: Disable ALL autocmds to prevent formatters/plugins from modifying
	-- the buffer during sync. This prevents divergence between CRDT and buffer.
	local old_eventignore = vim.o.eventignore
	vim.o.eventignore = "all"

	-- Current byte position in the buffer (cursor for delta application)
	local byte_pos = 0

	for _, delta in ipairs(deltas) do
		if delta.type == "retain" then
			-- Skip forward by delta.len bytes (no buffer change)
			byte_pos = byte_pos + delta.len
		elseif delta.type == "insert" then
			-- Insert text at current position
			local row, col = byte_to_row_col(bufnr, byte_pos)
			local lines = vim.split(delta.text, "\n", { plain = true })

			local ok, err = pcall(function()
				vim.api.nvim_buf_set_text(bufnr, row, col, row, col, lines)
			end)

			if not ok then
				vim.schedule(function()
					vim.notify("[tandem] Delta insert error: " .. tostring(err), vim.log.levels.DEBUG)
				end)
			end

			-- Move cursor past inserted text
			byte_pos = byte_pos + #delta.text
		elseif delta.type == "delete" then
			-- Delete delta.len bytes at current position
			local start_row, start_col = byte_to_row_col(bufnr, byte_pos)
			local end_row, end_col = byte_to_row_col(bufnr, byte_pos + delta.len)

			local ok, err = pcall(function()
				vim.api.nvim_buf_set_text(bufnr, start_row, start_col, end_row, end_col, {})
			end)

			if not ok then
				vim.schedule(function()
					vim.notify("[tandem] Delta delete error: " .. tostring(err), vim.log.levels.DEBUG)
				end)
			end

			-- byte_pos stays the same - deletion shrinks buffer, we're now at the next content
		end
	end

	-- Restore eventignore
	vim.o.eventignore = old_eventignore

	-- Clear flag synchronously - on_bytes callbacks fire DURING nvim_buf_set_text,
	-- so by the time we reach here, all callbacks have been processed.
	state.is_applying_remote = false
end

--- Poll CRDT for changes and sync buffer if needed
--- Uses the CRDT as single source of truth - if buffer differs, replace it
--- @param bufnr number Buffer number
--- @return number 1 if synced, 0 if no change needed
function M.poll_and_apply(bufnr)
	local state = attached_buffers[bufnr]
	if not state or not ffi then
		return 0
	end

	-- Clear any pending deltas (we don't use them - we do full sync)
	-- This is important to drain the queue so it doesn't grow unbounded
	local delta_jsons = ffi.crdt.doc_poll_deltas(state.doc_id)
	if #delta_jsons == 0 then
		-- No remote changes happened
		return 0
	end

	-- Remote changes happened - compare buffer with CRDT and sync if different
	local crdt_content = ffi.crdt.doc_get_text(state.doc_id)
	local buf_content = M.get_content(bufnr)

	if crdt_content == buf_content then
		-- Already in sync (local edit was identical to remote, rare but possible)
		return 0
	end

	-- Buffer differs from CRDT - replace buffer with CRDT content
	-- CRDT is the source of truth after merging all peer edits
	state.is_applying_remote = true

	-- Save cursor position (best effort)
	local cursor_pos = vim.api.nvim_win_get_cursor(0)
	local cursor_line, cursor_col = cursor_pos[1], cursor_pos[2]

	-- Replace buffer content
	local lines = vim.split(crdt_content, "\n", { plain = true })
	local ok, err = pcall(function()
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, lines)
	end)

	if not ok then
		vim.schedule(function()
			vim.notify("[tandem] Buffer sync error: " .. tostring(err), vim.log.levels.ERROR)
		end)
	end

	-- Restore cursor position (clamped to valid range)
	local new_line_count = #lines
	if cursor_line > new_line_count then
		cursor_line = new_line_count
	end
	if cursor_line > 0 then
		local line_len = #(lines[cursor_line] or "")
		if cursor_col > line_len then
			cursor_col = line_len
		end
		pcall(vim.api.nvim_win_set_cursor, 0, { cursor_line, cursor_col })
	end

	state.is_applying_remote = false
	return 1
end

--- Check if buffer is attached
--- @param bufnr number Buffer number
--- @return boolean
function M.is_attached(bufnr)
	return attached_buffers[bufnr] ~= nil
end

--- Get doc_id for attached buffer
--- @param bufnr number Buffer number
--- @return string|nil
function M.get_doc_id(bufnr)
	local state = attached_buffers[bufnr]
	return state and state.doc_id or nil
end

--- Get buffer content as single string
--- Includes trailing newline to match Neovim's byte offset counting.
--- @param bufnr number Buffer number
--- @return string
function M.get_content(bufnr)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, true)
	-- Add trailing newline to match Neovim's byte counting (each line has EOL)
	return table.concat(lines, "\n") .. "\n"
end

--- Set buffer content from CRDT (initial sync)
--- Content is expected to have a trailing newline (matching get_content format).
--- @param bufnr number Buffer number
--- @param content string Content to set (with trailing newline)
function M.set_content(bufnr, content)
	local state = attached_buffers[bufnr]
	if state then
		state.is_applying_remote = true
	end

	-- CRITICAL: Disable ALL autocmds to prevent formatters/plugins from modifying
	-- the buffer during sync. This prevents divergence between CRDT and buffer.
	local old_eventignore = vim.o.eventignore
	vim.o.eventignore = "all"

	-- Disable fixeol to prevent Neovim from adding trailing newlines
	local old_fixeol = vim.bo[bufnr].fixendofline
	vim.bo[bufnr].fixendofline = false

	-- Remove trailing newline before splitting (we add it in get_content for
	-- byte offset consistency, but nvim_buf_set_lines doesn't want it)
	local content_without_trailing = content:gsub("\n$", "")
	local lines = vim.split(content_without_trailing, "\n", { plain = true })
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, lines)

	-- Restore settings
	vim.bo[bufnr].fixendofline = old_fixeol
	vim.o.eventignore = old_eventignore

	-- Update shadow copy to match new buffer content
	-- This is critical for the on_lines callback to work correctly
	if state then
		state.prev_lines = lines
		state.is_applying_remote = false
	end
end

--- Set callback for edit notifications
--- Called when a local edit is applied to CRDT (for debounce timing)
--- @param callback function|nil Callback function or nil to clear
function M.set_on_edit_callback(callback)
	on_edit_callback = callback
end

return M

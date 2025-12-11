-- Stress test for tandem.nvim
-- Tests CRDT convergence under sequential edits from multiple clients
--
-- Usage:
--   1. Start a WebSocket relay server
--   2. Run ./scripts/stress_test.sh A in terminal A
--   3. Run ./scripts/stress_test.sh B in terminal B
--   4. In instance A: run :StressTest
--   5. Wait for completion, then in instance B: run :StressCompare to verify sync
--   6. In instance B: run :StressTest
--   7. Wait for completion, then in instance A: run :StressCompare to verify sync
--   8. Repeat as needed - hashes should always match after sync

local M = {}

-- Configuration
local config = {
	num_edits = 500, -- Number of random edits per test run
	edit_delay_ms = 20, -- Delay between edits (ms) - models fast human typing
	sync_wait_ms = 3000, -- Wait time after edits for sync to settle
	instance_id = tostring(math.random(1000, 9999)), -- Unique ID for this instance
}

-- Simple hash function for content comparison
local function hash_content(content)
	local h = 0
	for i = 1, #content do
		h = (h * 31 + content:byte(i)) % 2147483647
	end
	return string.format("%08x", h)
end

-- Generate random printable character
local function random_char()
	local chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 "
	local idx = math.random(1, #chars)
	return chars:sub(idx, idx)
end

-- Generate random string of 1-5 chars
local function random_string()
	local len = math.random(1, 5)
	local s = ""
	for _ = 1, len do
		s = s .. random_char()
	end
	return s
end

-- Perform a single random edit on the buffer
local function random_edit(bufnr)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, true)
	local line_count = math.max(1, #lines)

	-- Pick random line
	local row = math.random(1, line_count) - 1
	local line = lines[row + 1] or ""
	local line_len = #line

	-- Pick random operation: 1=insert, 2=delete, 3=replace, 4=newline
	local op = math.random(1, 4)

	if op == 1 then
		-- Insert random chars at random position
		local col = math.random(0, line_len)
		local text = random_string()
		local ok, err = pcall(vim.api.nvim_buf_set_text, bufnr, row, col, row, col, { text })
		if not ok then
			return false, "insert failed: " .. tostring(err)
		end
		return true, string.format("insert '%s' at %d:%d", text, row, col)
	elseif op == 2 and line_len > 0 then
		-- Delete 1-3 chars
		local col = math.random(0, math.max(0, line_len - 1))
		local del_len = math.min(math.random(1, 3), line_len - col)
		local end_col = col + del_len
		local ok, err = pcall(vim.api.nvim_buf_set_text, bufnr, row, col, row, end_col, { "" })
		if not ok then
			return false, "delete failed: " .. tostring(err)
		end
		return true, string.format("delete %d:%d-%d", row, col, end_col)
	elseif op == 3 and line_len > 0 then
		-- Replace 1-2 chars
		local col = math.random(0, math.max(0, line_len - 1))
		local rep_len = math.min(math.random(1, 2), line_len - col)
		local end_col = col + rep_len
		local text = random_string():sub(1, math.random(1, 3))
		local ok, err = pcall(vim.api.nvim_buf_set_text, bufnr, row, col, row, end_col, { text })
		if not ok then
			return false, "replace failed: " .. tostring(err)
		end
		return true, string.format("replace %d:%d-%d with '%s'", row, col, end_col, text)
	else
		-- Insert newline (creates new line)
		local col = math.random(0, line_len)
		local ok, err = pcall(vim.api.nvim_buf_set_text, bufnr, row, col, row, col, { "", "" })
		if not ok then
			return false, "newline failed: " .. tostring(err)
		end
		return true, string.format("newline at %d:%d", row, col)
	end
end

-- Run the stress test
function M.run_test()
	local bufnr = vim.api.nvim_get_current_buf()

	-- Check if tandem session is active
	local session = require("tandem.session")
	if not session.is_active() then
		vim.notify("[stress_test] Not in a tandem session! Join first with :TandemJoin", vim.log.levels.ERROR)
		return
	end

	vim.notify(
		string.format("[stress_test:%s] Starting %d random edits...", config.instance_id, config.num_edits),
		vim.log.levels.INFO
	)

	local edit_count = 0
	local error_count = 0
	local start_time = vim.uv.now()

	-- Use a timer to spread edits over time
	local timer = vim.uv.new_timer()
	timer:start(
		0,
		config.edit_delay_ms,
		vim.schedule_wrap(function()
			if edit_count >= config.num_edits then
				timer:stop()
				timer:close()

				local elapsed = vim.uv.now() - start_time
				vim.notify(
					string.format(
						"[stress_test:%s] Completed %d edits in %dms (%d errors). Waiting %dms for sync...",
						config.instance_id,
						edit_count,
						elapsed,
						error_count,
						config.sync_wait_ms
					),
					vim.log.levels.INFO
				)

				-- Wait for sync to settle, then show hash
				vim.defer_fn(function()
					M.show_hash()
				end, config.sync_wait_ms)

				return
			end

			local ok, msg = random_edit(bufnr)
			edit_count = edit_count + 1

			if not ok then
				error_count = error_count + 1
			end

			-- Progress update every 100 edits
			if edit_count % 100 == 0 then
				vim.notify(
					string.format(
						"[stress_test:%s] Progress: %d/%d edits",
						config.instance_id,
						edit_count,
						config.num_edits
					),
					vim.log.levels.INFO
				)
			end
		end)
	)
end

-- Show content hash for comparison
function M.show_hash()
	local bufnr = vim.api.nvim_get_current_buf()
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, true)
	local content = table.concat(lines, "\n")
	local h = hash_content(content)
	local line_count = #lines
	local byte_count = #content

	-- Use nvim_echo to force display
	local msg = string.format(
		"\n========================================\n"
			.. "[stress_test:%s] RESULT\n"
			.. "  HASH:  %s\n"
			.. "  LINES: %d\n"
			.. "  BYTES: %d\n"
			.. "========================================\n",
		config.instance_id,
		h,
		line_count,
		byte_count
	)
	vim.api.nvim_echo({ { msg, "WarningMsg" } }, true, {})
end

-- Get detailed content info for debugging divergence
function M.debug_content()
	local bufnr = vim.api.nvim_get_current_buf()
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, true)

	print("=== Buffer Content Debug ===")
	print(string.format("Line count: %d", #lines))

	for i, line in ipairs(lines) do
		if i <= 20 then -- First 20 lines
			print(string.format("%3d: [%d] %s", i, #line, line:sub(1, 60)))
		end
	end

	if #lines > 20 then
		print(string.format("... and %d more lines", #lines - 20))
	end
end

-- Commands
vim.api.nvim_create_user_command("StressTest", function()
	M.run_test()
end, { desc = "Run 500 random edits, then show hash" })

vim.api.nvim_create_user_command("StressCompare", function()
	M.show_hash()
end, { desc = "Show content hash for comparison" })

vim.api.nvim_create_user_command("StressDebug", function()
	M.debug_content()
end, { desc = "Debug buffer content" })

vim.api.nvim_echo({
	{ string.format("[stress_test:%s] Loaded.\n", config.instance_id), "Normal" },
	{ "  :StressTest   - Run 500 random edits on this instance\n", "Normal" },
	{ "  :StressCompare - Show content hash (should match other instance)\n", "Normal" },
	{ "  :StressDebug  - Debug buffer content\n", "Normal" },
}, true, {})

return M

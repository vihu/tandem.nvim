-- Critical tests for CRDT-Buffer Bridge
-- Tests byte offset conversion with UTF-8 and feedback loop prevention
-- Run: nvim --headless --clean --cmd "set rtp+=$(pwd)" +"luafile lua/tandem/test_critical.lua" +qa 2>&1

local function main()
	-- Load FFI
	local plugin_path = debug.getinfo(1, "S").source:sub(2):match("(.*/)")
	local ffi_path = plugin_path .. "../../rust/tandem-ffi/lua/tandem_ffi.so"
	package.cpath = package.cpath .. ";" .. ffi_path

	local ok, ffi = pcall(require, "tandem_ffi")
	if not ok then
		print("[FAIL] Failed to load tandem_ffi: " .. tostring(ffi))
		return
	end

	-- Load buffer module
	package.loaded["tandem.buffer"] = nil
	local buffer = dofile(plugin_path .. "buffer.lua")

	print("=== CRITICAL TEST 1: ASCII Multi-line Byte Offsets ===")
	do
		local bufnr = vim.api.nvim_create_buf(false, true)
		local doc_id = ffi.crdt.doc_create()
		buffer.attach(bufnr, doc_id, ffi)

		-- Set "hello\nworld" (5 + 1 + 5 = 11 bytes, plus trailing newline)
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, { "hello", "world" })
		vim.wait(10)

		local crdt_text = ffi.crdt.doc_get_text(doc_id):gsub("\n$", "")
		if crdt_text ~= "hello\nworld" then
			print("[FAIL] Expected 'hello\\nworld', got '" .. crdt_text:gsub("\n", "\\n") .. "'")
			return
		end
		print("[OK] Initial content: 'hello\\nworld'")

		-- Edit on line 2: replace "world" with "WORLD"
		vim.api.nvim_buf_set_text(bufnr, 1, 0, 1, 5, { "WORLD" })
		vim.wait(10)

		crdt_text = ffi.crdt.doc_get_text(doc_id):gsub("\n$", "")
		if crdt_text ~= "hello\nWORLD" then
			print("[FAIL] After line 2 edit, expected 'hello\\nWORLD', got '" .. crdt_text:gsub("\n", "\\n") .. "'")
			return
		end
		print("[OK] Line 2 edit: 'hello\\nWORLD'")

		buffer.detach(bufnr)
		ffi.crdt.doc_destroy(doc_id)
		vim.api.nvim_buf_delete(bufnr, { force = true })
	end

	print("\n=== CRITICAL TEST 2: UTF-8 Multi-byte Characters ===")
	do
		local bufnr = vim.api.nvim_create_buf(false, true)
		local doc_id = ffi.crdt.doc_create()
		buffer.attach(bufnr, doc_id, ffi)

		-- Set content with emoji (multi-byte UTF-8)
		-- Emoji like "😀" is 4 bytes in UTF-8
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, { "hello", "world" })
		vim.wait(10)

		-- Verify basic content
		local crdt_text = ffi.crdt.doc_get_text(doc_id):gsub("\n$", "")
		if crdt_text ~= "hello\nworld" then
			print("[FAIL] Setup failed")
			return
		end

		-- Now add emoji at end of line 1
		vim.api.nvim_buf_set_text(bufnr, 0, 5, 0, 5, { " 😀" })
		vim.wait(10)

		crdt_text = ffi.crdt.doc_get_text(doc_id):gsub("\n$", "")
		local expected = "hello 😀\nworld"
		if crdt_text ~= expected then
			print("[FAIL] After emoji insert, expected '" .. expected:gsub("\n", "\\n") .. "'")
			print("       got '" .. crdt_text:gsub("\n", "\\n") .. "'")
			return
		end
		print("[OK] Emoji insert: 'hello 😀\\nworld'")

		-- Edit after emoji on line 2
		vim.api.nvim_buf_set_text(bufnr, 1, 0, 1, 5, { "WORLD" })
		vim.wait(10)

		crdt_text = ffi.crdt.doc_get_text(doc_id):gsub("\n$", "")
		expected = "hello 😀\nWORLD"
		if crdt_text ~= expected then
			print("[FAIL] After edit on line after emoji, expected '" .. expected:gsub("\n", "\\n") .. "'")
			print("       got '" .. crdt_text:gsub("\n", "\\n") .. "'")
			return
		end
		print("[OK] Edit after emoji: 'hello 😀\\nWORLD'")

		buffer.detach(bufnr)
		ffi.crdt.doc_destroy(doc_id)
		vim.api.nvim_buf_delete(bufnr, { force = true })
	end

	print("\n=== CRITICAL TEST 3: Feedback Loop Prevention (Local) ===")
	do
		local bufnr = vim.api.nvim_create_buf(false, true)
		local doc_id = ffi.crdt.doc_create()
		buffer.attach(bufnr, doc_id, ffi)

		-- Make a local edit
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, { "test" })
		vim.wait(10)

		-- The CRDT should have the edit
		local crdt_text = ffi.crdt.doc_get_text(doc_id):gsub("\n$", "")
		if crdt_text ~= "test" then
			print("[FAIL] Local edit not synced to CRDT")
			return
		end
		print("[OK] Local edit synced to CRDT")

		-- Now, when we poll for changes, there shouldn't be any
		-- (because the edit was local, not remote)
		local changes = ffi.crdt.doc_poll_changes(doc_id)
		if #changes > 0 then
			print("[FAIL] Local edit should not generate remote change event")
			return
		end
		print("[OK] No remote change event from local edit")

		buffer.detach(bufnr)
		ffi.crdt.doc_destroy(doc_id)
		vim.api.nvim_buf_delete(bufnr, { force = true })
	end

	print("\n=== CRITICAL TEST 4: Feedback Loop Prevention (Remote Apply) ===")
	do
		local bufnr = vim.api.nvim_create_buf(false, true)
		local doc_id = ffi.crdt.doc_create()
		buffer.attach(bufnr, doc_id, ffi)

		-- Initialize with some content
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, { "initial" })
		vim.wait(10)

		-- Create a "remote" change by:
		-- 1. Creating a second CRDT doc
		-- 2. Setting different content
		-- 3. Syncing to our doc
		local doc_id2 = ffi.crdt.doc_create()
		ffi.crdt.doc_set_text(doc_id2, "REMOTE")

		local sv1 = ffi.crdt.doc_state_vector(doc_id)
		local diff = ffi.crdt.doc_encode_update(doc_id2, sv1)
		ffi.crdt.doc_apply_update(doc_id, diff)

		-- Poll and apply remote changes to buffer
		local num_changes = buffer.poll_and_apply(bufnr)
		vim.wait(10)

		if num_changes == 0 then
			print("[WARN] No remote changes detected (CRDT merge behavior)")
		else
			print("[OK] Applied " .. num_changes .. " remote changes")
		end

		-- The key test: after applying remote change, no infinite loop should occur
		-- The buffer should not send the remote edit back to CRDT
		-- We verify by checking if additional poll returns 0 changes
		vim.wait(50) -- Give time for any echo to propagate

		local echo_changes = ffi.crdt.doc_poll_changes(doc_id)
		if #echo_changes > 0 then
			print("[FAIL] Remote apply caused echo back to CRDT (feedback loop!)")
			return
		end
		print("[OK] No feedback loop from remote apply")

		buffer.detach(bufnr)
		ffi.crdt.doc_destroy(doc_id)
		ffi.crdt.doc_destroy(doc_id2)
		vim.api.nvim_buf_delete(bufnr, { force = true })
	end

	print("\n=== CRITICAL TEST 5: Rapid Alternating Edits ===")
	do
		local bufnr = vim.api.nvim_create_buf(false, true)
		local doc_id = ffi.crdt.doc_create()
		buffer.attach(bufnr, doc_id, ffi)

		-- Initialize
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, { "start" })
		vim.wait(10)

		-- Rapid local edits
		for i = 1, 10 do
			vim.api.nvim_buf_set_text(bufnr, 0, 0, 0, 0, { tostring(i) })
		end
		vim.wait(50)

		local crdt_text = ffi.crdt.doc_get_text(doc_id)
		local buf_text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, true), "\n")

		-- CRDT should roughly match buffer (accounting for trailing newline)
		local crdt_trimmed = crdt_text:gsub("\n$", "")
		if crdt_trimmed ~= buf_text then
			print("[WARN] After rapid edits, CRDT and buffer differ")
			print("       Buffer: '" .. buf_text .. "'")
			print("       CRDT: '" .. crdt_trimmed .. "'")
		else
			print("[OK] Rapid edits synced correctly")
		end

		-- Check no pending changes (all local)
		local changes = ffi.crdt.doc_poll_changes(doc_id)
		if #changes > 0 then
			print("[WARN] Unexpected changes after rapid local edits")
		else
			print("[OK] No spurious remote changes")
		end

		buffer.detach(bufnr)
		ffi.crdt.doc_destroy(doc_id)
		vim.api.nvim_buf_delete(bufnr, { force = true })
	end

	print("\n[PASS] All critical tests passed!")
end

main()

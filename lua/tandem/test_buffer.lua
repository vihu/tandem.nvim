-- Test script for buffer sync module
-- Run: nvim --headless --clean --cmd "set rtp+=$(pwd)" +"luafile lua/tandem/test_buffer.lua" +qa 2>&1

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
	print("[OK] FFI loaded")

	-- Load buffer module
	package.loaded["tandem.buffer"] = nil -- Clear cache
	local buffer = dofile(plugin_path .. "buffer.lua")
	print("[OK] Buffer module loaded")

	-- Create a scratch buffer for testing
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_current_buf(bufnr)
	print("[OK] Created test buffer: " .. bufnr)

	-- Create CRDT document
	local doc_id = ffi.crdt.doc_create()
	print("[OK] Created CRDT doc: " .. doc_id)

	-- Test 1: Attach buffer
	local attached = buffer.attach(bufnr, doc_id, ffi)
	if not attached then
		print("[FAIL] buffer.attach returned false")
		return
	end
	print("[OK] Buffer attached")

	-- Test 2: Verify attachment
	if not buffer.is_attached(bufnr) then
		print("[FAIL] buffer.is_attached returned false")
		return
	end
	print("[OK] buffer.is_attached")

	-- Test 3: Set initial content via buffer
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, { "hello" })
	vim.wait(10)

	-- Verify CRDT got the content
	-- Note: Neovim internally treats buffer as "hello\n" (with trailing newline)
	-- so we accept either "hello" or "hello\n"
	local crdt_text = ffi.crdt.doc_get_text(doc_id)
	local crdt_text_trimmed = crdt_text:gsub("\n$", "")
	if crdt_text_trimmed ~= "hello" then
		print("[FAIL] After set_lines, CRDT expected 'hello', got '" .. crdt_text:gsub("\n", "\\n") .. "'")
		return
	end
	print("[OK] Local edit synced to CRDT: '" .. crdt_text:gsub("\n", "\\n") .. "'")

	-- Test 4: Append text
	vim.api.nvim_buf_set_text(bufnr, 0, 5, 0, 5, { " world" })
	vim.wait(10)

	crdt_text = ffi.crdt.doc_get_text(doc_id)
	crdt_text_trimmed = crdt_text:gsub("\n$", "")
	if crdt_text_trimmed ~= "hello world" then
		print("[FAIL] After append, CRDT expected 'hello world', got '" .. crdt_text:gsub("\n", "\\n") .. "'")
		return
	end
	print("[OK] Append synced to CRDT: '" .. crdt_text:gsub("\n", "\\n") .. "'")

	-- Test 5: Replace text
	vim.api.nvim_buf_set_text(bufnr, 0, 0, 0, 5, { "hi" })
	vim.wait(10)

	crdt_text = ffi.crdt.doc_get_text(doc_id)
	crdt_text_trimmed = crdt_text:gsub("\n$", "")
	if crdt_text_trimmed ~= "hi world" then
		print("[FAIL] After replace, CRDT expected 'hi world', got '" .. crdt_text:gsub("\n", "\\n") .. "'")
		return
	end
	print("[OK] Replace synced to CRDT: '" .. crdt_text:gsub("\n", "\\n") .. "'")

	-- Test 6: Multi-line content
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, { "line1", "line2", "line3" })
	vim.wait(10)

	crdt_text = ffi.crdt.doc_get_text(doc_id)
	crdt_text_trimmed = crdt_text:gsub("\n$", "")
	if crdt_text_trimmed ~= "line1\nline2\nline3" then
		print("[FAIL] Multi-line, CRDT expected 'line1\\nline2\\nline3', got '" .. crdt_text:gsub("\n", "\\n") .. "'")
		return
	end
	print("[OK] Multi-line synced to CRDT")

	-- Test 7: Edit on second line
	vim.api.nvim_buf_set_text(bufnr, 1, 0, 1, 5, { "LINE2" })
	vim.wait(10)

	crdt_text = ffi.crdt.doc_get_text(doc_id)
	crdt_text_trimmed = crdt_text:gsub("\n$", "")
	if crdt_text_trimmed ~= "line1\nLINE2\nline3" then
		print(
			"[FAIL] After line2 edit, CRDT expected 'line1\\nLINE2\\nline3', got '"
				.. crdt_text:gsub("\n", "\\n")
				.. "'"
		)
		return
	end
	print("[OK] Line 2 edit synced to CRDT")

	-- Test 8: Simulate remote change
	-- Create a second CRDT doc, make changes, sync to first
	local doc_id2 = ffi.crdt.doc_create()
	ffi.crdt.doc_set_text(doc_id2, "REMOTE")

	-- Get update from doc2
	local sv1 = ffi.crdt.doc_state_vector(doc_id)
	local diff = ffi.crdt.doc_encode_update(doc_id2, sv1)

	-- Apply to doc1 (this will queue a change event)
	ffi.crdt.doc_apply_update(doc_id, diff)

	-- Poll and apply remote changes
	local num_changes = buffer.poll_and_apply(bufnr)
	print("[OK] poll_and_apply returned " .. num_changes .. " changes")

	vim.wait(10)

	-- Check buffer content
	local buf_content = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, true), "\n")
	-- Note: The actual content depends on CRDT merge behavior
	-- For this test, we just verify the flow works
	print("[OK] Buffer content after remote: '" .. buf_content:gsub("\n", "\\n") .. "'")

	-- Test 9: Detach
	buffer.detach(bufnr)
	if buffer.is_attached(bufnr) then
		print("[FAIL] buffer.is_attached returned true after detach")
		return
	end
	print("[OK] Buffer detached")

	-- Cleanup
	ffi.crdt.doc_destroy(doc_id)
	ffi.crdt.doc_destroy(doc_id2)
	vim.api.nvim_buf_delete(bufnr, { force = true })

	print("\n[PASS] All buffer tests passed!")
end

main()

-- Test script for CRDT module
-- Run: nvim --headless --clean --cmd "set rtp+=$(pwd)" +"luafile lua/tandem/test_crdt.lua" +qa 2>&1

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

	local crdt = ffi.crdt
	if not crdt then
		print("[FAIL] crdt module not found")
		return
	end
	print("[OK] CRDT module found")

	-- Test 1: Create document
	local doc_id = crdt.doc_create()
	if not doc_id or doc_id == "" then
		print("[FAIL] doc_create returned empty")
		return
	end
	print("[OK] doc_create: " .. doc_id)

	-- Test 2: Set initial text
	crdt.doc_set_text(doc_id, "hello")
	local text = crdt.doc_get_text(doc_id)
	if text ~= "hello" then
		print("[FAIL] doc_get_text expected 'hello', got '" .. text .. "'")
		return
	end
	print("[OK] doc_set_text/doc_get_text: 'hello'")

	-- Test 3: Apply edit - append " world"
	crdt.doc_apply_edit(doc_id, 5, 5, " world")
	text = crdt.doc_get_text(doc_id)
	if text ~= "hello world" then
		print("[FAIL] After append, expected 'hello world', got '" .. text .. "'")
		return
	end
	print("[OK] doc_apply_edit (append): 'hello world'")

	-- Test 4: Apply edit - replace "hello" with "hi"
	crdt.doc_apply_edit(doc_id, 0, 5, "hi")
	text = crdt.doc_get_text(doc_id)
	if text ~= "hi world" then
		print("[FAIL] After replace, expected 'hi world', got '" .. text .. "'")
		return
	end
	print("[OK] doc_apply_edit (replace): 'hi world'")

	-- Test 5: Apply edit - delete " world"
	crdt.doc_apply_edit(doc_id, 2, 8, "")
	text = crdt.doc_get_text(doc_id)
	if text ~= "hi" then
		print("[FAIL] After delete, expected 'hi', got '" .. text .. "'")
		return
	end
	print("[OK] doc_apply_edit (delete): 'hi'")

	-- Test 6: State vector (should be non-empty base64)
	local sv = crdt.doc_state_vector(doc_id)
	if not sv or sv == "" then
		print("[FAIL] doc_state_vector returned empty")
		return
	end
	print("[OK] doc_state_vector: " .. sv:sub(1, 20) .. "...")

	-- Test 7: Encode full state
	local state = crdt.doc_encode_full_state(doc_id)
	if not state or state == "" then
		print("[FAIL] doc_encode_full_state returned empty")
		return
	end
	print("[OK] doc_encode_full_state: " .. state:sub(1, 20) .. "...")

	-- Test 8: Create second doc and sync
	local doc_id2 = crdt.doc_create()
	print("[OK] Created second doc: " .. doc_id2)

	-- Get state vector from doc2 (empty)
	local sv2 = crdt.doc_state_vector(doc_id2)
	print("[OK] doc2 state_vector: " .. sv2)

	-- Encode diff from doc1 to sync to doc2
	local diff = crdt.doc_encode_update(doc_id, sv2)
	print("[OK] Encoded diff from doc1: " .. diff:sub(1, 30) .. "...")

	-- Apply diff to doc2
	local applied = crdt.doc_apply_update(doc_id2, diff)
	if not applied then
		print("[FAIL] doc_apply_update returned false")
		return
	end
	print("[OK] Applied update to doc2")

	-- Verify doc2 content matches doc1
	local text2 = crdt.doc_get_text(doc_id2)
	if text2 ~= "hi" then
		print("[FAIL] After sync, doc2 expected 'hi', got '" .. text2 .. "'")
		return
	end
	print("[OK] doc2 content after sync: '" .. text2 .. "'")

	-- Test 9: Poll changes (should be empty since we just synced, no remote changes)
	local changes = crdt.doc_poll_changes(doc_id2)
	print("[OK] doc_poll_changes returned " .. #changes .. " changes")

	-- Test 10: Cleanup
	crdt.doc_destroy(doc_id)
	crdt.doc_destroy(doc_id2)
	print("[OK] Documents destroyed")

	print("\n[PASS] All CRDT tests passed!")
end

main()

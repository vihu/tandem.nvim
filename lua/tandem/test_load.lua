local ok, tandem = pcall(require, "tandem")
if not ok then
	print("[FAIL] require('tandem'):", tandem)
	vim.cmd("cq")
end

tandem.setup()

if not tandem.ffi then
	print("[FAIL] FFI not loaded")
	vim.cmd("cq")
end

if type(tandem.ffi.ws.connect) ~= "function" then
	print("[FAIL] ws.connect not a function")
	vim.cmd("cq")
end

print("[OK] tandem loaded, FFI available")
print("  ws.connect:", type(tandem.ffi.ws.connect))
print("  ws.poll:", type(tandem.ffi.ws.poll))
print("  ws.send:", type(tandem.ffi.ws.send))
print("  crdt:", type(tandem.ffi.crdt))

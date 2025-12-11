-- Checkhealth module for tandem.nvim
-- Run with :checkhealth tandem

local M = {}

function M.check()
	vim.health.start("tandem")

	-- Check Neovim version (requires 0.11+)
	local nvim_version = vim.version()
	local version_str = string.format("%d.%d.%d", nvim_version.major, nvim_version.minor, nvim_version.patch)

	if nvim_version.major == 0 and nvim_version.minor < 11 then
		vim.health.error(
			string.format("Neovim 0.11+ required, found %s", version_str),
			{ "Upgrade Neovim to 0.11 or later" }
		)
	else
		vim.health.ok(string.format("Neovim version: %s", version_str))
	end

	-- Check FFI library
	local ffi_ok, ffi = pcall(require, "tandem_ffi")
	if not ffi_ok then
		vim.health.error("FFI library not found: tandem_ffi.so", {
			"Run the build step: require('tandem.build').install()",
			"Or build from source: make build",
			"Check that the binary exists in lua/ or bin/lua/ directory",
		})
	else
		vim.health.ok("FFI library loaded successfully")

		-- Check FFI modules
		local modules = { "ws", "crdt", "auth", "crypto", "code" }
		local missing = {}
		for _, mod in ipairs(modules) do
			if not ffi[mod] then
				table.insert(missing, mod)
			end
		end

		if #missing > 0 then
			vim.health.warn("FFI modules missing: " .. table.concat(missing, ", "), {
				"This may indicate an outdated or corrupted build",
				"Try rebuilding: make clean && make build",
			})
		else
			vim.health.ok("All FFI modules available: " .. table.concat(modules, ", "))
		end
	end

	-- Check for curl (needed for auto-download)
	if vim.fn.executable("curl") == 1 then
		vim.health.ok("curl found (required for auto-download)")
	else
		vim.health.warn("curl not found", {
			"curl is required for automatic binary download",
			"Install curl or build from source with: make build",
		})
	end

	-- Check installed version
	local build_ok, build = pcall(require, "tandem.build")
	if build_ok and build.get_installed_version then
		local version = build.get_installed_version()
		if version then
			vim.health.ok("Installed version: " .. version)
		end
	end

	-- Check configuration
	local tandem_ok, tandem = pcall(require, "tandem")
	if tandem_ok and tandem.get_config then
		local config = tandem.get_config()
		if config then
			vim.health.ok(string.format("Default server: %s", config.default_server or "not set"))
		end
	end
end

return M

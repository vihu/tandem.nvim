# tandem.nvim

![GitHub Actions Workflow Status](https://img.shields.io/github/actions/workflow/status/vihu/tandem.nvim/rust.yml)
![GitHub Release](https://img.shields.io/github/v/release/vihu/tandem.nvim)

Real-time collaborative editing for Neovim. No server required.

## Features

- **P2P connections**: Direct peer-to-peer via [Iroh](https://iroh.computer/) - no relay server needed
- **E2E encrypted**: Automatic end-to-end encryption via QUIC/TLS 1.3
- **CRDT-based**: Conflict-free resolution using [Loro](https://github.com/loro-dev/loro) CRDT
- **Simple sharing**: Host a session, share the code, collaborate
- **Statusline integration**: Works with lualine and other statusline plugins

## Requirements

- Neovim 0.11+
- curl (for downloading pre-compiled binaries)
- Rust toolchain (only if building from source)

## Installation

### lazy.nvim (recommended)

Pre-compiled binaries are automatically downloaded for Linux and macOS (x86_64 and aarch64):

```lua
{
  "vihu/tandem.nvim",
  build = function()
    require("tandem.build").install()
  end,
  config = function()
    require("tandem").setup({
      user_name = "your-name",
    })
  end,
}
```

### packer.nvim

```lua
use {
  "vihu/tandem.nvim",
  run = function()
    require("tandem.build").install()
  end,
  config = function()
    require("tandem").setup({
      user_name = "your-name",
    })
  end,
}
```

### vim-plug

```vim
Plug 'vihu/tandem.nvim', { 'do': ':lua require("tandem.build").install()' }

" In your init.vim or after/plugin:
lua require("tandem").setup({ user_name = "your-name" })
```

### Building from source

```lua
-- lazy.nvim
{
  "vihu/tandem.nvim",
  build = "make build",  -- Requires Rust toolchain
  -- ...
}
```

Build dependencies:

- Rust toolchain (stable)
- libluajit (`libluajit-5.1-dev` on Debian/Ubuntu)
- libclang-dev
- pkg-config

## Usage

### Hosting a Session

```vim
:TandemHost
```

This will:

1. Start a P2P endpoint
2. Generate a shareable session code
3. Copy the code to your clipboard

Share the code with collaborators.

### Joining a Session

```vim
:TandemJoin <session-code>
```

The connection is direct and encrypted - no data passes through any server.

### Commands

| Command              | Description                     |
| -------------------- | ------------------------------- |
| `:TandemHost`        | Host a new session              |
| `:TandemJoin <code>` | Join a session using a code     |
| `:TandemLeave`       | Leave the current session       |
| `:TandemCode`        | Copy current session code       |
| `:TandemInfo`        | Show basic session info         |
| `:TandemStatus`      | Show detailed connection status |

## Configuration

```lua
require("tandem").setup({
  -- Display name shown to other users
  user_name = "nvim-user",

  -- Polling interval for sync updates (ms)
  poll_interval_ms = 50,

  -- Debug logging
  debug = false,
})
```

## Statusline Integration

### lualine

```lua
require("lualine").setup({
  sections = {
    lualine_x = {
      { require("tandem").statusline },
    },
  },
})
```

### Manual statusline

```lua
vim.o.statusline = "%{%v:lua.require('tandem').statusline()%}"
```

Status indicators:

- `[Tandem P2P: synced[E2E]]` - Connected with encryption
- `[Tandem P2P: connecting...]` - Establishing connection
- Empty when not in a session

## Health Check

```vim
:checkhealth tandem
```

## Troubleshooting

### "Failed to load tandem_ffi" error

```lua
-- Re-run the installer
:lua require("tandem.build").install()

-- Or force a fresh download
:lua require("tandem.build").install({ force = true })
```

### Build fails with "libluajit not found"

```bash
# Debian/Ubuntu
sudo apt install libluajit-5.1-dev

# Arch
sudo pacman -S luajit

# macOS
brew install luajit
```

### Sync issues

Enable debug logging:

```lua
require("tandem").setup({ debug = true })
```

Check `/tmp/tandem-nvim.log` for detailed logs.

## Architecture

```
+---------------------------------------------------------------+
|  Lua Layer (lua/tandem/)                                      |
|  - init.lua:     Plugin entry, commands, setup()              |
|  - session.lua:  P2P session lifecycle                        |
|  - buffer.lua:   Buffer <-> CRDT synchronization              |
|  - build.lua:    Auto-download pre-built binaries             |
|  - health.lua:   :checkhealth integration                     |
+---------------------------------------------------------------+
|  Rust FFI (src/)                                              |
|  - lib.rs:         nvim-oxi entry, module exports             |
|  - iroh_client.rs: P2P networking (QUIC/TLS 1.3)              |
|  - crdt.rs:        Loro LoroDoc/LoroText wrapper              |
+---------------------------------------------------------------+
```

## License

MIT

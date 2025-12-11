# tandem.nvim

![GitHub Actions Workflow Status](https://img.shields.io/github/actions/workflow/status/vihu/tandem.nvim/rust.yml)
![GitHub Release](https://img.shields.io/github/v/release/vihu/tandem.nvim)

Real-time collaborative editing for Neovim using [Loro](https://github.com/loro-dev/loro) CRDT-based document synchronization.

## Features

- **Real-time sync**: Edits sync between clients within 50ms
- **CRDT-based**: Conflict-free resolution using Loro CRDT
- **Simple sharing**: Host a session, share the code, collaborate
- **Automatic reconnection**: Exponential backoff with configurable retries
- **Cursor awareness**: See other users' cursor positions
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

If pre-compiled binaries are unavailable for your platform, or you prefer to build from source:

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

Start a collaborative session on the current buffer:

```vim
:TandemHost
```

This will:

1. Connect to the relay server
2. Generate a shareable session code
3. Copy the code to your clipboard

Share the code with collaborators!

### Joining a Session

Join using a session code from someone else:

```vim
:TandemJoin <session-code>
```

### Commands

| Command              | Description                     |
| -------------------- | ------------------------------- |
| `:TandemHost [name]` | Host a new session              |
| `:TandemJoin <code>` | Join a session using a code     |
| `:TandemLeave`       | Leave the current session       |
| `:TandemCode`        | Copy current session code       |
| `:TandemInfo`        | Show basic session info         |
| `:TandemStatus`      | Show detailed connection status |

### Leaving a Session

```vim
:TandemLeave
```

## Configuration

```lua
require("tandem").setup({
  -- Display name shown to other users
  user_name = "nvim-user",

  -- Default relay server
  default_server = "ws://127.0.0.1:8080",

  -- Polling interval for sync updates (ms)
  poll_interval_ms = 50,

  -- Reconnection settings
  reconnect_max_retries = 10,      -- Max reconnection attempts
  reconnect_base_delay_ms = 1000,  -- Initial delay (1 second)
  reconnect_max_delay_ms = 30000,  -- Maximum delay (30 seconds)

  -- Connection timeout (ms)
  connection_timeout_ms = 10000,   -- 10 seconds

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

- `[Tandem: synced]` - Connected and syncing
- `[Tandem: connected]` - Connected, waiting for sync
- `[Tandem: connecting...]` - Establishing connection
- `[Tandem: reconnecting N/M]` - Reconnecting (attempt N of M)
- Empty when not in a session

## Running a Relay Server

The plugin includes a relay server binary:

```bash
# If installed via pre-built binaries, find it in the bin/ directory
./bin/tandem-server

# Or build and run from source
make server
```

This starts a WebSocket relay at `ws://127.0.0.1:8080` that:

- Accepts connections at `/ws/{room-id}`
- Maintains server-side CRDT for late joiners
- Broadcasts updates to all peers in the same room

### Server Configuration

Configure via environment variables:

| Variable              | Default          | Description              |
| --------------------- | ---------------- | ------------------------ |
| `TANDEM_BIND_ADDR`    | `127.0.0.1:8080` | Server bind address      |
| `TANDEM_MAX_PEERS`    | `8`              | Max peers per room       |
| `TANDEM_MAX_ROOMS`    | `1000000`        | Max total rooms          |
| `TANDEM_MAX_DOC_SIZE` | `10485760`       | Max document size (10MB) |

## Health Check

Verify your installation:

```vim
:checkhealth tandem
```

This checks:

- Neovim version compatibility
- FFI library loading
- Required dependencies

## Troubleshooting

### "Failed to load tandem_ffi" error

The FFI library wasn't found. Try:

```lua
-- Re-run the installer
:lua require("tandem.build").install()

-- Or force a fresh download
:lua require("tandem.build").install({ force = true })
```

### Build fails with "libluajit not found"

Install LuaJIT development headers:

```bash
# Debian/Ubuntu
sudo apt install libluajit-5.1-dev

# Arch
sudo pacman -S luajit

# macOS
brew install luajit
```

### Connection timeout

- Verify the relay server is running
- Check firewall settings
- Try `:TandemStatus` for detailed connection info

### Sync issues

Enable debug logging:

```lua
require("tandem").setup({ debug = true })
```

Check `/tmp/tandem-nvim.log` for detailed Rust-side logs.

## Architecture

```
+-----------------------------------------------------------+
|  Lua Layer (lua/tandem/)                                  |
|  - init.lua:     Plugin entry, commands                   |
|  - session.lua:  Connection lifecycle, sync loop          |
|  - buffer.lua:   Buffer <-> CRDT bridge                   |
|  - build.lua:    Auto-download pre-built binaries         |
|  - health.lua:   :checkhealth integration                 |
+-----------------------------------------------------------+
|  Rust FFI (rust/tandem-ffi/)                              |
|  - lib.rs:  nvim-oxi entry, FFI exports                   |
|  - ws.rs:   Async WebSocket client (tokio-tungstenite)    |
|  - crdt.rs: Loro LoroText wrapper                         |
+-----------------------------------------------------------+
|  tandem-server: WebSocket relay with server-side CRDT     |
+-----------------------------------------------------------+
```

## License

MIT

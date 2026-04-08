# hello_tty

**A GPU-accelerated terminal emulator built in MoonBit**

hello_tty is a terminal emulator that leverages MoonBit's native backend and wgpu (WebGPU) for GPU-accelerated text rendering, delivering fast and smooth terminal output.

- **GPU-accelerated rendering** — Uses wgpu-native to draw via Metal / Vulkan / DX12, with a glyph atlas for efficient text rendering
- **VT100 compatible** — Comprehensive parsing and handling of CSI / ESC / OSC sequences, supporting 256-color palette, 24-bit True Color, and CJK / emoji wide characters
- **Tabs and split panes** — Manage multiple sessions simultaneously with horizontal and vertical pane splitting and tab switching

By combining MoonBit's type safety with C FFI, the core terminal emulation logic is written safely while platform-specific rendering and input handling are integrated efficiently.


## Architecture Overview

hello_tty is a multi-process, single-threaded terminal emulator. To work within MoonBit's single-threaded constraint and ensure fork safety with the garbage collector, the main process and the PTY reader subprocess communicate over a Unix socket IPC.

### Process Architecture

```
Main Process (MoonBit)                 PTY Reader (MoonBit)
├─ Platform (window, input)            ├─ Fork shell via PTY
├─ VT100 parser + terminal state       ├─ Poll PTY output (non-blocking)
├─ GPU rendering pipeline              └─ Forward to main via IPC
├─ Layout manager (tabs, panes)
└─ Event loop
        ↕ IPC (Unix socket)
```

The PTY read operation is isolated in a separate subprocess. This prevents blocking I/O from freezing the event loop and avoids corrupting the MoonBit GC in forked child processes.

### Core Components

| Component | Package | Role |
|---|---|---|
| **Terminal** | `src/terminal/` | VT100 emulation: grid with scrollback, cursor, screen modes |
| **VT Parser** | `src/vt_parser/` | State-machine-based escape sequence parser |
| **Renderer** | `src/renderer/` | Generates render commands (CellQuad / CursorQuad) from terminal state |
| **GPU Backend** | `src/renderer/ffi/` | Executes drawing via wgpu-native; manages device, pipelines, and atlas |
| **Font** | `src/font/` | Glyph rasterization and texture atlas; CoreText on macOS, FreeType2 on Linux |
| **PTY** | `src/pty/` | Pseudo-terminal creation, fork, and I/O |
| **Input** | `src/input/` | Key classification (IME / PTY / UI action) and escape sequence translation |
| **Platform** | `src/platform/` | Window management, event polling, clipboard abstraction |
| **Layout** | `src/layout/` | Tab and pane split tree (horizontal / vertical splits) |
| **Session** | `src/session/` | Lifecycle management for multiple terminal sessions |
| **Bridge** | `src/bridge/` | FFI export functions for platform adapters |
| **Theme** | `src/theme/` | Color theme definitions and 256-color palette |

### Rendering Pipeline

1. **Terminal state** — Generates a `RenderCommand` array from each cell in the grid and the cursor position
2. **Color resolution** — Resolves terminal `Color` (Default / Indexed / Palette / RGB) to `RgbaColor` using the theme
3. **Quad construction** — Builds vertex data (position, UV, foreground color, background color) for each cell
4. **GPU drawing** — Encodes into a wgpu command buffer and presents to the swapchain

Rasterized glyphs are cached in a texture atlas (initial size 1024×1024). During drawing, glyphs are sampled from the atlas, minimizing font rendering overhead.

### Multi-Surface Design

Each pane has its own independent surface (swapchain), while the GPU device, render pipelines, font engine, and glyph atlas are shared globally. This avoids duplicating GPU resources when adding panes.

### FFI Boundary

The boundary between MoonBit and C/Swift is consolidated in `src/bridge/`. The bridge layer exports all colors as fully resolved RGBA values, so platform adapters do not need to understand the terminal's color system.

```
MoonBit (type-safe domain)
  ↓ ffi_* functions (src/bridge/)
C stubs (src/bridge/c_stub/)
  ↓ dylib export
Platform adapter (Swift / etc.)
```


## Quick Start

### Prerequisites

- [MoonBit](https://www.moonbitlang.com/) toolchain (`moon` command)
- C compiler (clang / gcc)
- macOS: Xcode Command Line Tools, Swift 5.9+

### Build and Run

```bash
# Clone the repository
git clone https://github.com/trkbt10/hello_tty.git
cd hello_tty

# Type check
make check

# Run tests
make test

# Native build (headless / interactive mode)
make
```

### Run Modes

#### Interactive Mode

Launches a shell via PTY and operates as a terminal. Press Ctrl+D to exit.

```bash
make debug-interactive
```

#### macOS GUI Mode

Builds and launches as a SwiftUI-based GUI application.

```bash
# Build dylib + Swift app together
make swift

# Run as macOS app
make debug-macos
```

A GPU-accelerated terminal window will open, running the default shell (`$SHELL` environment variable, falling back to `/bin/sh`).

### Verification

```bash
# Headless VT parser test
make debug-headless

# PTY reader standalone test
make debug-pty

# Bridge FFI test
make debug-bridge
```


## Usage

### Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| `Cmd+T` | Open a new tab |
| `Cmd+W` | Close current tab / pane |
| `Cmd+D` | Split pane vertically |
| `Cmd+Shift+D` | Split pane horizontally |
| `Cmd+[` / `Cmd+]` | Switch tabs |
| `Cmd+←` / `Cmd+→` | Move focus between panes |
| `Cmd+C` | Copy text |
| `Cmd+V` | Paste text |
| `Cmd+A` | Select all |
| `Cmd+F` | Search |

### Terminal Capabilities

#### Supported Escape Sequences

- **CSI (Control Sequence Introducer)**: Cursor movement, text attributes, color setting, screen/line erase
- **ESC sequences**: RIS (reset), DECSC / DECRC (save/restore cursor)
- **OSC (Operating System Command)**: Window title setting

#### Color Support

- ANSI 16 colors (standard + bright)
- 256-color palette (6×6×6 color cube + 24-step grayscale)
- 24-bit True Color (RGB)
- Theme-based ANSI color customization

#### Terminal Modes

- DECCKM (cursor key application mode)
- DECAWM (auto-wrap)
- DECTCEM (cursor show/hide)
- DECOM (origin mode)
- Bracketed paste
- Focus tracking
- Mouse tracking

### Themes

Built-in themes are available:

- `midnight` (default) — Dark theme
- `solarized` — Solarized color scheme

A theme defines foreground, background, cursor, and selection colors, along with ANSI 16 color overrides and background opacity.

### Default Configuration

| Setting | Value |
|---|---|
| Grid size | 24 rows × 80 columns |
| Shell | `$SHELL` (falls back to `/bin/sh`) |
| Scrollback | Up to 10,000 lines |
| Cell size | 8 × 16 px |
| Font size | 14pt |
| Atlas size | 1024 × 1024 px |
| TERM variable | `xterm-256color` |


## Installation

### System Requirements

| Item | Requirement |
|---|---|
| OS | macOS (Metal), Linux (Vulkan) |
| MoonBit | Latest toolchain |
| C compiler | clang or gcc |
| GPU | Driver supported by wgpu-native (Metal / Vulkan / DX12) |

For macOS, the following are also required:

- Xcode Command Line Tools
- Swift 5.9+ (for macOS GUI mode)

### Building from Source

```bash
# Clone the repository
git clone https://github.com/trkbt10/hello_tty.git
cd hello_tty

# Install MoonBit dependencies
moon install

# Native build
make
```

### Building the macOS Application

For macOS GUI mode, the MoonBit core is built as a dylib and integrated with the Swift adapter.

```bash
# Build dylib (libhello_tty.dylib)
make dylib

# Build Swift app + dylib together
make swift
```

Build artifacts:

```
_build/native/debug/build/
├── cmd/main/main.exe              # Headless execution
├── cmd/pty_reader/pty_reader.exe  # PTY reader subprocess
├── cmd/interactive/interactive.exe # Interactive mode
└── cmd/bridge_lib/bridge_lib.exe  # FFI export

adapters/macos/build/
└── libhello_tty.dylib             # macOS dylib
```

### Verifying the Build

```bash
# Type check
make check

# Run tests
make test

# Headless test (VT parser)
make debug-headless
```

### Dependencies

#### MoonBit Packages

| Package | Version | Purpose |
|---|---|---|
| `moonbitlang/async` | 0.16.8 | Async operations |
| `moonbitlang/x` | 0.4.41 | System utilities |
| `trkbt10/subprocess` | 0.2.0 | IPC sockets, process spawning |
| `trkbt10/osenv` | 0.1.0 | Environment variables |
| `mizchi/font` | 0.7.0 | Font abstractions |

#### Native Libraries

| Library | Purpose |
|---|---|
| wgpu-native | GPU rendering (vendored) |
| libutil | PTY support (Unix) |
| CoreText | Font rasterization (macOS) |
| FreeType2 | Font rasterization (Linux) |
| Metal / QuartzCore | GPU backend (macOS) |


## License

Apache-2.0 - see [LICENSE](LICENSE) for details.

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

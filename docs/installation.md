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

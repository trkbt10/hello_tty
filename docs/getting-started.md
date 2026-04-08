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

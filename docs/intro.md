# hello_tty

**A GPU-accelerated terminal emulator built in MoonBit**

hello_tty is a terminal emulator that leverages MoonBit's native backend and wgpu (WebGPU) for GPU-accelerated text rendering, delivering fast and smooth terminal output.

- **GPU-accelerated rendering** — Uses wgpu-native to draw via Metal / Vulkan / DX12, with a glyph atlas for efficient text rendering
- **VT100 compatible** — Comprehensive parsing and handling of CSI / ESC / OSC sequences, supporting 256-color palette, 24-bit True Color, and CJK / emoji wide characters
- **Tabs and split panes** — Manage multiple sessions simultaneously with horizontal and vertical pane splitting and tab switching

By combining MoonBit's type safety with C FFI, the core terminal emulation logic is written safely while platform-specific rendering and input handling are integrated efficiently.

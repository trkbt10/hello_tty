# hello_tty — MoonBit Terminal Emulator
#
# Root Makefile: unified build, debug, and test entry points for all environments
#
# Targets:
#   make                  MoonBit native build (headless CLI)
#   make check            Type check only (fast)
#   make test             Run moon test
#
#   make debug-headless   Debug in headless mode (terminal core verification)
#   make debug-macos      Debug macOS SwiftUI app
#   make debug-pty        PTY reader standalone debug (no endpoint)
#   make debug-bridge     Bridge library standalone test
#
#   make dylib            Build libhello_tty.dylib (for macOS adapter)
#   make swift            Build dylib + Swift app
#   make names            Print MoonBit mangled export names
#
#   make clean            Remove all build artifacts
#   make clean-moon       Remove MoonBit build cache only
#   make clean-swift      Remove Swift build artifacts + dylib only
#
#   make info             Show project info and build status

# ============================================================
# Variables
# ============================================================

BUILD_DIR     := _build/native/debug/build
MAIN_EXE      := $(BUILD_DIR)/cmd/main/main.exe
PTY_READER    := $(BUILD_DIR)/cmd/pty_reader/pty_reader.exe
BRIDGE_LIB    := $(BUILD_DIR)/cmd/bridge_lib/bridge_lib.exe
BRIDGE_C      := $(BUILD_DIR)/cmd/bridge_lib/bridge_lib.c
INTERACTIVE   := $(BUILD_DIR)/cmd/interactive/interactive.exe

MACOS_ADAPTER := adapters/macos
DYLIB_DIR     := $(MACOS_ADAPTER)/build
DYLIB         := $(DYLIB_DIR)/libhello_tty.dylib

# MoonBit SDK
MOON_INCLUDE  := $(HOME)/.moon/include
MOON_RUNLIB   := $(HOME)/.moon/lib/libmoonbitrun.o
MOON_RUNTIME  := $(BUILD_DIR)/runtime.o
MOON_BT       := $(HOME)/.moon/lib/libbacktrace.a

# C stubs
C_STUB_DIR    := src/bridge/c_stub
C_STUB_SRC    := $(C_STUB_DIR)/hello_tty_stub.c

# wgpu-native
WGPU_DIR      := vendor/wgpu-native
WGPU_INCLUDE  := $(WGPU_DIR)/include
WGPU_LIB      := $(WGPU_DIR)/lib/libwgpu_native.a

# GPU renderer C stubs
GPU_STUB_DIR  := src/renderer/ffi/c_stub

CC            := clang
CFLAGS        := -I$(MOON_INCLUDE) -I$(C_STUB_DIR) -I$(WGPU_INCLUDE) -I$(WGPU_INCLUDE)/webgpu -I$(WGPU_INCLUDE)/wgpu -I$(GPU_STUB_DIR) \
                 -fPIC -g -O2 -fwrapv -fno-strict-aliasing -Wno-unused-value
DYLIB_FLAGS   := -dynamiclib -install_name @rpath/libhello_tty.dylib

.PHONY: all check test build \
        debug-headless debug-macos debug-pty debug-bridge debug-interactive \
        self-test-macos \
        vendor-wgpu dylib swift names \
        clean clean-moon clean-swift \
        info

# ============================================================
# Basic build
# ============================================================

all: build

## Type check only (no compilation, fastest)
check:
	moon check --target native

## Full native build
build:
	moon build --target native

## Run tests
test:
	moon test --target native

# ============================================================
# Debug runs
# ============================================================

## Headless mode: validate VT parser + terminal core behavior
## Skips platform initialization and processes sample escape sequences
debug-headless: build
	@echo "=== debug-headless: headless mode ==="
	$(MAIN_EXE)

## macOS SwiftUI app: MoonBit core + CoreText rendering via dylib
## Opens a window and displays the terminal view
debug-macos: dylib swift
	@echo "=== debug-macos: SwiftUI app ==="
	cd $(MACOS_ADAPTER) && DYLD_LIBRARY_PATH=build swift run HelloTTY

## macOS SwiftUI app: automated UI tests
## Opens a window, runs automated tests, saves screenshots to /tmp/, prints results, then exits
self-test-macos: dylib swift
	@echo "=== self-test-macos: automated UI tests ==="
	cd $(MACOS_ADAPTER) && DYLD_LIBRARY_PATH=build swift run HelloTTY -- --self-test

## PTY reader only: start without endpoint and verify normal exit
## When arguments are provided, it connects to an IPC socket and forks a shell
debug-pty: build
	@echo "=== debug-pty: PTY reader (no endpoint) ==="
	$(PTY_READER)

## PTY reader + real shell: connection test with a local IPC server
## Starts a real shell with an explicit socket path
debug-pty-shell: build
	@echo "=== debug-pty-shell: PTY reader + shell ==="
	@SOCK="/tmp/hello_tty_debug_$$$$.sock"; \
	echo "Socket: $$SOCK"; \
	echo "NOTE: No server side is running, so connection will fail and exit"; \
	$(PTY_READER) "$$SOCK" /bin/zsh 24 80 || true

## Bridge library: integration test for FFI exports
## Verifies init -> get_grid -> shutdown flow of the MoonBit terminal core
debug-bridge: build
	@echo "=== debug-bridge: bridge FFI test ==="
	$(BRIDGE_LIB)

## Interactive shell: direct PTY fork/exec with raw-mode interaction
## Operates a real shell through VT parser + terminal state
## Exit with Ctrl+D
debug-interactive: build
	@echo "=== debug-interactive: interactive shell (exit with Ctrl+D) ==="
	$(INTERACTIVE)

# ============================================================
# macOS adapter (dylib + Swift)
# ============================================================

## Download wgpu-native if missing
vendor-wgpu:
	@if [ ! -f "$(WGPU_LIB)" ]; then \
		echo "=== Downloading wgpu-native ===" && \
		$(WGPU_DIR)/fetch.sh; \
	fi

## Build libhello_tty.dylib (bundles wgpu-native)
dylib: build vendor-wgpu
	@mkdir -p $(DYLIB_DIR)
	@echo "=== dylib: libhello_tty.dylib ==="
	@if [ ! -f "$(BRIDGE_C)" ]; then \
		echo "Error: $(BRIDGE_C) not found"; \
		exit 1; \
	fi
	$(CC) $(CFLAGS) -DHELLO_TTY_PLATFORM_MACOS $(DYLIB_FLAGS) \
		-o $(DYLIB) \
		$(BRIDGE_C) \
		$(C_STUB_SRC) \
		$(C_STUB_DIR)/hello_tty_pty.c \
		$(GPU_STUB_DIR)/gpu_wgpu.c \
		$(GPU_STUB_DIR)/gpu_moonbit_glue.c \
		$(GPU_STUB_DIR)/font_coretext.c \
		$(WGPU_LIB) \
		$(MOON_RUNLIB) \
		$(MOON_RUNTIME) \
		$(MOON_BT) \
		-lpthread \
		-framework CoreFoundation \
		-framework CoreText \
		-framework Metal \
		-framework QuartzCore \
		-framework CoreGraphics \
		-lutil
	@echo "=== Built $(DYLIB) ==="

## Build Swift app (depends on dylib)
swift: dylib
	cd $(MACOS_ADAPTER) && swift build

## Print mangled MoonBit export names (for C stub development)
names: build
	@echo "=== mangled FFI export names ==="
	@if [ -f "$(BRIDGE_C)" ]; then \
		grep -oE '_M0FP[0-9A-Za-z_]*ffi[_a-z]*[A-Za-z_]*' "$(BRIDGE_C)" | sort -u; \
	else \
		echo "$(BRIDGE_C) not found"; \
	fi

# ============================================================
# Cleanup
# ============================================================

## Remove all build outputs
clean: clean-moon clean-swift

## Remove MoonBit build cache
clean-moon:
	moon clean

## Remove Swift build outputs and dylib
clean-swift:
	rm -rf $(DYLIB_DIR)
	cd $(MACOS_ADAPTER) && swift package clean 2>/dev/null || true

# ============================================================
# Info
# ============================================================

## Show project/build status
info:
	@echo "hello_tty — MoonBit Terminal Emulator"
	@echo ""
	@echo "MoonBit: $$(moon version 2>&1 | head -1)"
	@echo "Swift:   $$(swift --version 2>&1 | head -1)"
	@echo "CC:      $$($(CC) --version 2>&1 | head -1)"
	@echo ""
	@echo "Build artifacts:"
	@[ -f "$(MAIN_EXE)" ]      && echo "  ✓ $(MAIN_EXE)"      || echo "  ✗ main.exe (not built)"
	@[ -f "$(PTY_READER)" ]    && echo "  ✓ $(PTY_READER)"    || echo "  ✗ pty_reader.exe (not built)"
	@[ -f "$(BRIDGE_LIB)" ]    && echo "  ✓ $(BRIDGE_LIB)"    || echo "  ✗ bridge_lib.exe (not built)"
	@[ -f "$(INTERACTIVE)" ]   && echo "  ✓ $(INTERACTIVE)"   || echo "  ✗ interactive.exe (not built)"
	@[ -f "$(DYLIB)" ]         && echo "  ✓ $(DYLIB)"         || echo "  ✗ libhello_tty.dylib (not built)"
	@echo ""
	@echo "Commands:"
	@echo "  make check          Type check"
	@echo "  make debug-headless Run in headless mode"
	@echo "  make debug-macos    Run macOS SwiftUI app"
	@echo "  make debug-pty      Run PTY reader only"
	@echo "  make debug-bridge   Run bridge FFI test"
	@echo "  make debug-interactive Run interactive shell"
	@echo "  make clean          Remove all outputs"

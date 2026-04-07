# adapters/macos — macOS SwiftUI adapter
#
# Usually invoked from the project root Makefile:
#   make dylib        -> libhello_tty.dylib
#   make swift        -> dylib + Swift app
#   make debug-macos  -> build + run
#
# If you use this Makefile directly:
#   make              -> dylib
#   make swift        -> dylib + Swift app
#   make run          -> build + run
#   make clean        -> remove build artifacts

.PHONY: all swift run clean

all:
	$(MAKE) -C ../.. dylib

swift: all
	swift build

run: swift
	DYLD_LIBRARY_PATH=build swift run HelloTTY

clean:
	rm -rf build
	swift package clean 2>/dev/null || true

# adapters/macos — macOS SwiftUIアダプタ
#
# 通常はプロジェクトルートのMakefileから呼ばれます:
#   make dylib        → libhello_tty.dylib
#   make swift        → dylib + Swift app
#   make debug-macos  → ビルド + 実行
#
# このMakefileを直接使う場合:
#   make              → dylib
#   make swift        → dylib + Swift app
#   make run          → ビルド + 実行
#   make clean        → ビルド成果物削除

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

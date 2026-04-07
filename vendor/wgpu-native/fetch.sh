#!/bin/bash
# Download prebuilt wgpu-native for the current platform.
# Usage: ./fetch.sh
#
# Extracts libwgpu_native.a + headers into this directory.
# The static lib is gitignored; headers are committed for build reproducibility.

set -euo pipefail

WGPU_VERSION="22.1.0.5"
BASE_URL="https://github.com/gfx-rs/wgpu-native/releases/download/v${WGPU_VERSION}"

cd "$(dirname "$0")"

# Detect platform
ARCH=$(uname -m)
OS=$(uname -s)

case "${OS}-${ARCH}" in
    Darwin-arm64)  ARCHIVE="wgpu-macos-aarch64-release.zip" ;;
    Darwin-x86_64) ARCHIVE="wgpu-macos-x86_64-release.zip" ;;
    Linux-x86_64)  ARCHIVE="wgpu-linux-x86_64-release.zip" ;;
    Linux-aarch64) ARCHIVE="wgpu-linux-aarch64-release.zip" ;;
    *)
        echo "Unsupported platform: ${OS}-${ARCH}"
        exit 1
        ;;
esac

URL="${BASE_URL}/${ARCHIVE}"

if [ -f "lib/libwgpu_native.a" ]; then
    echo "wgpu-native already present (lib/libwgpu_native.a)"
    exit 0
fi

echo "Downloading wgpu-native ${WGPU_VERSION} for ${OS}-${ARCH}..."
echo "  URL: ${URL}"

TMPDIR=$(mktemp -d)
trap "rm -rf ${TMPDIR}" EXIT

curl -L -o "${TMPDIR}/${ARCHIVE}" "${URL}"
unzip -q "${TMPDIR}/${ARCHIVE}" -d "${TMPDIR}/wgpu"

# The zip contains include/webgpu/webgpu.h and include/wgpu/wgpu.h
mkdir -p lib include/webgpu include/wgpu
cp "${TMPDIR}"/wgpu/lib/libwgpu_native.a lib/
cp "${TMPDIR}"/wgpu/include/webgpu/*.h include/webgpu/
cp "${TMPDIR}"/wgpu/include/wgpu/*.h include/wgpu/

echo "Done. Files:"
ls -la lib/ include/

#!/bin/sh
# Copyright 2026 Sig Demo contributors
# SPDX-License-Identifier: AGPL-3.0-only
set -eu

PACKAGE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
WORKSPACE_DIR=$(CDPATH= cd -- "$PACKAGE_DIR/../../.." && pwd)
PROBE_DIR="$WORKSPACE_DIR/.sig-demo/ios/mesh-public-probe"
BUILD_DIR="$PROBE_DIR/swift-build"
export CLANG_MODULE_CACHE_PATH="$PROBE_DIR/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"

python3 "$PACKAGE_DIR/prepare.py"
swift build --disable-sandbox --package-path "$PACKAGE_DIR" --scratch-path "$BUILD_DIR"
BIN_DIR=$(swift build --disable-sandbox --show-bin-path --package-path "$PACKAGE_DIR" --scratch-path "$BUILD_DIR")
xcrun swiftc -swift-version 6 -parse-as-library \
  -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
  -I "$BIN_DIR/Modules" \
  -F "$PROBE_DIR/artifact/MeshLLMFFI.xcframework/macos-arm64" \
  "$PACKAGE_DIR/Smoke/PublicSmoke.swift" \
  "$BIN_DIR"/MeshLLM.build/*.o "$BIN_DIR"/SigDemoMesh.build/*.o \
  -framework MeshLLMFFI -framework Foundation -framework Security \
  -framework SystemConfiguration -framework Network -framework Metal \
  -framework Accelerate -framework CoreGraphics -framework MetalKit \
  -framework AppKit -framework IOKit -lc++ -lresolv \
  -Xlinker -dead_strip -o "$PROBE_DIR/public-smoke"
exec "$PROBE_DIR/public-smoke" "$@"

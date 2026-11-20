#!/bin/bash
# Copyright 2026 sig demo contributors
# SPDX-License-Identifier: AGPL-3.0-only
set -euo pipefail

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../../.." && pwd)
SOURCE=${SIG_DEMO_LIBSIGNAL_SOURCE:-"$ROOT/.sig-demo/ios/libsignal"}
BUILD_DIR=${SIG_DEMO_LIBSIGNAL_BUILD_DIR:-"$ROOT/.sig-demo/ios/libsignal-build"}
TOOLCHAIN=${SIG_DEMO_LIBSIGNAL_TOOLCHAIN:-1.95.0}
TARGET=${1:-aarch64-apple-ios-sim}
PROFILE=${2:-release}

case "$TARGET" in
  aarch64-apple-ios|aarch64-apple-ios-sim|aarch64-apple-darwin) ;;
  *) echo 'Use an arm64 iOS device, simulator, or macOS smoke-test target.' >&2; exit 2 ;;
esac
case "$PROFILE" in release|debug) ;; *) echo 'Use release or debug profile.' >&2; exit 2 ;; esac

python3 "$HERE/prepare.py" --source "$SOURCE" --check
if ! command -v protoc >/dev/null; then
  PROTOC_CACHED_BIN=$(python3 - <<'PY'
import os
from pathlib import Path
root=Path(os.environ.get('CARGO_HOME', str(Path.home()/'.cargo')))/'registry/src'
paths=sorted(root.glob('*/protoc-bin-vendored-macos-aarch_64-*/bin/protoc'))
print(paths[-1].parent if paths else '')
PY
)
  if [[ -z "$PROTOC_CACHED_BIN" ]]; then
    echo 'Install protoc or add the cached vendored protoc bin directory to PATH.' >&2
    exit 1
  fi
  export PATH="$PROTOC_CACHED_BIN:$PATH"
fi
export PROTOC=$(command -v protoc)
export RUSTUP_TOOLCHAIN="$TOOLCHAIN"
export CARGO_TARGET_DIR="$BUILD_DIR"
export CARGO_BUILD_JOBS=${CARGO_BUILD_JOBS:-6}
export RUSTFLAGS="--cfg aes_armv8 --cfg tokio_unstable ${RUSTFLAGS:-}"
export IPHONEOS_DEPLOYMENT_TARGET=16.0
if [[ "$TARGET" == aarch64-apple-ios* ]]; then
  export CMAKE_TOOLCHAIN_FILE="$HERE/apple-minimum.cmake"
fi
# Keep debug-level logging out of app libraries. This first application build
# favors iteration speed; production-size/LTO qualification is a separate build.
export CARGO_PROFILE_RELEASE_OPT_LEVEL=${CARGO_PROFILE_RELEASE_OPT_LEVEL:-1}
export CARGO_PROFILE_RELEASE_LTO=${CARGO_PROFILE_RELEASE_LTO:-false}
export CARGO_PROFILE_RELEASE_DEBUG=${CARGO_PROFILE_RELEASE_DEBUG:-1}
export CARGO_PROFILE_RELEASE_CODEGEN_UNITS=${CARGO_PROFILE_RELEASE_CODEGEN_UNITS:-16}
export CARGO_PROFILE_DEV_DEBUG=1
FEATURES=log/max_level_info,log/release_max_level_info
if [[ "$TARGET" != aarch64-apple-ios ]]; then FEATURES="$FEATURES,libsignal-bridge-testing"; fi
ARGS=(build --locked --offline -p libsignal-ffi --target "$TARGET" --features "$FEATURES")
if [[ "$PROFILE" == release ]]; then ARGS+=(--release); fi
cd "$SOURCE"
cargo "+$TOOLCHAIN" "${ARGS[@]}"
LIBRARY="$BUILD_DIR/$TARGET/$PROFILE/libsignal_ffi.a"
test -s "$LIBRARY"
case "$TARGET" in
  aarch64-apple-ios) PLATFORM=ios ;;
  aarch64-apple-ios-sim) PLATFORM=ios-simulator ;;
  aarch64-apple-darwin) PLATFORM=macos ;;
esac
if python3 "$HERE/verify-library.py" "$LIBRARY" --platform "$PLATFORM"; then
  :
else
  VERIFY_STATUS=$?
  if [[ "$VERIFY_STATUS" != 2 || "$TARGET" != aarch64-apple-ios* ]]; then
    exit "$VERIFY_STATUS"
  fi
  # Existing BoringSSL CMake outputs may predate the minimum-version toolchain.
  # Invalidate one dependency/target in this dedicated build directory only.
  cargo "+$TOOLCHAIN" clean --offline -p boring-sys --target "$TARGET"
  cargo "+$TOOLCHAIN" "${ARGS[@]}"
  python3 "$HERE/verify-library.py" "$LIBRARY" --platform "$PLATFORM"
fi
printf '%s\n' "$LIBRARY"

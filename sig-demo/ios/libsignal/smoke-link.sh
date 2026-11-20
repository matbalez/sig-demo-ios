#!/bin/bash
# Link the public C ABI without credentials, wallet state, or a network connection.
set -euo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../../.." && pwd)
SOURCE=${SIG_DEMO_LIBSIGNAL_SOURCE:-"$ROOT/.sig-demo/ios/libsignal"}
BUILD_DIR=${SIG_DEMO_LIBSIGNAL_BUILD_DIR:-"$ROOT/.sig-demo/ios/libsignal-build"}
LIBRARY=${1:-"$BUILD_DIR/aarch64-apple-ios-sim/debug/libsignal_ffi.a"}
TARGET=${2:-aarch64-apple-ios-sim}
case "$TARGET" in
  aarch64-apple-ios-sim) SDK=iphonesimulator; CLANG_TARGET=arm64-apple-ios16.0-simulator; SUFFIX=sim ;;
  aarch64-apple-ios) SDK=iphoneos; CLANG_TARGET=arm64-apple-ios16.0; SUFFIX=device ;;
  *) echo 'Use an arm64 iOS device or simulator target.' >&2; exit 2 ;;
esac
OUTPUT=${SIG_DEMO_LIBSIGNAL_SMOKE_OUTPUT:-"$ROOT/.sig-demo/ios/libsignal-bridge-smoke-$SUFFIX"}
xcrun clang -target "$CLANG_TARGET" \
  -isysroot "$(xcrun --sdk "$SDK" --show-sdk-path)" \
  -I "$SOURCE/swift/Sources/SignalFfi" "$HERE/smoke.c" "$LIBRARY" \
  -framework Security -framework Foundation -lc++ -lresolv -o "$OUTPUT"
printf '%s\n' "$OUTPUT"

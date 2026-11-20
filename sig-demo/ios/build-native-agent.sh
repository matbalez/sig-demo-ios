#!/bin/sh
# Copyright 2026 sig demo contributors
# SPDX-License-Identifier: AGPL-3.0-only
set -eu

IOS_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
WORKSPACE_DIR=$(CDPATH= cd -- "$IOS_DIR/../.." && pwd)
AGENT_DIR="$WORKSPACE_DIR/sig-demo/gdk/native-agent"
BUILD_DIR="${CARGO_TARGET_DIR:-$WORKSPACE_DIR/.sig-demo/ios/agent-build}"
PACKAGE_DIR="$IOS_DIR/NativeAgent"
BINDGEN="${SIG_DEMO_UNIFFI_BINDGEN:-$BUILD_DIR/tools/bin/uniffi-bindgen}"

# Keep Rust, cc, and CMake dependencies on the same supported iOS baseline.
# Without this, Rust defaults to iOS 10 while native dependencies can pick the
# installed SDK version, producing incompatible objects and missing stack probes.
export IPHONEOS_DEPLOYMENT_TARGET=17.0
export CMAKE_BUILD_PARALLEL_LEVEL="${CMAKE_BUILD_PARALLEL_LEVEL:-2}"
python3 "$AGENT_DIR/llama/prepare.py"
DEVICE_ONLY=false
if [ "${1:-}" = '--device-only' ]; then
  DEVICE_ONLY=true
elif [ "$#" -ne 0 ]; then
  printf '%s\n' 'Usage: build-native-agent.sh [--device-only]' >&2
  exit 1
fi

if [ ! -x "$BINDGEN" ]; then
  if [ -n "${SIG_DEMO_UNIFFI_BINDGEN:-}" ]; then
    printf '%s\n' "Cannot execute the specified UniFFI binding generator: $BINDGEN" >&2
    exit 1
  fi
  cargo +1.95.0 install --locked uniffi --version 0.32.2 --features cli \
    --bin uniffi-bindgen --root "$BUILD_DIR/tools" --jobs 2
fi

# Device and simulator contain identical Rust/UniFFI code. The macOS executable
# is used only to generate bindings; no executable is launched by the iOS app.
TARGETS='aarch64-apple-ios aarch64-apple-ios-sim'
if [ "$DEVICE_ONLY" = true ]; then TARGETS='aarch64-apple-ios'; fi
for TARGET in $TARGETS; do
  SDK=iphoneos
  if [ "$TARGET" = 'aarch64-apple-ios-sim' ]; then SDK=iphonesimulator; fi
  export SDKROOT=$(xcrun --sdk "$SDK" --show-sdk-path)
  export CMAKE_OSX_SYSROOT="$SDKROOT"
  export CMAKE_OSX_DEPLOYMENT_TARGET="$IPHONEOS_DEPLOYMENT_TARGET"
  set --
  if [ "$TARGET" = 'aarch64-apple-ios' ] && [ "${SIG_DEMO_IOS_LOCAL_TOOL_PROBE:-0}" = 1 ]; then
    set -- --features ios-local-tool-probe
  fi
  cargo +1.95.0 build "$@" --locked --release --manifest-path "$AGENT_DIR/Cargo.toml" \
    --target "$TARGET" --target-dir "$BUILD_DIR" --jobs 2
done

# Build the same ABI for the host smoke test without copying or changing the
# desktop application's native resources.
if [ "$DEVICE_ONLY" = false ]; then
  export SDKROOT=$(xcrun --sdk macosx --show-sdk-path)
  export CMAKE_OSX_SYSROOT="$SDKROOT"
  export CMAKE_OSX_DEPLOYMENT_TARGET=14.0
  cargo +1.95.0 build --locked --release --manifest-path "$AGENT_DIR/Cargo.toml" \
    --target aarch64-apple-darwin --target-dir "$BUILD_DIR" --jobs 2
fi

# Stage bindings and both framework slices together. A failed rebuild must not
# pair fresh bindings with a previously built binary using a different ABI.
STAGING_DIR=$(mktemp -d "$WORKSPACE_DIR/.sig-demo/ios/agent-xcframework.XXXXXX")
trap 'rm -rf "$STAGING_DIR"' EXIT HUP INT TERM
GENERATED_DIR="$STAGING_DIR/generated"
mkdir -p "$GENERATED_DIR" "$PACKAGE_DIR/Sources/SigDemoAgent" "$PACKAGE_DIR/Artifacts"
(
  cd "$AGENT_DIR"
  "$BINDGEN" generate "$BUILD_DIR/aarch64-apple-ios/release/libsig_demo_agent.a" \
    --language swift --out-dir "$GENERATED_DIR" --no-format --metadata-no-deps
)
cp "$GENERATED_DIR/sig_demo_agentFFI.modulemap" "$GENERATED_DIR/module.modulemap"

# Xcode refuses to replace an existing framework. Keep the last good artifact
# until both builds and binding generation have succeeded.
mkdir -p "$STAGING_DIR/headers"
cp "$GENERATED_DIR/sig_demo_agentFFI.h" "$GENERATED_DIR/module.modulemap" "$STAGING_DIR/headers/"
if [ "$DEVICE_ONLY" = true ]; then
  xcodebuild -create-xcframework \
    -library "$BUILD_DIR/aarch64-apple-ios/release/libsig_demo_agent.a" -headers "$STAGING_DIR/headers" \
    -output "$STAGING_DIR/SigDemoAgentFFI.xcframework"
else
  xcodebuild -create-xcframework \
    -library "$BUILD_DIR/aarch64-apple-ios/release/libsig_demo_agent.a" -headers "$STAGING_DIR/headers" \
    -library "$BUILD_DIR/aarch64-apple-ios-sim/release/libsig_demo_agent.a" -headers "$STAGING_DIR/headers" \
    -output "$STAGING_DIR/SigDemoAgentFFI.xcframework"
fi
# llama.cpp embeds the target-specific Metal shader into its static library.
rm -rf "$PACKAGE_DIR/Artifacts/SigDemoAgentFFI.xcframework"
mv "$STAGING_DIR/SigDemoAgentFFI.xcframework" "$PACKAGE_DIR/Artifacts/"
cp "$GENERATED_DIR/sig_demo_agent.swift" "$PACKAGE_DIR/Sources/SigDemoAgent/Generated.swift"
rm -rf "$PACKAGE_DIR/Generated"
mv "$GENERATED_DIR" "$PACKAGE_DIR/Generated"
printf '%s\n' "Native Sig agent ready: $PACKAGE_DIR/Artifacts/SigDemoAgentFFI.xcframework"

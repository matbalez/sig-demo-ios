#!/bin/bash
# Copyright 2026 sig demo contributors
# SPDX-License-Identifier: AGPL-3.0-only
set -euo pipefail

IOS_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
WORKSPACE_DIR=$(CDPATH= cd -- "$IOS_DIR/../.." && pwd -P)
CHECKOUT="$WORKSPACE_DIR/.sig-demo/ios/chatgpt/Signal-iOS"
LIBSIGNAL_ARCHIVE="$WORKSPACE_DIR/.sig-demo/ios/libsignal-build/aarch64-apple-ios-sim/debug/libsignal_ffi.a"
BUILD_DIR="$WORKSPACE_DIR/.sig-demo/ios/chatgpt/Build"
RINGRTC_PREBUILD="$WORKSPACE_DIR/.sig-demo/ios/ringrtc-cache/prebuild-2.72.0"
PRODUCTS_POINTER="$BUILD_DIR/products-directory.txt"
BUILD_JOBS=4
CHECK_ONLY=false

usage() {
  printf '%s\n' 'Usage: build-app.sh [--checkout PATH] [--libsignal PATH] [--jobs N] [--check]'
  printf '%s\n' 'Builds the prepared Debug arm64 simulator app without changing its backend configuration.'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --checkout|--libsignal|--jobs)
      if [[ $# -lt 2 || "$2" == --* ]]; then usage >&2; exit 2; fi
      case "$1" in
        --checkout) CHECKOUT="$2" ;;
        --libsignal) LIBSIGNAL_ARCHIVE="$2" ;;
        --jobs) BUILD_JOBS="$2" ;;
      esac
      shift 2 ;;
    --check) CHECK_ONLY=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

if [[ ! "$BUILD_JOBS" =~ ^[1-9][0-9]*$ ]]; then echo '--jobs must be a positive integer.' >&2; exit 2; fi
if [[ ! -d "$CHECKOUT/Signal.xcodeproj" ]]; then
  echo 'Prepare the pinned private source checkout with prepare-upstream.mjs first.' >&2
  exit 1
fi
CHECKOUT=$(CDPATH= cd -- "$CHECKOUT" && pwd -P)
if [[ ! -d "$CHECKOUT/Pods/Pods.xcodeproj" || ! -f "$CHECKOUT/Pods/Manifest.lock" ]]; then
  echo 'The pinned Signal Pods dependencies are missing; run sig-demo/ios/fetch-dependencies.sh first.' >&2
  exit 1
fi
if ! cmp -s "$CHECKOUT/Podfile.lock" "$CHECKOUT/Pods/Manifest.lock"; then
  echo 'The installed Pods manifest differs from the pinned Podfile.lock. Resolve the dependency setup before building.' >&2
  exit 1
fi
if [[ ! -s "$LIBSIGNAL_ARCHIVE" ]]; then
  echo 'The private simulator libsignal archive is missing. Build libsignal/build.sh aarch64-apple-ios-sim debug, or pass --libsignal.' >&2
  exit 1
fi
LIBSIGNAL_ARCHIVE="$(CDPATH= cd -- "$(dirname -- "$LIBSIGNAL_ARCHIVE")" && pwd -P)/$(basename -- "$LIBSIGNAL_ARCHIVE")"
if [[ ! -f "$IOS_DIR/NativeAgent/Artifacts/SigDemoAgentFFI.xcframework/Info.plist" ||
      ! -f "$IOS_DIR/NativeAgent/Sources/SigDemoAgent/Generated.swift" ]]; then
  echo 'The native Sig agent framework or bindings are missing; run build-native-agent.sh first.' >&2
  exit 1
fi
if [[ ! -f "$WORKSPACE_DIR/.sig-demo/ios/mesh-sdk-v0.78.1/sdk/swift/Generated/MeshLLMFFI.xcframework/Info.plist" ]]; then
  echo 'The pinned embedded Mesh SDK is missing; run python3 sig-demo/ios/Mesh/prepare.py first.' >&2
  exit 1
fi
if [[ ! -f "$IOS_DIR/PaidMesh/Artifacts/SigDemoPaidMeshFFI.xcframework/Info.plist" ]]; then
  echo 'The isolated paid Mesh native artifact is missing; run sh sig-demo/ios/PaidMesh/build.sh first.' >&2
  exit 1
fi
if [[ ! -f "$RINGRTC_PREBUILD/prebuild-checksum" ||
      ! -f "$RINGRTC_PREBUILD/release/WebRTC.xcframework/Info.plist" ]]; then
  echo 'The pinned RingRTC prebuild is missing from .sig-demo/ios/ringrtc-cache/prebuild-2.72.0. Complete dependency setup first.' >&2
  exit 1
fi
if ! cmp -s "$CHECKOUT/Pods/SignalRingRTC/prebuild-checksum" "$RINGRTC_PREBUILD/prebuild-checksum"; then
  echo 'The RingRTC prebuild checksum differs from the pinned dependency. Complete dependency setup before building.' >&2
  exit 1
fi

# Keep products and compiler caches outside FileProvider: evicted intermediate
# outputs can block Swift while it compares a new output with its predecessor.
if [[ -f "$PRODUCTS_POINTER" ]]; then
  IFS= read -r PRODUCTS_DIR < "$PRODUCTS_POINTER"
  LOCAL_BUILD_ROOT="${PRODUCTS_DIR%/Products}"
  if [[ ! "$PRODUCTS_DIR" =~ ^/private/tmp/sig-demo-ios-simulator-build-[[:alnum:]]+/Products$ ||
        ! -d "$PRODUCTS_DIR" || -L "$PRODUCTS_DIR" || ! -O "$PRODUCTS_DIR" ||
        ! -d "$LOCAL_BUILD_ROOT" || -L "$LOCAL_BUILD_ROOT" || ! -O "$LOCAL_BUILD_ROOT" ]]; then
    echo 'The simulator products pointer is invalid; inspect the ignored build output before retrying.' >&2
    exit 1
  fi
elif $CHECK_ONLY; then
  PRODUCTS_DIR='/private/tmp/sig-demo-ios-simulator-build-<generated>/Products'
else
  mkdir -p "$BUILD_DIR"
  PRODUCTS_DIR="$(mktemp -d /private/tmp/sig-demo-ios-simulator-build-XXXXXX)/Products"
  mkdir -p "$PRODUCTS_DIR"
  (umask 077; printf '%s\n' "$PRODUCTS_DIR" > "$PRODUCTS_POINTER")
fi
LOCAL_BUILD_ROOT="${PRODUCTS_DIR%/Products}"
INTERMEDIATES_DIR="$LOCAL_BUILD_ROOT/Intermediates.noindex"
PRECOMPS_DIR="$LOCAL_BUILD_ROOT/PrecompiledHeaders"
for CACHE_DIR in "$INTERMEDIATES_DIR" "$PRECOMPS_DIR"; do
  if [[ -L "$CACHE_DIR" || ( -e "$CACHE_DIR" && ( ! -d "$CACHE_DIR" || ! -O "$CACHE_DIR" ) ) ]]; then
    echo 'A simulator compiler cache path is invalid; inspect the private build output before retrying.' >&2
    exit 1
  fi
done

# Absolute paths matter here: SwiftPM can interpret a relative SYMROOT against
# each local package and otherwise emit products into tracked source folders.
COMMON=(
  -configuration Debug -sdk iphonesimulator -jobs "$BUILD_JOBS"
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES IPHONEOS_DEPLOYMENT_TARGET=16.0
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
  # The two Rust static libraries contain unused standard-library personality
  # objects. Normal dead stripping selects only referenced archive members.
  DEAD_CODE_STRIPPING=YES
  # Upstream still uses synchronous APIs deprecated at our iOS 16 baseline.
  # Keep those warnings visible without blocking this development build.
  SWIFT_TREAT_WARNINGS_AS_ERRORS=NO
  'OTHER_LDFLAGS=$(inherited) -lc++ -lresolv'
  "LIBSIGNAL_FFI_LIB_TO_LINK=$LIBSIGNAL_ARCHIVE"
  "RINGRTC_PREBUILD_DIR=$RINGRTC_PREBUILD"
  "SYMROOT=$PRODUCTS_DIR"
  "OBJROOT=$INTERMEDIATES_DIR"
  "SHARED_PRECOMPS_DIR=$PRECOMPS_DIR"
)
PODS_COMMAND=(
  xcodebuild -project "$CHECKOUT/Pods/Pods.xcodeproj"
  -target Pods-Signal
  -target Pods-SignalServiceKit
  -target Pods-SignalUI
  -target Pods-SignalNSE
  -target Pods-SignalShareExtension
  "${COMMON[@]}" build
)
APP_COMMAND=(xcodebuild -project "$CHECKOUT/Signal.xcodeproj" -target Signal "${COMMON[@]}" build)
APP="$PRODUCTS_DIR/Debug-iphonesimulator/Signal.app"

if $CHECK_ONLY; then
  printf '%s\n' 'Prepared source and native dependencies are present. Planned commands:'
  printf '%q ' "${PODS_COMMAND[@]}"; printf '\n'
  printf '%q ' "${APP_COMMAND[@]}"; printf '\n'
  printf '%q ' python3 "$IOS_DIR/sign-simulator.py" --app "$APP" --stage; printf '\n'
  printf 'Simulator app: %s\n' "$APP"
  exit 0
fi

mkdir -p "$BUILD_DIR/Logs"
if ! mkdir "$BUILD_DIR/.build-app.lock" 2>/dev/null; then
  echo "A build lock exists at $BUILD_DIR/.build-app.lock. Verify that no other build uses this output directory." >&2
  exit 1
fi
trap 'rmdir "$BUILD_DIR/.build-app.lock" 2>/dev/null || true' EXIT HUP INT TERM
cd "$CHECKOUT"

# Direct project targets avoid the upstream workspace scheme's simulator
# eligibility check. Build the complete Pods dependency closure and the five
# wrapper frameworks referenced by the app, frameworks, and extension targets.
"${PODS_COMMAND[@]}" 2>&1 | tee "$BUILD_DIR/Logs/pods.log"
"${APP_COMMAND[@]}" 2>&1 | tee "$BUILD_DIR/Logs/app.log"
test -d "$APP"
python3 "$IOS_DIR/sign-simulator.py" --app "$APP" --stage 2>&1 | tee "$BUILD_DIR/Logs/signing.log"
printf 'Native simulator staging receipt: %s\n' "$BUILD_DIR/simulator-app.json"

#!/bin/sh
# Copyright 2026 Sig Demo contributors
# SPDX-License-Identifier: AGPL-3.0-only
set -eu

PAID_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
WORKSPACE_DIR=$(CDPATH= cd -- "$PAID_DIR/../../.." && pwd)
BUILD_DIR="$WORKSPACE_DIR/.sig-demo/ios/paid-mesh-build"
sh "$PAID_DIR/prepare.sh"

# Rust and native dependencies must agree on minimum OS versions. The client
# mode does not install/download a model runtime and never starts a subprocess.
export IPHONEOS_DEPLOYMENT_TARGET=16.0
export MACOSX_DEPLOYMENT_TARGET=13.0
TARGETS=${PAID_MESH_TARGETS:-"aarch64-apple-darwin aarch64-apple-ios-sim aarch64-apple-ios"}
for TARGET in $TARGETS; do
  just --justfile "$PAID_DIR/Justfile" build "$TARGET"
done

STAGING=$(mktemp -d "$WORKSPACE_DIR/.sig-demo/ios/paid-mesh-framework.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT HUP INT TERM
mkdir -p "$PAID_DIR/Artifacts"
for TARGET in $TARGETS; do
  FRAMEWORK="$STAGING/$TARGET/SigDemoPaidMeshFFI.framework"
  mkdir -p "$FRAMEWORK/Headers" "$FRAMEWORK/Modules"
  case "$TARGET" in
    aarch64-apple-darwin) PLATFORM=MacOSX; MINIMUM=13.0; CLANG_TARGET=arm64-apple-macos13.0; SDK=macosx ;;
    aarch64-apple-ios-sim) PLATFORM=iPhoneSimulator; MINIMUM=16.0; CLANG_TARGET=arm64-apple-ios16.0-simulator; SDK=iphonesimulator ;;
    aarch64-apple-ios) PLATFORM=iPhoneOS; MINIMUM=16.0; CLANG_TARGET=arm64-apple-ios16.0; SDK=iphoneos ;;
    *) printf 'Unsupported paid Mesh target: %s\n' "$TARGET" >&2; exit 1 ;;
  esac
  SDK_PATH=$(xcrun --sdk "$SDK" --show-sdk-path)
  set -- -framework Network -framework Security -framework SystemConfiguration -framework CoreFoundation
  if [ "$SDK" = macosx ]; then set -- "$@" -framework IOKit; fi
  # A source-built wrapper closes the export namespace over exactly our five
  # entrypoints. Rust's direct cdylib also re-exports dependency no_mangle APIs.
  xcrun clang++ -dynamiclib -target "$CLANG_TARGET" -isysroot "$SDK_PATH" \
    -Wl,-dead_strip -Wl,-twolevel_namespace \
    -Wl,-force_load,"$BUILD_DIR/$TARGET/release/libsig_demo_paid_mesh.a" \
    -Wl,-exported_symbols_list,"$PAID_DIR/Rust/native.exports" \
    -Wl,-install_name,@rpath/SigDemoPaidMeshFFI.framework/SigDemoPaidMeshFFI \
    "$@" -lresolv -liconv -lz -o "$FRAMEWORK/SigDemoPaidMeshFFI"
  cp "$PAID_DIR/include/sig_demo_paid_mesh.h" "$FRAMEWORK/Headers/SigDemoPaidMeshFFI.h"
  cat > "$FRAMEWORK/Modules/module.modulemap" <<'MODULEMAP'
framework module SigDemoPaidMeshFFI {
  umbrella header "SigDemoPaidMeshFFI.h"
  export *
  module * { export * }
}
MODULEMAP
  cat > "$FRAMEWORK/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.matbalez.sig-demo.ios.paid-mesh.ffi</string>
<key>CFBundleExecutable</key><string>SigDemoPaidMeshFFI</string>
<key>CFBundleName</key><string>SigDemoPaidMeshFFI</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>MinimumOSVersion</key><string>$MINIMUM</string>
<key>CFBundleSupportedPlatforms</key><array><string>$PLATFORM</string></array>
</dict></plist>
PLIST
  xcrun nm -gUj "$FRAMEWORK/SigDemoPaidMeshFFI" | LC_ALL=C sort > "$STAGING/$TARGET.exports"
  diff -u "$PAID_DIR/Rust/native.exports" "$STAGING/$TARGET.exports"
  xcrun otool -D "$FRAMEWORK/SigDemoPaidMeshFFI" | tail -1 | \
    rg -x '@rpath/SigDemoPaidMeshFFI.framework/SigDemoPaidMeshFFI'
  xcrun otool -hv "$FRAMEWORK/SigDemoPaidMeshFFI" | rg 'TWOLEVEL'
  xcrun nm -m "$FRAMEWORK/SigDemoPaidMeshFFI" | rg 'non-external.*_sqlite3_open_v2$'
  if xcrun nm -u "$FRAMEWORK/SigDemoPaidMeshFFI" | rg 'sqlite3_'; then
    printf '%s\n' 'Paid Mesh must bind its SQLite inside its own framework.' >&2
    exit 1
  fi
done

# The paid dynamic boundary owns its Rust/C runtime and bundled SQLite.
# Only the five prefixed C functions are exported; no SQLite/Rust symbols can
# satisfy another framework's references through this dependency.
set -- -create-xcframework
for TARGET in $TARGETS; do
  set -- "$@" -framework "$STAGING/$TARGET/SigDemoPaidMeshFFI.framework"
done
xcodebuild "$@" -output "$STAGING/SigDemoPaidMeshFFI.xcframework"
rm -rf "$PAID_DIR/Artifacts/SigDemoPaidMeshFFI.xcframework"
mv "$STAGING/SigDemoPaidMeshFFI.xcframework" "$PAID_DIR/Artifacts/"
printf '%s\n' "Paid Mesh native dependency ready: $PAID_DIR/Artifacts/SigDemoPaidMeshFFI.xcframework"

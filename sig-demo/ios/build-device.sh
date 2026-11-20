#!/bin/bash
# Copyright 2026 Sig Demo contributors
# SPDX-License-Identifier: AGPL-3.0-only
set -euo pipefail

IOS_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
WORKSPACE_DIR=$(CDPATH= cd -- "$IOS_DIR/../.." && pwd -P)
CHECKOUT="$WORKSPACE_DIR/.sig-demo/ios/chatgpt/Signal-iOS"
LIBSIGNAL_ARCHIVE="$WORKSPACE_DIR/.sig-demo/ios/libsignal-build/aarch64-apple-ios/release/libsignal_ffi.a"
RECEIPT_DIR="$WORKSPACE_DIR/.sig-demo/ios/device-release"
POINTER="$RECEIPT_DIR/build-directory.txt"
RINGRTC_PREBUILD="$WORKSPACE_DIR/.sig-demo/ios/ringrtc-cache/prebuild-2.72.0"
BUILD_JOBS=2
VERSION=0.1.0
BUILD_NUMBER=
TEAM_ID=
CHECK_ONLY=false
SIGNED=false
ALLOW_PROVISIONING=false
SOURCE_ARCHIVE=
SOURCE_SHA256=
LOCAL_MODELS=
LOCAL_MODEL_PACKAGE=

usage() {
  printf '%s\n' 'Usage: build-device.sh --build-number N [--version X.Y.Z] [--libsignal PATH] [--checkout PATH] [--jobs N] [--check]'
  printf '%s\n' '       [--signed --team TEAM_ID [--allow-provisioning-updates]]'
  printf '%s\n' '       [--source-archive /absolute/path/SigDemoSource.tar.gz --source-sha256 SHA256]'
  printf '%s\n' '       [--local-models /absolute/model/directory [--local-model-package PATH]]'
  printf '%s\n' 'Creates an unsigned arm64 iPhone App Store Release archive by default. Signing never uploads the app.'
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --checkout|--libsignal|--jobs|--version|--build-number|--team|--source-archive|--source-sha256|--local-models|--local-model-package)
      if [[ $# -lt 2 || "$2" == --* ]]; then usage >&2; exit 2; fi
      case "$1" in
        --checkout) CHECKOUT="$2" ;;
        --libsignal) LIBSIGNAL_ARCHIVE="$2" ;;
        --jobs) BUILD_JOBS="$2" ;;
        --version) VERSION="$2" ;;
        --build-number) BUILD_NUMBER="$2" ;;
        --team) TEAM_ID="$2" ;;
        --source-archive) SOURCE_ARCHIVE="$2" ;;
        --source-sha256) SOURCE_SHA256="$2" ;;
        --local-models) LOCAL_MODELS="$2" ;;
        --local-model-package) LOCAL_MODEL_PACKAGE="$2" ;;
      esac
      shift 2 ;;
    --check) CHECK_ONLY=true; shift ;;
    --signed) SIGNED=true; shift ;;
    --allow-provisioning-updates) ALLOW_PROVISIONING=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
if [[ ! "$BUILD_JOBS" =~ ^[1-9][0-9]*$ || ! "$BUILD_NUMBER" =~ ^[1-9][0-9]{0,8}$ || ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo 'Use a positive --jobs, a positive --build-number (at most nine digits), and --version X.Y.Z.' >&2; exit 2
fi
if [[ -n "$LOCAL_MODEL_PACKAGE" && -z "$LOCAL_MODELS" ]]; then
  echo '--local-model-package requires --local-models.' >&2; exit 2
fi
MINIMUM_IOS=16.0
if [[ -n "$LOCAL_MODELS" ]]; then MINIMUM_IOS=17.0; fi
if [[ -n "$SOURCE_ARCHIVE" || -n "$SOURCE_SHA256" ]]; then
  if [[ "$SOURCE_ARCHIVE" != /* || ! -f "$SOURCE_ARCHIVE" || -L "$SOURCE_ARCHIVE" || ! "$SOURCE_SHA256" =~ ^[a-f0-9]{64}$ ]]; then
    echo 'The source resource requires an absolute regular archive file and its lowercase SHA256.' >&2; exit 2
  fi
  python3 - "$SOURCE_ARCHIVE" "$SOURCE_SHA256" <<'PY'
import hashlib, sys
from pathlib import Path
digest = hashlib.sha256()
with Path(sys.argv[1]).open('rb') as stream:
    for chunk in iter(lambda: stream.read(1024 * 1024), b''):
        digest.update(chunk)
if digest.hexdigest() != sys.argv[2]:
    raise SystemExit('The corresponding source archive does not match its expected SHA256.')
PY
fi
if $SIGNED; then
  if [[ ! "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then echo 'A signed archive requires --team with the private developer team ID.' >&2; exit 2; fi
elif [[ -n "$TEAM_ID" ]] || $ALLOW_PROVISIONING; then
  echo '--team and --allow-provisioning-updates require --signed.' >&2; exit 2
fi
if [[ ! -d "$CHECKOUT/Signal.xcodeproj" || ! -d "$CHECKOUT/Pods/Pods.xcodeproj" ]]; then
  echo 'Prepare the pinned private checkout and fetch its dependencies first.' >&2; exit 1
fi
CHECKOUT=$(CDPATH= cd -- "$CHECKOUT" && pwd -P)
if ! cmp -s "$CHECKOUT/Podfile.lock" "$CHECKOUT/Pods/Manifest.lock"; then
  echo 'Installed Pods differ from the pinned lockfile; dependencies were preserved.' >&2; exit 1
fi
if [[ ! -s "$LIBSIGNAL_ARCHIVE" ]]; then
  echo 'Pass --libsignal with the verified aarch64-apple-ios production libsignal archive.' >&2; exit 1
fi
LIBSIGNAL_ARCHIVE="$(CDPATH= cd -- "$(dirname -- "$LIBSIGNAL_ARCHIVE")" && pwd -P)/$(basename -- "$LIBSIGNAL_ARCHIVE")"
for REQUIRED in \
  "$IOS_DIR/NativeAgent/Artifacts/SigDemoAgentFFI.xcframework/Info.plist" \
  "$IOS_DIR/PaidMesh/Artifacts/SigDemoPaidMeshFFI.xcframework/Info.plist" \
  "$WORKSPACE_DIR/.sig-demo/ios/mesh-sdk-v0.78.1/sdk/swift/Generated/MeshLLMFFI.xcframework/Info.plist" \
  "$RINGRTC_PREBUILD/release/WebRTC.xcframework/Info.plist" \
  "$IOS_DIR/branding/SigDemo.xcassets/SigDemoAppIcon.appiconset/Contents.json"; do
  if [[ ! -f "$REQUIRED" ]]; then echo "Missing device prerequisite: $REQUIRED" >&2; exit 1; fi
done
if ! cmp -s "$CHECKOUT/Pods/SignalRingRTC/prebuild-checksum" "$RINGRTC_PREBUILD/prebuild-checksum"; then
  echo 'RingRTC does not match the pinned prebuild.' >&2; exit 1
fi
if [[ ! -f "$WORKSPACE_DIR/.sig-demo/ios/ruby-gems/cache/xcodeproj-1.28.1.gem" ]]; then
  echo 'The pinned workspace Ruby build archives are required; fetch-dependencies.sh installs them.' >&2; exit 1
fi

if [[ -f "$POINTER" ]]; then
  IFS= read -r LOCAL_BUILD_ROOT < "$POINTER"
  if [[ ! "$LOCAL_BUILD_ROOT" =~ ^/private/tmp/sig-demo-ios-device-build-[[:alnum:]]+$ ||
        ! -d "$LOCAL_BUILD_ROOT" || -L "$LOCAL_BUILD_ROOT" || ! -O "$LOCAL_BUILD_ROOT" ]]; then
    echo 'Invalid owned device build pointer; existing outputs were preserved.' >&2; exit 1
  fi
elif $CHECK_ONLY; then
  LOCAL_BUILD_ROOT='/private/tmp/sig-demo-ios-device-build-<generated>'
else
  mkdir -p "$RECEIPT_DIR"
  LOCAL_BUILD_ROOT=$(mktemp -d /private/tmp/sig-demo-ios-device-build-XXXXXX)
  (umask 077; printf '%s\n' "$LOCAL_BUILD_ROOT" > "$POINTER")
fi
for CHILD in Products DerivedData Intermediates.noindex PrecompiledHeaders ReleaseMetadata Signal.xcodeproj Archives RubyGems RubyGemArchives; do
  ITEM="$LOCAL_BUILD_ROOT/$CHILD"
  if [[ -L "$ITEM" || ( -e "$ITEM" && ( ! -d "$ITEM" || ! -O "$ITEM" ) ) ]]; then
    echo 'Invalid device output path; existing outputs were preserved.' >&2; exit 1
  fi
done

# Xcode normalizes DerivedData to /tmp. Use that same spelling for every
# output root so its relative skip-install framework links remain valid.
XCODE_BUILD_ROOT=${LOCAL_BUILD_ROOT#/private}
COMMON=(
  -configuration 'App Store Release' -sdk iphoneos -jobs "$BUILD_JOBS"
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO "IPHONEOS_DEPLOYMENT_TARGET=$MINIMUM_IOS"
  DEAD_CODE_STRIPPING=YES SWIFT_TREAT_WARNINGS_AS_ERRORS=NO
  'OTHER_LDFLAGS=$(inherited) -lc++ -lresolv'
  "LIBSIGNAL_FFI_LIB_TO_LINK=$LIBSIGNAL_ARCHIVE"
  "RINGRTC_PREBUILD_DIR=$RINGRTC_PREBUILD"
  "OBJROOT=$XCODE_BUILD_ROOT/Intermediates.noindex"
  "SHARED_PRECOMPS_DIR=$XCODE_BUILD_ROOT/PrecompiledHeaders"
)
PODS_COMMAND=(xcodebuild -project "$CHECKOUT/Pods/Pods.xcodeproj"
  -target Pods-Signal -target Pods-SignalServiceKit -target Pods-SignalUI
  -target Pods-SignalNSE -target Pods-SignalShareExtension
  "${COMMON[@]}" "SYMROOT=$XCODE_BUILD_ROOT/Products"
  CODE_SIGNING_ALLOWED=NO DEVELOPMENT_TEAM= build)
SIGNING=(CODE_SIGNING_ALLOWED=NO DEVELOPMENT_TEAM= CODE_SIGN_IDENTITY=)
if $SIGNED; then
  SIGNING=(CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Automatic "DEVELOPMENT_TEAM=$TEAM_ID" 'CODE_SIGN_IDENTITY=Apple Development')
  if $ALLOW_PROVISIONING; then SIGNING+=(-allowProvisioningUpdates); fi
fi
APP_COMMAND=(xcodebuild -project "$LOCAL_BUILD_ROOT/Signal.xcodeproj" -scheme Signal
  # Let the archive action create its own BuildProductsPath for collection.
  # CocoaPods still resolves to the separately built, qualified products.
  -destination 'generic/platform=iOS' -derivedDataPath "$XCODE_BUILD_ROOT/DerivedData"
  "${COMMON[@]}" "PODS_BUILD_DIR=$XCODE_BUILD_ROOT/Products"
  'FRAMEWORK_SEARCH_PATHS=$(inherited) "$(PODS_CONFIGURATION_BUILD_DIR)"'
  "${SIGNING[@]}")
PROJECT_COMMAND=(ruby "$IOS_DIR/prepare-device-project.rb" --checkout "$CHECKOUT" --output "$LOCAL_BUILD_ROOT" --version "$VERSION" --build-number "$BUILD_NUMBER")
if [[ -n "$LOCAL_MODELS" ]]; then
  PROJECT_COMMAND=(ruby "$IOS_DIR/prepare-local-device-project.rb" --testflight --checkout "$CHECKOUT" --output "$LOCAL_BUILD_ROOT" --version "$VERSION" --build-number "$BUILD_NUMBER" --local-models "$LOCAL_MODELS")
  if [[ -n "$LOCAL_MODEL_PACKAGE" ]]; then PROJECT_COMMAND+=(--local-model-package "$LOCAL_MODEL_PACKAGE"); fi
fi
if [[ -n "$SOURCE_ARCHIVE" ]]; then PROJECT_COMMAND+=(--source-archive "$SOURCE_ARCHIVE" --source-sha256 "$SOURCE_SHA256"); fi

if $CHECK_ONLY; then
  printf '%s\n' 'Device dependencies are present. Planned commands (no signing or provisioning performed):'
  printf '%q ' bash "$IOS_DIR/prepare-device-ruby.sh" "$LOCAL_BUILD_ROOT"; printf '\n'
  printf '%q ' "${PROJECT_COMMAND[@]}"; printf '\n'
  printf '%q ' "${PODS_COMMAND[@]}"; printf '\n'
  printf '%q ' "${APP_COMMAND[@]}" -archivePath "$LOCAL_BUILD_ROOT/Archives/<new>/SigDemo.xcarchive" archive; printf '\n'
  exit 0
fi

mkdir -p "$RECEIPT_DIR/Logs"
if ! mkdir "$RECEIPT_DIR/.build-device.lock" 2>/dev/null; then
  echo 'A device build lock exists; verify that no device build is active before retrying.' >&2; exit 1
fi
trap 'rmdir "$RECEIPT_DIR/.build-device.lock" 2>/dev/null || true' EXIT HUP INT TERM
python3 "$IOS_DIR/libsignal/verify-library.py" "$LIBSIGNAL_ARCHIVE" --platform ios
bash "$IOS_DIR/prepare-device-ruby.sh" "$LOCAL_BUILD_ROOT"
export GEM_HOME="$LOCAL_BUILD_ROOT/RubyGems"
export GEM_PATH="$GEM_HOME"
"${PROJECT_COMMAND[@]}"
mkdir -p "$LOCAL_BUILD_ROOT/Archives"
ARCHIVE_PARENT=$(mktemp -d "$LOCAL_BUILD_ROOT/Archives/$VERSION-$BUILD_NUMBER-XXXXXX")
ARCHIVE_PATH="$ARCHIVE_PARENT/SigDemo.xcarchive"
"${PODS_COMMAND[@]}" 2>&1 | tee "$RECEIPT_DIR/Logs/pods.log"
"${APP_COMMAND[@]}" -archivePath "$ARCHIVE_PATH" archive 2>&1 | tee "$RECEIPT_DIR/Logs/archive.log"
INSPECT_COMMAND=(python3 "$IOS_DIR/inspect-device-archive.py" "$ARCHIVE_PATH" --version "$VERSION" --build-number "$BUILD_NUMBER")
if $SIGNED; then INSPECT_COMMAND+=(--require-signed --team "$TEAM_ID"); fi
if [[ -n "$SOURCE_ARCHIVE" ]]; then INSPECT_COMMAND+=(--require-source); fi
"${INSPECT_COMMAND[@]}"
(umask 077; printf '%s\n' "$ARCHIVE_PATH" > "$RECEIPT_DIR/archive-path.txt")
printf 'Device archive: %s\n' "$ARCHIVE_PATH"
if ! $SIGNED; then printf '%s\n' 'Unsigned validation archive only; it cannot be installed or uploaded.'; fi

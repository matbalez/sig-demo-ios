#!/bin/bash
# Copyright 2026 Sig Demo contributors
# SPDX-License-Identifier: AGPL-3.0-only
set -euo pipefail
IOS_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
WORKSPACE_DIR=$(CDPATH= cd -- "$IOS_DIR/../.." && pwd -P)
RECEIPT_DIR="$WORKSPACE_DIR/.sig-demo/ios/device-release"
ARCHIVE=
TEAM_ID=
METHOD=app-store-connect
ALLOW_PROVISIONING=false
CHECK_ONLY=false
usage() {
  printf '%s\n' 'Usage: export-device.sh --team TEAM_ID [--archive PATH] [--allow-provisioning-updates] [--check]'
  printf '%s\n' 'Requests a local App Store Connect signed export of the private archive. This command never uploads.'
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --team|--archive)
      if [[ $# -lt 2 || "$2" == --* ]]; then usage >&2; exit 2; fi
      case "$1" in --team) TEAM_ID="$2" ;; --archive) ARCHIVE="$2" ;; esac
      shift 2 ;;
    --allow-provisioning-updates) ALLOW_PROVISIONING=true; shift ;;
    --check) CHECK_ONLY=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
if [[ ! "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then usage >&2; exit 2; fi
if [[ -z "$ARCHIVE" && -f "$RECEIPT_DIR/archive-path.txt" ]]; then IFS= read -r ARCHIVE < "$RECEIPT_DIR/archive-path.txt"; fi
if [[ ! "$ARCHIVE" =~ ^/private/tmp/sig-demo-ios-device-build-[[:alnum:]]+/Archives/[[:alnum:].-]+/SigDemo.xcarchive$ ||
      ! -d "$ARCHIVE" || -L "$ARCHIVE" || ! -O "$ARCHIVE" ]]; then
  echo 'Pass an owned archive produced by build-device.sh.' >&2; exit 1
fi
LOCAL_BUILD_ROOT="${ARCHIVE%%/Archives/*}"
if [[ ! -d "$LOCAL_BUILD_ROOT" || -L "$LOCAL_BUILD_ROOT" || ! -O "$LOCAL_BUILD_ROOT" ]]; then echo 'Invalid private device build root.' >&2; exit 1; fi
for ITEM in "$LOCAL_BUILD_ROOT/Exports" "$RECEIPT_DIR/Logs"; do
  if [[ -L "$ITEM" || ( -e "$ITEM" && ( ! -d "$ITEM" || ! -O "$ITEM" ) ) ]]; then echo 'Invalid owned export path.' >&2; exit 1; fi
done
if $CHECK_ONLY; then
  printf 'Local export method: %s; private team: %s; archive: %s\n' "$METHOD" "$TEAM_ID" "$ARCHIVE"
  printf '%s\n' 'Private archive validation, local export and exported signature checks will run without uploading. Provisioning updates require the explicit flag.'
  exit 0
fi
mkdir -p "$LOCAL_BUILD_ROOT/Exports" "$RECEIPT_DIR/Logs"
EXPORT_DIR=$(mktemp -d "$LOCAL_BUILD_ROOT/Exports/$METHOD-XXXXXX")
python3 - "$ARCHIVE" "$TEAM_ID" "$METHOD" "$EXPORT_DIR/ExportOptions.plist" "$IOS_DIR/inspect-device-archive.py" <<'PY'
import plistlib, subprocess, sys
from pathlib import Path
archive, team, method, output, inspector = sys.argv[1:]
app=Path(archive)/'Products/Applications/Signal.app'
info=plistlib.loads((app/'Info.plist').read_bytes())
subprocess.run(['python3', inspector, archive,
                '--version', info['CFBundleShortVersionString'], '--build-number', info['CFBundleVersion'], '--require-source'], check=True)
opts={'method':method, 'destination':'export', 'teamID':team, 'signingStyle':'automatic',
      'manageAppVersionAndBuildNumber':False, 'stripSwiftSymbols':True}
if method=='app-store-connect': opts.update(uploadSymbols=True, testFlightInternalTestingOnly=False)
Path(output).write_bytes(plistlib.dumps(opts))
PY
COMMAND=(xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT_DIR" -exportOptionsPlist "$EXPORT_DIR/ExportOptions.plist")
if $ALLOW_PROVISIONING; then COMMAND+=(-allowProvisioningUpdates); fi
"${COMMAND[@]}" 2>&1 | tee "$RECEIPT_DIR/Logs/export.log"
python3 - "$EXPORT_DIR" "$TEAM_ID" "$IOS_DIR/inspect-device-archive.py" <<'PY'
import os, plistlib, subprocess, sys, zipfile
from pathlib import Path
directory, team, inspector = sys.argv[1:]
directory=Path(directory)
ipas=list(directory.glob('*.ipa'))
if len(ipas)!=1: raise SystemExit('The local App Store export did not produce one IPA.')
verification=directory/'SignatureVerification'
verification.mkdir()
with zipfile.ZipFile(ipas[0]) as archive:
    archive.extractall(verification)
    for info in archive.infolist():
        path=verification/info.filename
        if path.is_file() and info.external_attr>>16:
            path.chmod((info.external_attr>>16)&0o777)
apps=list((verification/'Payload').glob('*.app'))
if len(apps)!=1: raise SystemExit('Unexpected exported IPA application layout.')
destination=verification/'Products/Applications/Signal.app'
destination.parent.mkdir(parents=True)
apps[0].rename(destination)
info=plistlib.loads((destination/'Info.plist').read_bytes())
subprocess.run(['python3',inspector,str(verification),'--version',info['CFBundleShortVersionString'],
                '--build-number',info['CFBundleVersion'],'--require-signed','--require-source','--team',team],check=True)
PY
(umask 077; printf '%s\n' "$EXPORT_DIR" > "$RECEIPT_DIR/export-path.txt")
printf 'Local signed export: %s\n' "$EXPORT_DIR"
printf '%s\n' 'Upload and TestFlight distribution are separate actions.'

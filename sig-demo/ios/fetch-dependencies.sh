#!/bin/sh
# Copyright 2026 sig demo contributors
# SPDX-License-Identifier: AGPL-3.0-only
set -eu
IOS_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
WORKSPACE_DIR=$(CDPATH= cd -- "$IOS_DIR/../.." && pwd)
CHECKOUT=${1:-"$WORKSPACE_DIR/.sig-demo/ios/chatgpt/Signal-iOS"}

# Fetch only the public pinned application dependencies. The upstream Makefile
# also resets Pod checkouts; that would discard our private libsignal bridge.
git -C "$CHECKOUT" submodule update --init --depth 1 Pods

# Keep downloaded RingRTC/WebRTC binaries in this demo's ignored build tree.
RING_DIR="$CHECKOUT/Pods/SignalRingRTC"
export SIG_DEMO_RINGRTC_CACHE="$WORKSPACE_DIR/.sig-demo/ios/ringrtc-cache"
python3 - "$RING_DIR" <<'PY'
from pathlib import Path
import sys
directory = Path(sys.argv[1])
script = (directory / 'bin/set-up-for-cocoapods').read_text()
needle = 'CACHE_DIR=~/Library/Caches/org.signal.ringrtc'
if script.count(needle) != 1:
    raise SystemExit('The pinned RingRTC setup script has changed.')
(directory / 'bin/sig-demo-set-up-for-cocoapods').write_text(
    script.replace(needle, 'CACHE_DIR="${SIG_DEMO_RINGRTC_CACHE:?}"'))
PY
sh "$RING_DIR/bin/sig-demo-set-up-for-cocoapods"

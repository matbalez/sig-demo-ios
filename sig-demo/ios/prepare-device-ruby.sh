#!/bin/bash
# Copyright 2026 Sig Demo contributors
# SPDX-License-Identifier: AGPL-3.0-only
# Reinstall the exact existing build-tool archives into an unsynced directory.
set -euo pipefail
IOS_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
WORKSPACE_DIR=$(CDPATH= cd -- "$IOS_DIR/../.." && pwd -P)
DESTINATION=${1:?Pass the owned private device build root}
if [[ ! "$DESTINATION" =~ ^/private/tmp/sig-demo-ios-device-build-[[:alnum:]]+$ ||
      ! -d "$DESTINATION" || -L "$DESTINATION" || ! -O "$DESTINATION" ]]; then
  echo 'Invalid private device build directory.' >&2; exit 1
fi
for CHILD in RubyGems RubyGemArchives; do
  ITEM="$DESTINATION/$CHILD"
  if [[ -L "$ITEM" || ( -e "$ITEM" && ( ! -d "$ITEM" || ! -O "$ITEM" ) ) ]]; then
    echo 'Invalid private Ruby build cache; existing files were preserved.' >&2; exit 1
  fi
done
export GEM_HOME="$DESTINATION/RubyGems"
export GEM_PATH="$GEM_HOME"
if [[ -f "$GEM_HOME/specifications/xcodeproj-1.28.1.gemspec" ]] && ruby -e 'require "xcodeproj"' >/dev/null 2>&1; then exit 0; fi
python3 - "$WORKSPACE_DIR/.sig-demo/ios/ruby-gems/cache" "$DESTINATION/RubyGemArchives" <<'PY'
from pathlib import Path
import sys
source, destination = map(Path, sys.argv[1:])
destination.mkdir(exist_ok=True)
for name in ('CFPropertyList-3.0.8', 'atomos-0.1.3', 'base64-0.3.0', 'claide-1.1.0', 'colored2-3.1.2', 'nanaimo-0.4.0', 'nkf-0.3.0', 'rexml-3.4.4', 'xcodeproj-1.28.1'):
    path = source / (name + '.gem')
    data = path.read_bytes()
    if len(data) != path.stat().st_size or not data:
        raise SystemExit('An existing pinned Ruby build archive could not be read completely.')
    # Fresh writes avoid copying FileProvider eviction flags from the source.
    (destination / path.name).write_bytes(data)
PY
ruby -S gem install --local --ignore-dependencies --no-document --install-dir "$GEM_HOME" "$DESTINATION"/RubyGemArchives/*.gem
ruby -e 'require "xcodeproj"; abort "Unexpected xcodeproj version" unless Xcodeproj::VERSION == "1.28.1"'

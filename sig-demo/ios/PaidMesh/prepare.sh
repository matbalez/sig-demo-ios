#!/bin/sh
# Copyright 2026 Sig Demo contributors
# SPDX-License-Identifier: AGPL-3.0-only
set -eu

PAID_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
WORKSPACE_DIR=$(CDPATH= cd -- "$PAID_DIR/../../.." && pwd)
PROBE="$WORKSPACE_DIR/.sig-demo/ios/paid-mesh-probe"
REVISION=c7d5157384e072ad82c58916f4d3bcca50894f25
SHA256=2a71914b65693b047183f5ff116c25e5757668f5e75e3c25991de3f73ec7aa85
ARCHIVE="$PROBE/mesh-c7d5157.tar.gz"
PATCH="$PAID_DIR/Patches/0001-stable-paid-client-identity.patch"
PATCH_SHA256=d37708ea53635b0451f8b3e3a547814019a2757f1d1efe04dc258ec92749dbf6
PLUGIN_PATCH="$PAID_DIR/Patches/0002-in-process-payments-only.patch"
PLUGIN_PATCH_SHA256=93ca72be922a52af81429a9b2dcafbbd0d22db7ab52bed3e10c547c29af4b1bc
SHUTDOWN_PATCH="$PAID_DIR/Patches/0003-release-inference-bridge-on-shutdown.patch"
SHUTDOWN_PATCH_SHA256=301067eac52c6c4e2834c57e666a04b2d3012565ebcd6014f85a0488b605a9f3
OWNED_CLIENT_PATCH="$PAID_DIR/Patches/0004-isolate-caller-owned-client-identity.patch"
OWNED_CLIENT_PATCH_SHA256=de2b1c48cf42931eaeab927527e2ee62c8e2e35f092ea80cbb678465b3df45a1
mkdir -p "$PROBE"
if [ ! -f "$ARCHIVE" ]; then
  curl -fL --retry 2 "https://codeload.github.com/Mesh-LLM/mesh-llm/tar.gz/$REVISION" -o "$ARCHIVE.download"
  mv "$ARCHIVE.download" "$ARCHIVE"
fi
printf '%s  %s\n' "$SHA256" "$ARCHIVE" | shasum -a 256 -c -
STAGING=$(mktemp -d /private/tmp/sig-demo-paid-mesh-source-check.XXXXXX)
trap 'rm -rf "$STAGING"' EXIT HUP INT TERM
tar -xzf "$ARCHIVE" --strip-components=1 -C "$STAGING"
printf '%s  %s\n' "$PATCH_SHA256" "$PATCH" | shasum -a 256 -c -
patch -s -d "$STAGING" -p1 < "$PATCH"
printf '%s  %s\n' "$PLUGIN_PATCH_SHA256" "$PLUGIN_PATCH" | shasum -a 256 -c -
patch -s -d "$STAGING" -p1 < "$PLUGIN_PATCH"
printf '%s  %s\n' "$SHUTDOWN_PATCH_SHA256" "$SHUTDOWN_PATCH" | shasum -a 256 -c -
patch -s -d "$STAGING" -p1 < "$SHUTDOWN_PATCH"
printf '%s  %s\n' "$OWNED_CLIENT_PATCH_SHA256" "$OWNED_CLIENT_PATCH" | shasum -a 256 -c -
patch -s -d "$STAGING" -p1 < "$OWNED_CLIENT_PATCH"
if [ -n "${PAID_MESH_SOURCE_CACHE:-}" ]; then
  # A build-only public-source cache. No runtime wallet or home path changes.
  python3 - "$PAID_MESH_SOURCE_CACHE" "$PROBE/source" "$STAGING" <<'PYTHON'
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import uuid

cache, consumer, staging = map(Path, sys.argv[1:])
if (not cache.is_absolute() or cache.parent != Path("/private/tmp")
        or not cache.name.startswith("sig-demo-paid-mesh-source-")
        or any(ord(c) < 32 for c in str(cache))
        or cache.resolve() != cache):
    raise SystemExit("Source override must be an ordinary /private/tmp/sig-demo-paid-mesh-source-* directory")
try:
    cache.mkdir(mode=0o700)
except FileExistsError:
    pass
info = cache.lstat()
if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid()
        or info.st_mode & 0o022):
    raise SystemExit("Source cache must be owned by this user and not writable by others")
identity = (info.st_dev, info.st_ino)
# Open the protected owner-only directory before inspecting/populating it.
fd = os.open(cache, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
try:
    if not any(cache.iterdir()):
        shutil.copytree(staging, cache, dirs_exist_ok=True, symlinks=True)
    subprocess.run(["diff", "-qr", str(staging), str(cache)], check=True)
    current = cache.lstat()
    if ((current.st_dev, current.st_ino) != identity
            or (os.fstat(fd).st_dev, os.fstat(fd).st_ino) != identity):
        raise SystemExit("Source cache changed during verification")
    parent = consumer.parent.stat()
    if parent.st_uid != os.getuid() or parent.st_mode & 0o022:
        raise SystemExit("Consumer source parent is not privately owned")
    if os.path.lexists(consumer):
        old = consumer.lstat()
        if old.st_uid != os.getuid():
            raise SystemExit("Consumer source path is not owned by this user")
        if consumer.is_symlink() and os.readlink(consumer) == str(cache):
            print("Verified private public-source cache: " + str(cache))
            raise SystemExit(0)
        if not consumer.is_symlink():
            # Preserve an evicted/dataless cache without trying to read it.
            consumer.rename(consumer.with_name("source.previous." + uuid.uuid4().hex))
    link = consumer.with_name("source.link." + uuid.uuid4().hex)
    try:
        os.symlink(str(cache), link)
        os.replace(link, consumer)
    finally:
        if os.path.lexists(link):
            link.unlink()
    print("Verified private public-source cache: " + str(cache))
finally:
    os.close(fd)
PYTHON
elif [ -d "$PROBE/source" ]; then
  # Verify the consumed source, not only its archive. Never overwrite edits.
  diff -qr "$STAGING" "$PROBE/source"
elif [ -L "$PROBE/source" ]; then
  printf '%s\n' 'Public source cache is unavailable; set PAID_MESH_SOURCE_CACHE to a fresh owned private/tmp cache.' >&2
  exit 1
else
  mv "$STAGING" "$PROBE/source"
fi
printf '%s\n' "Pinned paid Mesh source verified: $REVISION"

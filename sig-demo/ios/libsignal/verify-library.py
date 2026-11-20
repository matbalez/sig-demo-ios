#!/usr/bin/env python3
"""Verify the private C export and every native object's deployment minimum."""

import argparse
from pathlib import Path
import re
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("library", type=Path)
    parser.add_argument("--maximum-minimum", default="16.0")
    parser.add_argument("--platform", choices=["ios", "ios-simulator", "macos"])
    args = parser.parse_args()
    library = args.library.resolve()
    if not library.is_file() or library.stat().st_size == 0:
        raise SystemExit("The native static library does not exist")
    # Apple's nm can fail on unrelated Rust LLVM bitcode members while correctly
    # reading the native bridge object. Its required native export is the check.
    symbols = subprocess.run(["xcrun", "nm", "-g", str(library)], capture_output=True, text=True)
    if not re.search(r"^\S+ T _signal_connection_manager_new_local_demo$", symbols.stdout, re.MULTILINE):
        raise SystemExit("The private constructor is missing from the static library")
    metadata = subprocess.run(["xcrun", "otool", "-l", str(library)], capture_output=True, text=True, check=True)
    versions = re.findall(r"^\s*minos ([0-9.]+)$", metadata.stdout, re.MULTILINE)
    if not versions:
        raise SystemExit("The static library has no native deployment declarations")
    platforms = set(re.findall(r"^\s*platform (\S+)$", metadata.stdout, re.MULTILINE))
    expected = {"ios": "2", "ios-simulator": "7", "macos": "1"}.get(args.platform)
    if expected and platforms != {expected}:
        raise SystemExit("Unexpected native platforms: " + ", ".join(sorted(platforms)))
    normalize = lambda value: tuple(int(part) for part in (value.split(".") + ["0", "0"])[:3])
    maximum = normalize(args.maximum_minimum)
    unsupported = sorted({version for version in versions if normalize(version) > maximum})
    if unsupported:
        print("Native objects exceed the iOS " + args.maximum_minimum + " minimum: " + ", ".join(unsupported), file=sys.stderr)
        raise SystemExit(2)
    print("Verified private export and " + str(len(versions)) + " native objects; minima " + ", ".join(sorted(set(versions))))


if __name__ == "__main__":
    main()

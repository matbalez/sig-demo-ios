#!/usr/bin/env python3
"""Prepare the pinned public libsignal fork without touching app state or keys."""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def run(args, cwd=None, **kwargs):
    return subprocess.run(args, cwd=cwd, check=True, text=True, **kwargs)


def main():
    here = Path(__file__).resolve().parent
    root = here.parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=root / ".sig-demo/ios/libsignal")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    source = args.source.resolve()
    pin = json.loads((here / "source.lock.json").read_text())
    if not source.exists():
        if args.check:
            raise SystemExit("The private libsignal source has not been prepared.")
        source.parent.mkdir(parents=True, exist_ok=True)
        run(["git", "clone", "--depth", "1", "--branch", pin["tag"], pin["repository"], str(source)])
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip()
    if head != pin["commit"]:
        raise SystemExit("The libsignal checkout has a different source pin. Existing files were preserved.")
    changed = subprocess.check_output(["git", "diff", "--name-only", "HEAD"], cwd=source, text=True).splitlines()
    untracked = subprocess.check_output(["git", "ls-files", "--others", "--exclude-standard"], cwd=source, text=True).splitlines()
    if any(name not in pin["patchedFilesSHA256"] for name in changed + untracked):
        raise SystemExit("The libsignal checkout contains unreviewed edits. Existing files were preserved.")

    def matches():
        return all((source / name).is_file() and
                   hashlib.sha256((source / name).read_bytes()).hexdigest() == digest
                   for name, digest in pin["patchedFilesSHA256"].items())

    if not matches():
        if args.check:
            raise SystemExit("The libsignal patch or generated header differs from the reviewed files.")
        changes = subprocess.check_output(["git", "status", "--porcelain", "--untracked-files=all"], cwd=source, text=True)
        if changes:
            raise SystemExit("The libsignal checkout has other edits. Existing files were preserved.")
        patch = here / pin["patch"]
        run(["git", "apply", "--check", str(patch)], cwd=source)
        run(["git", "apply", str(patch)], cwd=source)
        if not matches():
            raise SystemExit("The prepared libsignal files failed their recorded hashes.")
    print(f"Verified private libsignal {pin['tag']} ({head}) at {source}")


if __name__ == "__main__":
    main()

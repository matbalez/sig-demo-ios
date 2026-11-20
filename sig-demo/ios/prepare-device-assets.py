#!/usr/bin/env python3
"""Recreate unchanged pinned public asset catalogs outside FileProvider storage."""

import hashlib
import io
import json
import os
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path, PurePosixPath


def git(checkout, *args):
    return subprocess.check_output(["git", "-C", str(checkout), *args])


def main():
    ios, checkout, build = (Path(value).resolve() for value in sys.argv[1:4])
    catalogs = sys.argv[4:]
    if not catalogs or build.parent != Path("/private/tmp") or not build.name.startswith("sig-demo-ios-device-build-") or build.stat().st_uid != os.getuid():
        raise ValueError("Invalid private asset staging directory")
    for name in catalogs:
        path = PurePosixPath(name)
        if path.is_absolute() or ".." in path.parts or path.suffix != ".xcassets":
            raise ValueError("Unexpected public asset catalog path")
    commit = json.loads((ios / "upstream.lock.json").read_text())["commit"]
    if git(checkout, "rev-parse", "HEAD").decode().strip() != commit:
        raise ValueError("The public asset source does not match the pinned checkout")
    if git(checkout, "status", "--porcelain", "--untracked-files=all", "--", *catalogs):
        raise ValueError("Asset catalogs contain local changes; source files were preserved")
    indexed = {}
    for entry in git(checkout, "ls-tree", "-rz", commit, "--", *catalogs).split(b"\0"):
        if not entry:
            continue
        metadata, path = entry.split(b"\t", 1)
        mode, kind, oid = metadata.decode().split()
        if kind != "blob" or mode not in ("100644", "100755"):
            raise ValueError("Unexpected asset tree member")
        indexed[path.decode()] = oid
    if not indexed:
        raise ValueError("Pinned public asset catalogs are empty")
    destination = Path(tempfile.mkdtemp(prefix="AssetCatalogs-", dir=build))
    archive = git(checkout, "archive", "--format=tar", commit, "--", *catalogs)
    written = {}
    with tarfile.open(fileobj=io.BytesIO(archive), mode="r:") as source:
        for member in source:
            relative = PurePosixPath(member.name)
            if relative.is_absolute() or ".." in relative.parts:
                raise ValueError("Unexpected asset archive path")
            if member.isdir():
                continue
            if not member.isfile() or member.name not in indexed:
                raise ValueError("Unexpected asset archive member")
            stream = source.extractfile(member)
            if stream is None:
                raise ValueError("Missing asset archive contents")
            data = stream.read()
            blob = b"blob " + str(len(data)).encode() + b"\0" + data
            if len(data) != member.size or hashlib.sha1(blob).hexdigest() != indexed[member.name]:
                raise ValueError("The asset bytes differ from their pinned Git blob")
            output = destination / member.name
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_bytes(data)
            output.chmod(0o644)
            written[member.name] = hashlib.sha256(data).hexdigest()
    if written.keys() != indexed.keys():
        raise ValueError("The asset archive is incomplete")
    receipt = {"commit": commit, "catalogs": catalogs, "files": written,
               "purpose": "Unchanged pinned public asset bytes staged outside FileProvider; original source preserved"}
    (destination / "asset-staging-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(destination)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Fetch and verify the immutable upstream SDK; no model, identity or wallet I/O."""

import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def fetch(path, url, checksum):
    if path.exists():
        if digest(path) != checksum:
            raise SystemExit(f"Checksum mismatch: {path.name}")
        return
    temporary = path.with_suffix(path.suffix + ".download")
    try:
        with urllib.request.urlopen(url, timeout=60) as response, temporary.open("wb") as output:
            shutil.copyfileobj(response, output)
        if digest(temporary) != checksum:
            raise SystemExit(f"Checksum mismatch: {path.name}")
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def framework_plists(pin):
    result = []
    for platform in pin["platforms"]:
        framework = Path(platform) / "MeshLLMFFI.framework"
        if platform == "macos-arm64":
            result.append(framework / "Versions/A/Resources/Info.plist")
        else:
            result.append(framework / "Info.plist")
    return result


def verify_metadata_copy(original, derived, pin):
    patched = set(framework_plists(pin))
    expected_paths = {path.relative_to(original) for path in original.rglob("*")}
    actual_paths = {path.relative_to(derived) for path in derived.rglob("*")}
    if expected_paths != actual_paths:
        raise SystemExit("Derived framework layout differs from the original")
    for relative in expected_paths:
        source, destination = original / relative, derived / relative
        if source.is_symlink():
            if not destination.is_symlink() or os.readlink(source) != os.readlink(destination):
                raise SystemExit(f"Derived framework symlink differs: {relative}")
        elif source.is_file():
            if relative in patched:
                before = plistlib.loads(source.read_bytes())
                after = plistlib.loads(destination.read_bytes())
                if after != {**before, **pin["metadataPatch"]["set"]}:
                    raise SystemExit(f"Unexpected framework metadata change: {relative}")
            elif digest(source) != digest(destination):
                raise SystemExit(f"Derived framework payload differs: {relative}")


def prepare_metadata_copy(original, cache, pin):
    parent = cache / "derived-metadata-v2"
    derived = parent / original.name
    if not derived.exists():
        with tempfile.TemporaryDirectory(dir=cache, prefix="metadata-") as temporary:
            staging = Path(temporary) / original.name
            # APFS clones preserve every payload byte without another multi-GB
            # physical copy. Fall back to an ordinary symlink-preserving copy.
            result = subprocess.run(["/bin/cp", "-cR", str(original), str(staging)],
                                    capture_output=True, text=True)
            if result.returncode:
                if staging.exists():
                    shutil.rmtree(staging)
                shutil.copytree(original, staging, symlinks=True)
            for relative in framework_plists(pin):
                path = staging / relative
                metadata = plistlib.loads(path.read_bytes())
                if metadata.get("CFBundleName") != "MeshLLMFFI" or metadata.get("CFBundlePackageType") != "FMWK":
                    raise SystemExit(f"Unexpected framework wrapper: {relative}")
                metadata.update(pin["metadataPatch"]["set"])
                path.write_bytes(plistlib.dumps(metadata, fmt=plistlib.FMT_XML, sort_keys=True))
            verify_metadata_copy(original, staging, pin)
            parent.mkdir(exist_ok=True)
            shutil.move(str(staging), derived)
    else:
        verify_metadata_copy(original, derived, pin)
    return derived


def main():
    directory = Path(__file__).resolve().parent
    root = directory.parents[2]
    pin = json.loads((directory / "source.lock.json").read_text())
    cache = root / ".sig-demo/ios/mesh-public-probe"
    cache.mkdir(parents=True, exist_ok=True)
    source = root / ".sig-demo/mesh-research/source-v0.78.1.tar.gz"
    if not source.exists():
        source = cache / "source-v0.78.1.tar.gz"
    binary = cache / "MeshLLMFFI-v0.78.1.xcframework.zip"
    fetch(source, pin["sourceURL"], pin["sourceSHA256"])
    fetch(binary, pin["artifactURL"], pin["artifactSHA256"])
    artifact = cache / "artifact/MeshLLMFFI.xcframework"
    if not artifact.exists():
        with tempfile.TemporaryDirectory(dir=cache, prefix="artifact-") as temporary:
            subprocess.run(["unzip", "-q", str(binary), "-d", temporary], check=True)
            artifact.parent.mkdir(exist_ok=True)
            shutil.move(str(Path(temporary) / artifact.name), artifact)
    derived = prepare_metadata_copy(artifact, cache, pin)
    target = root / ".sig-demo/ios/mesh-sdk-v0.78.1"
    if not target.exists():
        with tempfile.TemporaryDirectory(dir=cache, prefix="source-") as temporary:
            with tarfile.open(source) as archive:
                archive.extractall(temporary, filter="data")
            children = list(Path(temporary).iterdir())
            if len(children) != 1 or not (children[0] / "Package.swift").is_file():
                raise SystemExit("Unexpected source archive layout")
            shutil.move(str(children[0]), target)
    framework = target / "sdk/swift/Generated/MeshLLMFFI.xcframework"
    framework.parent.mkdir(parents=True, exist_ok=True)
    allowed = {artifact.resolve(), derived.resolve()}
    previous = cache / "derived-metadata-v1" / artifact.name
    if framework.is_symlink() and framework.resolve() == previous.resolve():
        previous_pin = {**pin, "metadataPatch": {"set": {"CFBundleExecutable": "MeshLLMFFI"}}}
        verify_metadata_copy(artifact, previous, previous_pin)
        allowed.add(previous.resolve())
    if framework.exists() and (not framework.is_symlink() or framework.resolve() not in allowed):
        raise SystemExit("SDK framework points outside the verified artifact cache")
    if framework.is_symlink() and framework.resolve() != derived.resolve():
        framework.unlink()
    if not framework.exists():
        framework.symlink_to(os.path.relpath(derived, framework.parent), target_is_directory=True)
    print(f"Verified MeshLLM {pin['version']} source and metadata-only framework copy: {target}")


if __name__ == "__main__":
    main()

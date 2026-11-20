#!/usr/bin/env python3
# Copyright 2026 Sig Demo contributors
# SPDX-License-Identifier: AGPL-3.0-only
"""Prepare one iPhone app's Mesh package before Xcode generates its framework stub."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile


def version(value):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", value):
        raise ValueError("Invalid iOS deployment version")
    fields = [int(n) for n in value.split(".")]
    return tuple((fields + [0, 0])[:3])


def clone_file(source, destination):
    # Preserve identical large archives cheaply on APFS. Other filesystems can
    # use the ordinary verified copy.
    result = subprocess.run(["/bin/cp", "-c", source, destination], capture_output=True)
    if result.returncode:
        shutil.copy2(source, destination)
    return destination


def stage(mesh, sdk, parent, deployment, pin):
    if version(deployment) < version(pin["minimumIOSVersion"]):
        raise ValueError("The deployment target is below the pinned Mesh SDK minimum")
    sdk_name = "mesh-sdk-v" + pin["version"]
    if sdk.name != sdk_name:
        raise ValueError("Expected the pinned Mesh SDK directory")
    xc_path = Path("sdk/swift/Generated/MeshLLMFFI.xcframework")
    metadata = plistlib.loads((sdk / xc_path / "Info.plist").read_bytes())
    device, = [lib for lib in metadata["AvailableLibraries"] if lib["LibraryIdentifier"] == "ios-arm64"]
    if (device["SupportedPlatform"] != "ios" or device.get("SupportedPlatformVariant") or
            device["SupportedArchitectures"] != ["arm64"] or device["LibraryPath"] != "MeshLLMFFI.framework"):
        raise ValueError("The arm64 slice is not the expected iPhone framework")
    relative = Path("ios-arm64/MeshLLMFFI.framework")
    wrapper = sdk / xc_path / relative
    info = plistlib.loads((wrapper / "Info.plist").read_bytes())
    if (info.get("CFBundleExecutable") != "MeshLLMFFI" or info.get("CFBundleIdentifier") != "ai.meshllm.MeshLLMFFI" or
            version(info.get("MinimumOSVersion")) != version(pin["minimumIOSVersion"])):
        raise ValueError("Unexpected metadata in the qualified Mesh input")
    archive = wrapper / info["CFBundleExecutable"]
    with archive.open("rb") as f:
        if f.read(8) != b"!<arch>\n":
            raise ValueError("Only the pinned static Mesh framework gets an Xcode-generated stub")

    parent.mkdir(exist_ok=True)
    out = Path(tempfile.mkdtemp(prefix="DeviceMesh-", dir=parent))
    try:
        out_mesh = out / "Mesh"
        out_sdk = out / sdk_name
        for src, dest in [(mesh, out_mesh), (sdk / "sdk/swift", out_sdk / "sdk/swift")]:
            dest.mkdir(parents=True)
            shutil.copytree(src / "Sources", dest / "Sources")
            # SwiftPM requires the test target's source path to exist when
            # loading the package. The iPhone app builds only library targets.
            (dest / "Tests").symlink_to((src / "Tests").resolve(strict=True), target_is_directory=True)
        shutil.copy2(sdk / "Package.swift", out_sdk / "Package.swift")
        manifest = (mesh / "Package.swift").read_text()
        path = re.compile(r'(\.package\(path: ")((?:\.\./\.\./\.\./\.sig-demo/ios/|\.\./)' + re.escape(sdk_name) + r')("\))')
        rendered, count = path.subn(r'\g<1>../' + sdk_name + r'\g<3>', manifest)
        if count != 1:
            raise ValueError("Unexpected Mesh SDK dependency declaration")
        (out_mesh / "Package.swift").write_text(rendered)
        dest_xc = out_sdk / xc_path
        dest_wrapper = dest_xc / relative
        dest_wrapper.parent.mkdir(parents=True)
        shutil.copytree(wrapper, dest_wrapper, copy_function=clone_file)
        binary = dest_wrapper / info["CFBundleExecutable"]
        with binary.open("rb") as f:
            if hashlib.file_digest(f, "sha256").hexdigest() != pin["deviceStaticArchiveSHA256"]:
                raise ValueError("Device static library differs from the pinned Mesh binary")
        (dest_xc / "Info.plist").write_bytes(plistlib.dumps({**metadata, "AvailableLibraries": [device]}))
        # Xcode builds a new arm64 stub at the application's deployment target.
        # The upstream static archive remains byte-identical.
        (dest_wrapper / "Info.plist").write_bytes(plistlib.dumps({**info, "MinimumOSVersion": deployment}))
        return out_mesh
    except BaseException:
        shutil.rmtree(out)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("mesh", "sdk", "parent"):
        parser.add_argument("--" + name, required=True, type=Path)
    parser.add_argument("--deployment", required=True)
    args = parser.parse_args()
    pin = json.loads(Path(__file__).with_name("source.lock.json").read_text())
    print(stage(args.mesh, args.sdk, args.parent, args.deployment, pin))


if __name__ == "__main__":
    main()

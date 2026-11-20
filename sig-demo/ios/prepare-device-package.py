#!/usr/bin/env python3
"""Stage owned PaidMesh packaging with its truthful required-reason manifest."""

import hashlib
import json
import os
import plistlib
import shutil
import sys
import tempfile
from pathlib import Path


def main():
    ios, build = map(lambda v: Path(v).resolve(), sys.argv[1:])
    if not build.name.startswith("sig-demo-ios-device-build-") or build.parent != Path("/private/tmp") or build.stat().st_uid != os.getuid():
        raise SystemExit("Invalid private device package directory")
    packages = build / "Packages"
    if packages.is_symlink() or (packages.exists() and not packages.is_dir()):
        raise SystemExit("Invalid owned package staging path")
    packages.mkdir(exist_ok=True)
    destination = Path(tempfile.mkdtemp(prefix="PaidMesh-", dir=packages))
    original = ios / "PaidMesh"
    receipts = []

    def copy_file(source, target):
        data = Path(source).read_bytes()
        if len(data) != Path(source).stat().st_size:
            raise ValueError("Incomplete public release package input")
        Path(target).write_bytes(data)
        Path(target).chmod(Path(source).stat().st_mode & 0o777)
        return target

    shutil.copytree(original / "Sources", destination / "Sources", copy_function=copy_file)
    artifact = "SigDemoPaidMeshFFI.xcframework"
    shutil.copytree(original / "Artifacts" / artifact, destination / "Artifacts" / artifact, copy_function=copy_file)
    manifest = {"NSPrivacyAccessedAPITypes": [{
        "NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryFileTimestamp",
        "NSPrivacyAccessedAPITypeReasons": ["C617.1"],
    }]}
    manifest_data = plistlib.dumps(manifest)
    for framework in sorted((destination / "Artifacts" / artifact).glob("*/*.framework")):
        relative = framework.relative_to(destination)
        info = plistlib.loads((framework / "Info.plist").read_bytes())
        executable = info["CFBundleExecutable"]
        source = original / relative / executable
        target = framework / executable
        original_hash = hashlib.sha256(source.read_bytes()).hexdigest()
        copied_hash = hashlib.sha256(target.read_bytes()).hexdigest()
        if original_hash != copied_hash:
            raise ValueError("The staged paid binary differs from its qualified input")
        (framework / "PrivacyInfo.xcprivacy").write_bytes(manifest_data)
        receipts.append({"binary": str(relative / executable), "qualifiedInputSha256": original_hash, "stagedBinarySha256": copied_hash})
    if not receipts:
        raise ValueError("No qualified paid framework slices were staged")
    package = (original / "Package.swift").read_text()
    expected = '.package(path: "../Mesh")'
    if package.count(expected) != 1:
        raise ValueError("Unexpected paid package dependency shape")
    package = package.replace(expected, ".package(path: " + json.dumps(str(ios / "Mesh")) + ")")
    (destination / "Package.swift").write_text(package)
    receipt = {"purpose": "Release-only SDK privacy packaging for app-owned wallet, ledger and profile file metadata; no data-collection assertion", "reason": "C617.1", "manifestSha256": hashlib.sha256(manifest_data).hexdigest(), "binaryBytesUnchangedBeforeSigning": receipts}
    (destination / "release-packaging-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(destination)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Validate the actual private iPhone archive without reading user data or keys."""

import argparse
import hashlib
import json
import plistlib
import re
import subprocess
from pathlib import Path


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


def os_version(value):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", value):
        raise ValueError(f"Invalid iPhone minimum OS version: {value!r}")
    fields = [int(n) for n in value.split(".")]
    return tuple((fields + [0, 0])[:3])


def inspect_binary(binary, maximum_minimum, bundle_minimum):
    architectures = run("xcrun", "lipo", "-archs", str(binary)).split()
    if architectures != ["arm64"]:
        raise ValueError(f"Unexpected device architectures: {binary.name}")
    metadata = run("xcrun", "otool", "-l", str(binary))
    platforms = re.findall(r"^\s*platform (\S+)$", metadata, re.MULTILINE)
    legacy_ios = "LC_VERSION_MIN_IPHONEOS" in metadata
    if platforms not in (["2"], ["IOS"]) and not (not platforms and legacy_ios):
        raise ValueError(f"Non-iPhone payload in archive: {binary.name}")
    # Only native build-version minima matter; LC_SOURCE_VERSION also has a
    # version field and must not be interpreted as an OS deployment minimum.
    minimum_match = re.search(r"LC_BUILD_VERSION\n(?:[^\n]*\n){0,4}?\s*minos ([0-9.]+)", metadata)
    if not minimum_match:
        minimum_match = re.search(r"LC_VERSION_MIN_IPHONEOS\n(?:[^\n]*\n){0,2}?\s*version ([0-9.]+)", metadata)
    if not minimum_match:
        raise ValueError(f"Missing device deployment declaration: {binary.name}")
    native = os_version(minimum_match[1])
    declared = os_version(bundle_minimum)
    if native > declared:
        raise ValueError(f"{binary.name}: Mach-O minimum iOS {minimum_match[1]} exceeds bundle MinimumOSVersion {bundle_minimum}")
    if declared > (maximum_minimum, 0, 0):
        raise ValueError(f"{binary.name}: bundle minimum iOS {bundle_minimum} exceeds the app minimum {maximum_minimum}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build-number", required=True)
    parser.add_argument("--require-signed", action="store_true")
    parser.add_argument("--require-source", action="store_true")
    parser.add_argument("--team")
    args = parser.parse_args()
    archive = args.archive.resolve()
    app = archive / "Products/Applications/Signal.app"
    if not app.is_dir():
        raise ValueError("The archive does not contain its native iPhone app")
    minimum_ios = 16
    models = app / "LocalModels"
    if models.exists():
        marker = json.loads((models / "SigDemoLocalModelDevice.json").read_text())
        if marker != {"schemaVersion": 1, "engine": "goose-local-inference", "backend": "metal",
                      "inProcess": True, "debugOnly": False, "gpuRequired": True}:
            raise ValueError("Invalid Release local inference configuration")
        pins = json.loads((Path(__file__).parent / "LocalModel/source.lock.json").read_text())["models"]
        model, = pins
        weights, = models.glob("*.gguf")
        if weights.name != model["filename"] or weights.stat().st_size != model["bytes"]:
            raise ValueError("Unexpected bundled local model")
        with weights.open("rb") as stream:
            if hashlib.file_digest(stream, "sha256").hexdigest() != model["sha256"]:
                raise ValueError("Bundled local model checksum differs from its source lock")
        if not (models / "LFM-Open-License.txt").is_file():
            raise ValueError("Missing bundled local model license")
        minimum_ios = 17
    expected = {
        app: "dev.matbalez.sig-demo.ios.signal",
        app / "PlugIns/SignalNSE.appex": "dev.matbalez.sig-demo.ios.signal.SignalNSE",
        app / "PlugIns/SignalShareExtension.appex": "dev.matbalez.sig-demo.ios.signal.shareextension",
    }
    for bundle, identifier in expected.items():
        info = plistlib.loads((bundle / "Info.plist").read_bytes())
        if info.get("CFBundleIdentifier") != identifier:
            raise ValueError(f"Unexpected private bundle identity: {bundle.name}")
        if info.get("CFBundleShortVersionString") != args.version or info.get("CFBundleVersion") != args.build_number:
            raise ValueError(f"Mismatched release version: {bundle.name}")
        if info.get("MinimumOSVersion") != f"{minimum_ios}.0" or info.get("CFBundleSupportedPlatforms") != ["iPhoneOS"]:
            raise ValueError(f"Unexpected device deployment metadata: {bundle.name}")
        if not (bundle / "PrivacyInfo.xcprivacy").is_file():
            raise ValueError(f"Missing privacy manifest: {bundle.name}")
        if args.require_signed:
            signed = subprocess.run(["codesign", "-d", "--entitlements", ":-", str(bundle)], check=True, capture_output=True).stdout
            entitlements = plistlib.loads(signed)
            if args.team and entitlements.get("com.apple.developer.team-identifier") != args.team:
                raise ValueError(f"Unexpected signing team: {bundle.name}")
            if entitlements.get("com.apple.security.hardened-process") is not True:
                raise ValueError(f"Enhanced security entitlement was not retained: {bundle.name}")
            groups = entitlements.get("com.apple.security.application-groups", [])
            if set(groups) != {"group.dev.matbalez.sig-demo.ios.signal.group", "group.dev.matbalez.sig-demo.ios.signal.group.staging"}:
                raise ValueError(f"Unexpected shared storage entitlement: {bundle.name}")
            if any(key in entitlements for key in ("aps-environment", "com.apple.developer.icloud-container-identifiers", "com.apple.developer.pushkit.unrestricted-voip")):
                raise ValueError(f"Unexpected upstream service entitlement: {bundle.name}")
            access = entitlements.get("keychain-access-groups", [])
            if len(access) != 1 or not access[0].endswith(".dev.matbalez.sig-demo.ios.signal"):
                raise ValueError(f"Unexpected private Keychain entitlement: {bundle.name}")
    bundles = list(expected) + sorted(app.rglob("*.framework"))
    for bundle in bundles:
        info = plistlib.loads((bundle / "Info.plist").read_bytes())
        inspect_binary(bundle / info["CFBundleExecutable"], minimum_ios, info.get("MinimumOSVersion"))
        if args.require_signed:
            run("codesign", "--verify", "--strict", str(bundle))
    app_info = plistlib.loads((app / "Info.plist").read_bytes())
    source_name = app_info.get("SigDemoSourceArchive")
    source_sha256 = app_info.get("SigDemoSourceSHA256")
    if args.require_source or source_name is not None or source_sha256 is not None:
        if source_name != "SigDemoSource.tar.gz" or not isinstance(source_sha256, str) or not re.fullmatch(r"[a-f0-9]{64}", source_sha256):
            raise ValueError("Missing or malformed corresponding source metadata")
        resource = app / source_name
        if resource.is_symlink() or not resource.is_file():
            raise ValueError("Missing bundled corresponding source archive")
        digest = hashlib.sha256()
        with resource.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
        if digest.hexdigest() != source_sha256:
            raise ValueError("The bundled corresponding source SHA256 does not match")
    icon = app_info.get("CFBundleIcons", {})
    if icon.get("CFBundlePrimaryIcon", {}).get("CFBundleIconName") != "SigDemoAppIcon":
        raise ValueError("The release archive is missing its distinct demo app icon")
    paid = app / "Frameworks/SigDemoPaidMeshFFI.framework/SigDemoPaidMeshFFI"
    privacy = plistlib.loads((paid.parent / "PrivacyInfo.xcprivacy").read_bytes())
    if not any(item.get("NSPrivacyAccessedAPIType") == "NSPrivacyAccessedAPICategoryFileTimestamp" and "C617.1" in item.get("NSPrivacyAccessedAPITypeReasons", []) for item in privacy.get("NSPrivacyAccessedAPITypes", [])):
        raise ValueError("The owned paid SDK file metadata declaration is missing")
    symbols = run("xcrun", "nm", "-gjU", str(paid)).splitlines()
    if set(symbols) != {"_sig_demo_paid_mesh_" + name for name in ("create", "call", "cancel", "free", "string_free")}:
        raise ValueError("The paid native library exposes unexpected symbols")
    print(f"Verified private iPhone release: three matching bundles, {len(bundles)} arm64 iOS executables, demo icon, privacy manifests, and isolated paid exports.")
    print("Signed archive verification passed." if args.require_signed else "Unsigned device archive validated; signing, export and App Store validation remain separate.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"Device archive validation failed: {error}")

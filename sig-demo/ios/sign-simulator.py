#!/usr/bin/env python3
"""Verify/export an Xcode ad hoc signed, isolated iOS Simulator application.

Xcode must package iOS capabilities into simulated Mach-O entitlement sections
and sign with its separate host entitlements. This helper never re-signs code.
Use --stage to export a verified copy outside a synced workspace, or --check to
validate and print the plan without writing files or changing signatures.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import struct
import subprocess
import sys
import tempfile

REPO_ROOT = Path(__file__).resolve().parents[2]
BUILD_ROOT = REPO_ROOT / ".sig-demo/ios/chatgpt/Build"
LEGACY_DEFAULT_APP = BUILD_ROOT / "Products/Debug-iphonesimulator/Signal.app"
PRODUCTS_POINTER = BUILD_ROOT / "products-directory.txt"
SIMULATOR_APP_MANIFEST = BUILD_ROOT / "simulator-app.json"
STAGING_PARENT = Path("/private/tmp")
STAGING_PREFIX = "sig-demo-ios-simulator-"
APP_ID = "dev.matbalez.sig-demo.ios.signal"
GROUPS = [f"group.{APP_ID}.group", f"group.{APP_ID}.group.staging"]
EXTENSIONS = {
    "SignalNSE.appex": f"{APP_ID}.SignalNSE",
    "SignalShareExtension.appex": f"{APP_ID}.shareextension",
}
CODESIGN = "/usr/bin/codesign"


class SigningError(Exception):
    pass


@dataclass(frozen=True)
class Bundle:
    path: Path
    identifier: str
    executable: Path


@dataclass(frozen=True)
class Plan:
    app: Bundle
    extensions: tuple[Bundle, ...]
    libraries: tuple[Path, ...]


def run(args: list[str]) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(args, capture_output=True, text=True, check=False)
    if result.returncode:
        raise SigningError(f"{shlex.join(args)} failed:\n{result.stderr.strip()}")
    return result


def contained(path: Path, app: Path) -> Path:
    resolved = path.resolve(strict=True)
    if not resolved.is_relative_to(app):
        raise SigningError(f"Embedded path escapes the application bundle: {path}")
    return resolved


def read_bundle(path: Path, app: Path, expected_id: str | None = None) -> Bundle:
    contained(path, app)
    info_path = contained(path / "Info.plist", app)
    with info_path.open("rb") as stream:
        info = plistlib.load(stream)
    if expected_id is not None:
        if info.get("CFBundleIdentifier") != expected_id:
            raise SigningError(f"Unexpected application identity in {path}")
        if info.get("CFBundleSupportedPlatforms") != ["iPhoneSimulator"]:
            raise SigningError(f"Only iPhoneSimulator bundles may be exported: {path}")
    executable_name = info.get("CFBundleExecutable")
    if not isinstance(executable_name, str) or Path(executable_name).name != executable_name:
        raise SigningError(f"Missing or unsafe CFBundleExecutable in {path}")
    executable = contained(path / executable_name, app)
    if not executable.is_file():
        raise SigningError(f"Missing executable in {path}")
    return Bundle(path, info.get("CFBundleIdentifier", ""), executable)


def validate_simulator_binary(path: Path) -> None:
    output = run(["/usr/bin/xcrun", "vtool", "-show-build", str(path)]).stdout
    platforms = re.findall(r"^\s*platform\s+(\S+)\s*$", output, re.MULTILINE)
    if not platforms or any(platform != "IOSSIMULATOR" for platform in platforms):
        raise SigningError(f"Only simulator Mach-O slices may be exported: {path}")


def read_simulated_sections(binary: Path) -> dict[str, bytes]:
    """Read public entitlement data, without changing or executing the Mach-O.

    The native build is deliberately thin arm64. Libraries may be universal;
    only app/extension executables require these simulator payload sections.
    """
    size = binary.stat().st_size
    with binary.open("rb") as stream:
        header = stream.read(32)
        if len(header) != 32:
            raise SigningError(f"Truncated Mach-O header: {binary}")
        magic, cpu, _, _, count, commands_size, _, _ = struct.unpack("<IIIIIIII", header)
        if magic != 0xFEEDFACF or cpu != 0x0100000C:
            raise SigningError(f"Expected the native build's thin arm64 executable: {binary}")
        end = 32 + commands_size
        if count > 8192 or end > size:
            raise SigningError(f"Invalid Mach-O load commands: {binary}")
        cursor = 32
        sections: dict[str, bytes] = {}
        for _ in range(count):
            stream.seek(cursor)
            command_header = stream.read(8)
            if len(command_header) != 8:
                raise SigningError(f"Truncated Mach-O load command: {binary}")
            command, command_size = struct.unpack("<II", command_header)
            if command_size < 8 or cursor + command_size > end:
                raise SigningError(f"Invalid Mach-O load command size: {binary}")
            if command == 0x19:  # LC_SEGMENT_64
                stream.seek(cursor)
                data = stream.read(command_size)
                if len(data) < 72:
                    raise SigningError(f"Truncated Mach-O segment: {binary}")
                section_count = struct.unpack_from("<I", data, 64)[0]
                if 72 + section_count * 80 > command_size:
                    raise SigningError(f"Invalid Mach-O section count: {binary}")
                for index in range(section_count):
                    offset = 72 + index * 80
                    name = data[offset:offset + 16].split(b"\0", 1)[0]
                    segment = data[offset + 16:offset + 32].split(b"\0", 1)[0]
                    if segment != b"__TEXT" or name not in (b"__entitlements", b"__ents_der"):
                        continue
                    payload_size = struct.unpack_from("<Q", data, offset + 40)[0]
                    payload_offset = struct.unpack_from("<I", data, offset + 48)[0]
                    if not payload_size or payload_size > 1024 * 1024 or payload_offset + payload_size > size:
                        raise SigningError(f"Invalid simulated entitlement section: {binary}")
                    stream.seek(payload_offset)
                    sections[name.decode("ascii")] = stream.read(payload_size)
            cursor += command_size
    return sections


def verify_xcode_entitlements(bundle: Bundle) -> str:
    sections = read_simulated_sections(bundle.executable)
    if not {"__entitlements", "__ents_der"} <= sections.keys():
        raise SigningError(
            f"Missing Xcode simulator entitlement sections in {bundle.path}; rebuild with "
            "CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- and normal simulator packaging."
        )
    simulated = plistlib.loads(sections["__entitlements"].rstrip(b"\0"))
    if not isinstance(simulated, dict):
        raise SigningError(f"Malformed embedded simulator entitlement payload: {bundle.path}")
    # Standard Xcode teamless simulator packaging uses its literal FAKETEAMID
    # placeholder. Accept only that or the empty prefix, never a real team ID.
    prefix = next((prefix for prefix in ("", "FAKETEAMID.")
                   if simulated.get("application-identifier") == prefix + bundle.identifier), None)
    expected = {
        "application-identifier": (prefix or "") + bundle.identifier,
        "keychain-access-groups": [(prefix or "") + APP_ID],
        "com.apple.security.application-groups": GROUPS,
    }
    if prefix is None or any(simulated.get(key) != value for key, value in expected.items()):
        raise SigningError(f"Embedded simulator identities differ from the isolated app plan: {bundle.path}")
    for key in ("com.apple.developer.associated-domains", "com.apple.developer.icloud-container-identifiers"):
        if key in simulated and simulated[key] != []:
            raise SigningError(f"Unexpected cloud/link capability in isolated simulator payload: {bundle.path}")
    metadata = run([CODESIGN, "--display", "--verbose=4", str(bundle.path)]).stderr
    if "Signature=adhoc" not in metadata:
        raise SigningError(f"Expected Xcode's ad hoc simulator signature: {bundle.path}")
    output = run([CODESIGN, "--display", "--entitlements", "-", "--xml", str(bundle.path)]).stdout
    host = plistlib.loads(output.encode("utf-8")) if output.strip() else {}
    if not isinstance(host, dict) or any(key in host for key in (*expected, "get-task-allow")):
        raise SigningError(f"iOS simulated capabilities must not replace Xcode's host entitlements: {bundle.path}")
    # Xcode's host com.apple.security.get-task-allow and any enhanced-security
    # protections remain intact. Never synthesize, weaken, or re-sign them here.
    return prefix


def prepare_plan(app_path: Path) -> Plan:
    app_path = app_path.expanduser().resolve(strict=True)
    if not app_path.is_dir() or app_path.suffix != ".app":
        raise SigningError("--app must identify a completed simulator .app bundle")
    app = read_bundle(app_path, app_path, APP_ID)
    expected_paths = {app_path / "PlugIns" / name for name in EXTENSIONS}
    if set(app_path.rglob("*.appex")) != expected_paths:
        raise SigningError("Expected exactly the isolated SignalNSE and SignalShareExtension plug-ins")
    if any(path != app_path for path in app_path.rglob("*.app")):
        raise SigningError("Unexpected nested application bundle")
    extensions = tuple(read_bundle(app_path / "PlugIns" / name, app_path, identifier) for name, identifier in EXTENSIONS.items())
    framework_paths = tuple(app_path.rglob("*.framework"))
    frameworks = tuple(read_bundle(path, app_path) for path in framework_paths)
    dylibs = tuple(app_path.rglob("*.dylib"))
    for path in dylibs:
        contained(path, app_path)
    for bundle in (app, *extensions, *frameworks):
        validate_simulator_binary(bundle.executable)
    for path in dylibs:
        validate_simulator_binary(path)
    prefixes = {verify_xcode_entitlements(bundle) for bundle in (app, *extensions)}
    if len(prefixes) != 1:
        raise SigningError("The app and extensions must share Xcode's same simulator keychain prefix")
    run([CODESIGN, "--verify", "--deep", "--strict", "--verbose=2", str(app_path)])
    if BUILD_ROOT.resolve() != BUILD_ROOT:
        raise SigningError("The ignored receipt output directory must not be a symlink")
    libraries = tuple(sorted((*framework_paths, *dylibs), key=lambda path: (-len(path.parts), str(path))))
    return Plan(app, extensions, libraries)


def default_app() -> Path:
    if not PRODUCTS_POINTER.exists():
        return LEGACY_DEFAULT_APP
    products = Path(PRODUCTS_POINTER.read_text().strip())
    if not products.is_absolute() or products.parent.parent != STAGING_PARENT or not products.parent.name.startswith("sig-demo-ios-simulator-build-") or products.name != "Products":
        raise SigningError("Invalid ignored simulator products-directory pointer; use --app explicitly")
    if products.resolve() != products:
        raise SigningError("Simulator products-directory pointer must not traverse symlinks")
    return products / "Debug-iphonesimulator/Signal.app"


def stage(source: Plan) -> Plan:
    directory = Path(tempfile.mkdtemp(prefix=STAGING_PREFIX, dir=STAGING_PARENT))
    os.chmod(directory, 0o700)
    app = directory / "Signal.app"
    print(f"Staging verified Xcode simulator build at {app}", flush=True)
    run(["/usr/bin/ditto", "--norsrc", "--noextattr", str(source.app.path), str(app)])
    # Copy data/modes and preserve Xcode's existing signatures. Validate every
    # private identity, embedded payload and sealed resource again after copying.
    return prepare_plan(app)


def write_simulator_app_manifest(plan: Plan, source: Plan) -> None:
    manifest = {
        "schemaVersion": 1,
        "appPath": str(plan.app.path),
        "sourceAppPath": str(source.app.path),
        "bundleIdentifier": plan.app.identifier,
        "extensionBundleIdentifiers": [bundle.identifier for bundle in plan.extensions],
        "appGroupIdentifiers": GROUPS,
        "platform": "iPhoneSimulator",
        "signingIdentity": "xcode-ad-hoc",
        "verification": "embedded-simulator-identities-and-host-signatures",
        "createdAt": datetime.now(timezone.utc).isoformat(),
    }
    BUILD_ROOT.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", prefix=".simulator-app-", suffix=".json.tmp", dir=BUILD_ROOT, delete=False) as stream:
        json.dump(manifest, stream, indent=2)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
        temporary_path = stream.name
    os.replace(temporary_path, SIMULATOR_APP_MANIFEST)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, help="completed Xcode-signed simulator Signal.app (default: current products-directory pointer)")
    parser.add_argument("--check", action="store_true", help="validate and print plan without any mutation")
    parser.add_argument("--stage", action="store_true", help="export a signature-preserving copy to a fresh private /private/tmp directory")
    args = parser.parse_args()
    try:
        source = prepare_plan(args.app if args.app is not None else default_app())
        print("Verified Xcode ad hoc host signatures, embedded isolated simulator identities, and sealed resources.")
        if args.check:
            if args.stage:
                placeholder = STAGING_PARENT / f"{STAGING_PREFIX}<generated>" / "Signal.app"
                print(shlex.join(["/usr/bin/ditto", "--norsrc", "--noextattr", str(source.app.path), str(placeholder)]))
                print("Would verify the copied app again, preserving all Xcode signatures and enhanced-security entitlements.")
            print(f"Would atomically update {SIMULATOR_APP_MANIFEST} after verification; no changes made.")
        else:
            plan = stage(source) if args.stage else source
            write_simulator_app_manifest(plan, source)
            print(str(plan.app.path))
    except (SigningError, OSError, ValueError, plistlib.InvalidFileException, struct.error) as error:
        print(f"Simulator export stopped: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

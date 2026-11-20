#!/usr/bin/env python3
"""Overlay the reviewed private Swift/C bridge into an explicit local Pod."""

import argparse
from pathlib import Path
import shlex
import stat
import subprocess


def main():
    here = Path(__file__).resolve().parent
    root = here.parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=root / ".sig-demo/ios/libsignal")
    parser.add_argument("--pod", type=Path, required=True)
    parser.add_argument("--target", choices=["aarch64-apple-ios", "aarch64-apple-ios-sim"], default="aarch64-apple-ios-sim")
    parser.add_argument("--profile", choices=["debug", "release"], default="debug")
    args = parser.parse_args()
    source, pod = args.source.resolve(), args.pod.resolve()
    subprocess.run(["python3", str(here / "prepare.py"), "--source", str(source), "--check"], check=True)
    if not (pod / "swift/Sources/LibSignalClient/Net.swift").is_file():
        raise SystemExit("Select the actual LibSignalClient Pod source directory.")
    files = [
        "swift/Sources/LibSignalClient/Net.swift",
        "swift/Sources/LibSignalClient/KeyTransparency.swift",
        "swift/Sources/LibSignalClient/SecureValueRecoveryBackup.swift",
        "swift/Sources/SignalFfi/signal_ffi.h",
    ]
    for relative in files:
        destination = pod / relative
        destination.chmod(destination.stat().st_mode | stat.S_IWUSR)
        destination.write_bytes((source / relative).read_bytes())
    # CocoaPods uses this file's existence to select local-build mode instead
    # of downloading/extracting an official archive without the private symbol.
    marker = pod / "swift/build_ffi.sh"
    marker.write_text(
        "#!/bin/sh\n# Private sig demo native source-build hook.\nexec bash "
        + shlex.quote(str(here / "build.sh"))
        + ' "${CARGO_BUILD_TARGET:-' + args.target + '}" ' + args.profile + "\n"
    )
    marker.chmod(0o755)
    library = root / ".sig-demo/ios/libsignal-build" / args.target / args.profile / "libsignal_ffi.a"
    print("Pod bridge overlaid; stock native download is disabled.")
    print("Pass this setting to xcodebuild:")
    print("LIBSIGNAL_FFI_LIB_TO_LINK=" + str(library))


if __name__ == "__main__":
    main()

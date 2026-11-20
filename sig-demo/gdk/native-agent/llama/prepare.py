#!/usr/bin/env python3
"""Materialize the pinned Goose provider and its Apple llama.cpp compatibility patches."""
import fcntl
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

HERE = Path(__file__).resolve().parent
WORKSPACE = HERE.parents[3]
CACHE = Path(os.environ.get("SIG_DEMO_LLAMA_SOURCE_CACHE", WORKSPACE / ".sig-demo/ios/llama-sources"))
VENDOR = HERE.parents[1] / "native/vendor"
COMMIT = "cd959bae99ff4bed22bef2604f45241c09bbb8c8"
CRATES = {
    "goose-local-inference-0.1.0-alpha.12": ("goose-local-inference", "a17b360274477d6ed121f8c417cac05811080c9457b0662525a13e3e225f9f41"),
    "llama-cpp-2-0.1.146": ("llama-cpp-2", "f3b0f368c76cc0fe475e8257aeeec269e0d6569bd48b1f503efd0963fc3ee397"),
    "llama-cpp-sys-2-0.1.146": ("llama-cpp-sys-2", "9b291e4bc2d10c43cd8dec16d49b6104cb3cb125f596ec380a753a5db1d965dd"),
}


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def artifact(name, url, expected):
    path = CACHE / name
    if not path.exists() or digest(path) != expected:
        with tempfile.NamedTemporaryFile(dir=CACHE, delete=False) as tmp:
            temp = Path(tmp.name)
            try:
                with urllib.request.urlopen(url) as response:
                    shutil.copyfileobj(response, tmp)
                tmp.flush()
                if digest(temp) != expected:
                    raise ValueError(f"Unexpected checksum for {name}")
                os.replace(temp, path)
            finally:
                temp.unlink(missing_ok=True)
    return path


def unpack(archive, stage, top, skip_llama=False):
    with tarfile.open(archive) as bundle:
        for member in bundle:
            parts = Path(member.name).parts
            if not parts or parts[0] != top:
                raise ValueError(f"Unexpected archive root {member.name}")
            if skip_llama and len(parts) > 1 and parts[1] == "llama.cpp":
                continue
            bundle.extract(member, stage, filter="data")


def prepare():
    VENDOR.mkdir(parents=True, exist_ok=True)
    llvm_hash = "fbe74146a3cdc00f706773eb233bc4aedb7d8c3c7e2122440e492a99c1ec5a76"
    top = "llama.cpp-" + COMMIT
    llama = CACHE / top
    if not (llama / ".sig-source-ready").exists():
        source = artifact(top + ".tar.gz", "https://codeload.github.com/ggml-org/llama.cpp/tar.gz/" + COMMIT, llvm_hash)
        with tempfile.TemporaryDirectory(dir=CACHE) as temp:
            unpack(source, temp, top)
            (Path(temp) / top / ".sig-source-ready").write_text(llvm_hash)
            os.replace(Path(temp) / top, llama)
    for name, (crate, checksum) in CRATES.items():
        patch = HERE / "patches" / (name + ".patch")
        target = VENDOR / name
        stamp = checksum + " " + digest(patch) + " " + COMMIT
        marker = target / ".sig-source-ready"
        if marker.exists() and marker.read_text() == stamp:
            continue
        path = artifact(name + ".crate", f"https://static.crates.io/crates/{crate}/{name}.crate", checksum)
        with tempfile.TemporaryDirectory(dir=VENDOR) as temp:
            unpack(path, temp, name, skip_llama=True)
            prepared = Path(temp) / name
            subprocess.run(["patch", "-p1", "-i", str(patch)], cwd=prepared, check=True)
            if crate == "llama-cpp-sys-2":
                (prepared / "llama.cpp").symlink_to(llama, target_is_directory=True)
            (prepared / ".sig-source-ready").write_text(stamp)
            if target.exists():
                if not marker.exists():
                    raise ValueError(f"Unrecognized vendor directory {target}")
                os.replace(target, Path(temp) / "previous")
            os.replace(prepared, target)


if __name__ == "__main__":
    CACHE.mkdir(parents=True, exist_ok=True)
    with (CACHE / "prepare.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        prepare()

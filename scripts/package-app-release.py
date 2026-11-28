#!/usr/bin/env python3
"""Validate and package one built Untitled.app and its release checksum."""

import argparse
import hashlib
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True)


def package(app, output, preview):
    app = app.resolve(strict=True)
    if app.name != "Untitled.app" or not app.is_dir():
        raise ValueError("Expected a built Untitled.app")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    version = info.get("CFBundleShortVersionString", "")
    build = info.get("CFBundleVersion", "")
    if (info.get("CFBundleIdentifier") != "com.untitled.app" or info.get("CFBundleExecutable") != "Untitled"
            or not isinstance(version, str) or not isinstance(build, str)
            or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version) or not re.fullmatch(r"[0-9]+", build)):
        raise ValueError("Invalid bundle identity, version or build number")

    run("/usr/bin/codesign", "--verify", "--deep", "--strict", app)
    signature = run("/usr/bin/codesign", "-dv", "--verbose=4", app).stderr.splitlines()
    developer_id = any(line.startswith("Authority=Developer ID Application:") for line in signature)
    if not preview:
        if not developer_id or not any(line.startswith("CodeDirectory ") and "(runtime)" in line for line in signature):
            raise ValueError("A formal release requires a Hardened Runtime Developer ID signature")
        run("/usr/bin/xcrun", "stapler", "validate", app)

    architectures = set(run("/usr/bin/lipo", "-archs", app / "Contents/MacOS/Untitled").stdout.split())
    if not architectures or not architectures <= {"arm64", "x86_64"}:
        raise ValueError("Unsupported application architecture")
    architecture = "universal" if len(architectures) == 2 else next(iter(architectures))
    name = f"Untitled-macOS-{architecture}-v{version}.zip"

    if output.exists() or output.is_symlink():
        raise ValueError("Choose a new output directory to preserve existing packages")
    output = output.resolve()
    if output.is_relative_to(app):
        raise ValueError("Choose an output directory outside the application bundle")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".untitled-release-", dir=output.parent) as temporary:
        stage = Path(temporary)
        archive = stage / name
        run("/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, archive)
        digest = hashlib.sha256()
        with archive.open("rb") as file:
            for block in iter(lambda: file.read(1024 * 1024), b""):
                digest.update(block)
        (stage / "SHA256SUMS.txt").write_text(f"{digest.hexdigest()}  {name}\n", encoding="utf-8")
        stage.rename(output)
    print(f"Untitled {version} ({build}), {architecture}, {'preview' if preview else 'notarized release'}")
    print(output / name)
    print(output / "SHA256SUMS.txt")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True, help="New directory for the application ZIP and SHA-256")
    parser.add_argument("--preview", action="store_true", help="Package an explicitly selected preview channel")
    arguments = parser.parse_args()
    try:
        package(arguments.app, arguments.output, arguments.preview)
    except (OSError, ValueError, plistlib.InvalidFileException, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Cannot package Untitled: {error}\n")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Build reproducible declarative ZIP plugins and their GitHub catalog."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import zipfile
import base64
import struct

DEFAULT_REPOSITORY = "tietiezhi-1216/untitled"


def read_plugin(directory, root):
    source = directory / "manifest.json"
    manifest_data = source.read_bytes()
    manifest = json.loads(manifest_data)
    if len(manifest_data) > 256 * 1024:
        raise ValueError(f"manifest exceeds 256 KiB: {source}")
    if not re.fullmatch(r"[a-z0-9]+([.-][a-z0-9]+)+", manifest["id"]):
        raise ValueError(f"invalid plugin id: {source}")
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", manifest["version"]):
        raise ValueError(f"invalid plugin version: {source}")
    if not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", directory.name):
        raise ValueError(f"plugin directory must use a lowercase slug: {directory}")
    license_file = directory / "LICENSE"
    if not license_file.is_file():
        if directory.is_relative_to(root / "Plugins"):
            license_file = root / "LICENSE"
        else:
            raise ValueError(f"independent plugins must include their own LICENSE: {directory}")
    contents = {
        "manifest.json": manifest_data,
        "README.md": (directory / "README.md").read_bytes(),
        "LICENSE": license_file.read_bytes(),
    }
    if len(contents["README.md"]) > 128 * 1024:
        raise ValueError(f"README exceeds 128 KiB: {directory}")
    contents["README.md"].decode("utf-8")
    if icon := manifest.get("icon"):
        if not re.fullmatch(r"[a-zA-Z0-9.]{1,80}", icon["symbol"]) or not re.fullmatch(r"#[0-9A-Fa-f]{6}", icon["tint"]):
            raise ValueError(f"invalid icon symbol or tint: {source}")
        if "png" in icon:
            png = base64.b64decode(icon["png"], validate=True)
            if len(png) < 24 or len(png) > 64 * 1024 or not png.startswith(b"\x89PNG\r\n\x1a\n"):
                raise ValueError(f"invalid PNG artwork: {source}")
            width, height = struct.unpack(">II", png[16:24])
            if width != height or not 32 <= width <= 256:
                raise ValueError(f"PNG must be square and 32–256 pixels: {source}")
    if storefront := manifest.get("storefront"):
        if tuple(map(int, manifest["minimumHostVersion"].split("."))) < (0, 12, 0):
            raise ValueError(f"storefront requires host 0.12.0+: {source}")
        if not 1 <= len(storefront["category"]) <= 24 or not 1 <= len(storefront["headline"]) <= 60 or len(storefront["caption"]) > 120:
            raise ValueError(f"invalid storefront copy: {source}")
        if not re.fullmatch(r"[a-zA-Z0-9.]{1,80}", storefront["categorySymbol"]):
            raise ValueError(f"invalid category symbol: {source}")
        if "jpeg" in storefront:
            jpeg = base64.b64decode(storefront["jpeg"], validate=True)
            if len(jpeg) > 96 * 1024 or not jpeg.startswith(b"\xff\xd8\xff"):
                raise ValueError(f"storefront must be a JPEG at most 96 KiB: {source}")
    return manifest, contents


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True, help="GitHub release tag, for example v0.2.0")
    parser.add_argument("--plugin", action="append", help="Plugin slug or directory; repeat to select plugins")
    parser.add_argument("--repository", default=DEFAULT_REPOSITORY, help="Release destination as owner/repo")
    parser.add_argument("--output", type=Path, help="Output directory (default: dist/plugins)")
    parser.add_argument("--write-catalog", action="store_true")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9._-]+", args.tag) or args.tag in {".", ".."}:
        parser.error("invalid release tag")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*", args.repository):
        parser.error("repository must be owner/repo")
    if args.write_catalog and (args.plugin or args.repository != DEFAULT_REPOSITORY):
        parser.error("--write-catalog requires the complete central repository; selected builds write a local catalog only")
    root = Path(__file__).resolve().parent.parent
    if args.plugin:
        directories = []
        for value in args.plugin:
            candidate = Path(value).expanduser()
            if not candidate.is_dir():
                candidate = root / "Plugins" / value
            directories.append(candidate.resolve())
    else:
        directories = [source.parent for source in sorted((root / "Plugins").glob("*/manifest.json"))]
    try:
        plugins = [(directory, *read_plugin(directory, root)) for directory in directories]
        if not plugins or len({manifest["id"] for _, manifest, _ in plugins}) != len(plugins):
            raise ValueError("no plugins selected, or duplicate plugin ids")
        filenames = [f"{directory.name}-{manifest['version']}.zip" for directory, manifest, _ in plugins]
        if len(set(filenames)) != len(filenames):
            raise ValueError("selected plugins would produce duplicate archive filenames")
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.error(str(error))
    output = (args.output or root / "dist" / "plugins").resolve()
    output.mkdir(parents=True, exist_ok=True)
    entries = []
    for directory, manifest, contents in plugins:
        name = f"{directory.name}-{manifest['version']}.zip"
        archive = output / name
        with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as package:
            for filename, data in sorted(contents.items()):
                info = zipfile.ZipInfo(filename, date_time=(2026, 1, 1, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = 0o100644 << 16
                package.writestr(info, data)
        if archive.stat().st_size > 2 * 1024 * 1024:
            archive.unlink()
            parser.error(f"plugin exceeds 2 MiB: {name}")
        checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
        entry = {
            key: manifest[key] for key in ("id", "name", "version", "summary", "author")
        } | {
            "downloadURL": f"https://github.com/{args.repository}/releases/download/{args.tag}/{name}",
            "sha256": checksum,
        }
        if "icon" in manifest:
            entry["icon"] = manifest["icon"]
        if "storefront" in manifest:
            entry["storefront"] = manifest["storefront"]
        entries.append(entry)
        print(f"{checksum}  {archive}")
    catalog = {"schemaVersion": 1, "plugins": entries}
    text = json.dumps(catalog, ensure_ascii=False, indent=2) + "\n"
    (output / "catalog.json").write_text(text)
    if args.write_catalog:
        (root / "Plugins" / "catalog.json").write_text(text)


if __name__ == "__main__":
    main()

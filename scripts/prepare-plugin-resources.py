#!/usr/bin/env python3
"""Bundle display metadata without installing plugins or changing the online catalog."""
import argparse
import base64
import json
from pathlib import Path

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--embed-icons", action="store_true", help="Embed each local Icon.png in its manifest")
parser.add_argument("--embed-artwork", action="store_true", help="Embed local Icon.png and Preview.jpg in the manifest")
parser.add_argument("--check", action="store_true", help="Check committed resource freshness without writing")
args = parser.parse_args()
presentations = []
for source in sorted((root / "Plugins").glob("*/manifest.json")):
    manifest = json.loads(source.read_text())
    changed = False
    if (args.embed_icons or args.embed_artwork) and (icon_file := source.parent / "Icon.png").is_file():
        manifest["icon"]["png"] = base64.b64encode(icon_file.read_bytes()).decode()
        changed = True
    if args.embed_artwork and (preview_file := source.parent / "Preview.jpg").is_file():
        manifest["storefront"]["jpeg"] = base64.b64encode(preview_file.read_bytes()).decode()
        changed = True
    if changed:
        source.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    item = {key: manifest[key] for key in ("id", "repository", "version", "name", "summary", "icon", "storefront") if key in manifest}
    item["readmeURL"] = manifest["repository"].rstrip("/") + "/blob/main/" + source.parent.relative_to(root).as_posix() + "/README.md"
    # README is loaded from the exact installed/downloaded package, never replaced by a newer bundled version.
    presentations.append(item)
destination = root / "Sources/Untitled/Resources/BundledPlugins.json"
text = json.dumps(presentations, ensure_ascii=False, indent=2) + "\n"
if len(text.encode("utf-8")) > 1024 * 1024:
    raise SystemExit("Bundled plugin display metadata exceeds 1 MiB")
if args.check:
    if not destination.is_file() or destination.read_text() != text:
        raise SystemExit("Plugin display metadata is stale: run python3 scripts/prepare-plugin-resources.py")
else:
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(text)

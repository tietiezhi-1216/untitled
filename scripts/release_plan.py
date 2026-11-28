"""Determine which products a verified Untitled source commit can release."""

import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess


SHA = re.compile(r"[0-9a-f]{40}")
VERSION = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)")
SLUG = r"[a-z0-9]+(?:-[a-z0-9]+)*"
MANIFEST = re.compile(rf"Plugins/({SLUG})/manifest\.json")
PLUGIN_FILE = re.compile(rf"Plugins/({SLUG})/(manifest\.json|README\.md|LICENSE)")
HOST_BUILD_FILES = {
    "LICENSE", "Package.swift", "Package.resolved",
    "scripts/build-app.sh", "scripts/build-icon.sh",
    "scripts/build-sharing-microphone.sh", "scripts/build-webp-encoder.sh",
}


def command(*args, **kwargs):
    return subprocess.run(args, check=True, stdout=subprocess.PIPE, text=True, **kwargs).stdout.strip()


def version_number(version):
    if not isinstance(version, str) or not VERSION.fullmatch(version):
        raise ValueError(f"Expected a three-part version, got {version!r}")
    return tuple(map(int, version.split(".")))


def require_main(source):
    if not SHA.fullmatch(source) or source not in command(
        "git", "rev-list", "--first-parent", "origin/main"
    ).splitlines():
        raise ValueError("Release source must be an exact commit on protected origin/main")
    return source


def require_approved_source(source, tag=None):
    """Use the exact release source and products recorded in protected main."""
    if not SHA.fullmatch(source):
        raise ValueError("Use a full release source SHA")
    control = require_main(command("git", "rev-parse", "HEAD"))
    approvals = json.loads(command("git", "show", f"{control}:.github/approved-release-sources.json"))
    approval = approvals.get(source)
    if not approval:
        raise ValueError(f"Protected main has no release approval for {source}")
    tags = set(approval["tags"])
    if tag is not None and tag not in tags:
        raise ValueError(f"Protected main has not approved {tag} for source {source}")
    baseline = approval["baseline"]
    if not isinstance(baseline, str) or not baseline.startswith("v"):
        raise ValueError("Release approval requires a published host baseline tag")
    version_number(baseline[1:])
    command("git", "merge-base", "--is-ancestor", f"refs/tags/{baseline}^{{commit}}", source)
    return approval


def host_info(revision):
    info = plistlib.loads(command("git", "show", f"{revision}:Resources/Info.plist").encode())
    version = info["CFBundleShortVersionString"]
    build = info["CFBundleVersion"]
    version_number(version)
    if not re.fullmatch(r"[0-9]+", build):
        raise ValueError("Untitled needs an integer CFBundleVersion")
    return version, build


def host_path(path):
    if path == "Sources/Untitled/Resources/BundledPlugins.json" or path.startswith("Resources/StoreArtwork/"):
        # Independent ZIP updates regenerate presentation metadata for the next host.
        return False
    if re.fullmatch(rf"Plugins/{SLUG}/Sources/.+", path):
        return True
    return path in HOST_BUILD_FILES or path.startswith(
        ("Sources/", "Resources/", "Tools/", "Untitled.xcodeproj/")
    )


def manifests(revision):
    paths = command("git", "ls-tree", "-r", "--name-only", revision, "--", "Plugins").splitlines()
    return {match[1]: path for path in paths if (match := MANIFEST.fullmatch(path))}


def plan(source, base=None):
    if not SHA.fullmatch(source) or (base is not None and not SHA.fullmatch(base)):
        raise ValueError("Use full source and base commit SHAs")
    base = base or f"{source}^1"
    changed = set(command("git", "diff", "--no-renames", "--name-only", "-z", base, source).split("\0"))
    previous_host, previous_build = host_info(base)
    host_version, build = host_info(source)
    host = None
    if (host_version, build) != (previous_host, previous_build) or any(map(host_path, changed)):
        if version_number(host_version) <= version_number(previous_host) or int(build) <= int(previous_build):
            raise ValueError("Host changes must increase both the marketing version and build number")
        declaration = command("git", "grep", "-l", "-E", r"^(package |public )?enum HostInfo ", source, "--", "Sources")
        definitions = command("git", "show", declaration)
        runtime_version = re.search(r'^\s*(?:package |public )?static let version = "([^"]+)"', definitions, re.M)
        if runtime_version is None or runtime_version[1] != host_version:
            raise ValueError("HostInfo.version must match the marketing version in Resources/Info.plist")
        host = {"tag": f"v{host_version}", "version": host_version, "build": build}

    old_manifests, current_manifests = manifests(base), manifests(source)
    touched = {match[1] for path in changed if (match := PLUGIN_FILE.fullmatch(path))}
    if "LICENSE" in changed:
        paths = command("git", "ls-tree", "-r", "--name-only", source, "--", "Plugins").splitlines()
        touched.update(slug for slug in current_manifests if f"Plugins/{slug}/LICENSE" not in paths)

    plugins = []
    for slug in sorted(touched.intersection(current_manifests)):
        manifest = json.loads(command("git", "show", f"{source}:{current_manifests[slug]}"))
        version, minimum = manifest["version"], manifest["minimumHostVersion"]
        version_number(version)
        if version_number(minimum) > version_number(host_version):
            raise ValueError(f"{slug} requires host {minimum}, newer than this source's host {host_version}")
        if slug in old_manifests:
            previous = json.loads(command("git", "show", f"{base}:{old_manifests[slug]}"))
            if version_number(version) <= version_number(previous["version"]):
                raise ValueError(f"Changes to the {slug} ZIP require increasing its plugin version")
        plugins.append({"slug": slug, "tag": f"plugin-{slug}-v{version}", "minimum": minimum})
    return {"source": source, "host": host, "plugins": plugins}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True)
    parser.add_argument("--base", help="PR base for pre-merge validation")
    source_group = parser.add_mutually_exclusive_group()
    source_group.add_argument("--protected-main", action="store_true")
    source_group.add_argument("--approved-source", action="store_true",
                              help="Use an exact release source recorded in protected main")
    parser.add_argument("--actions", action="store_true", help="Export GitHub Actions job outputs")
    args = parser.parse_args()
    try:
        if args.protected_main:
            require_main(args.source)
            if args.base:
                require_main(args.base)
                command("git", "merge-base", "--is-ancestor", args.base, args.source)
        if args.approved_source and args.base is not None:
            raise ValueError("An approved release uses its own first parent as the base")
        approval = require_approved_source(args.source) if args.approved_source else None
        result = plan(args.source, args.base)
        if approval:
            tags = {item["tag"] for item in [result["host"], *result["plugins"]] if item}
            if tags != set(approval["tags"]):
                raise ValueError("The release plan does not match the tags approved in protected main")
        print(json.dumps(result, indent=2))
        if args.actions:
            with Path(os.environ["GITHUB_OUTPUT"]).open("a", encoding="utf-8") as output:
                print(f"source={result['source']}", file=output)
                print("source_policy=approved" if args.approved_source else "source_policy=main", file=output)
                print(f"host={json.dumps(result['host'])}", file=output)
                print(f"plugins={json.dumps(result['plugins'])}", file=output)
                print(f"has_products={str(bool(result['host'] or result['plugins'])).lower()}", file=output)
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Release plan failed: {error}\n")


if __name__ == "__main__":
    main()

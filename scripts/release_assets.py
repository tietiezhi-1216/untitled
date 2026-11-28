"""Publish or verify one separately versioned Untitled release."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import zipfile

from release_plan import SHA, SLUG, command, require_approved_source, require_main, version_number


TAG = re.compile(rf"(?:plugin-({SLUG})-)?v(\d+\.\d+\.\d+)")
SUMS = "SHA256SUMS.txt"


def release_list(repository):
    pages = json.loads(command("gh", "api", "--paginate", "--slurp",
                               f"repos/{repository}/releases?per_page=100"))
    return [release for page in pages for release in page]


def tag_source(tag):
    ref = f"refs/tags/{tag}"
    refs = dict(line.split("\t")[::-1] for line in command(
        "git", "ls-remote", "--tags", "origin", ref, ref + "^{}"
    ).splitlines())
    return refs.get(ref + "^{}", refs.get(ref))


def archive_pattern(slug, version):
    if slug:
        return re.compile(re.escape(f"{slug}-{version}.zip"))
    return re.compile(rf"Untitled-macOS-(?:arm64|x86_64|universal)-v{re.escape(version)}\.zip")


def published_hosts(releases):
    hosts = []
    for release in releases:
        match = TAG.fullmatch(release["tag_name"])
        if release["draft"] or not match or match[1]:
            continue
        version = match[2]
        if any(archive_pattern(None, version).fullmatch(asset["name"]) and asset["state"] == "uploaded"
               for asset in release["assets"]):
            hosts.append((version_number(version), release["tag_name"]))
    return hosts


def require_host_baseline(releases, source, version, adopted):
    latest = max(published_hosts(releases), default=None)
    if latest is None:
        return
    published, tag = latest
    if published >= version_number(version):
        raise ValueError(f"The published host is already at {tag}; increase the host version")
    baseline = tag_source(tag)
    if baseline and is_ancestor(baseline, source):
        return
    prefix, _, commit = adopted.partition(":")
    if prefix == tag and SHA.fullmatch(commit) and require_main(commit) and is_ancestor(commit, source):
        return
    raise ValueError(f"Host source does not contain the published baseline {tag}. "
                     "Integrate that release's features into main and record the reviewed baseline.")


def require_host_release_baseline(releases, source, version, adopted, channel, approval):
    if channel == "preview" and approval.get("allow_older_preview") is True:
        tag = approval["baseline"]
        baseline_releases = [release for release in releases if release["tag_name"] == tag]
        if not published_hosts(baseline_releases):
            raise ValueError(f"The approved historical baseline {tag} has no public host ZIP")
        require_host_baseline(baseline_releases, source, version, "")
        return
    require_host_baseline(releases, source, version, adopted)


def is_ancestor(ancestor, source):
    return subprocess.run(["git", "merge-base", "--is-ancestor", ancestor, source],
                          stderr=subprocess.DEVNULL).returncode == 0


def require_plugin_version(releases, slug, version):
    # Older releases may have included this plugin ZIP under a host tag.
    archive = re.compile(rf"{re.escape(slug)}-(\d+\.\d+\.\d+)\.zip")
    for release in releases:
        if release["draft"]:
            continue
        for asset in release["assets"]:
            match = archive.fullmatch(asset["name"])
            if match and asset["state"] == "uploaded" and version_number(match[1]) >= version_number(version):
                raise ValueError(f"{slug} {match[1]} is already public in {release['tag_name']}; increase the plugin version")


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for block in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def verify_files(archive, checksum, slug, version):
    digest = sha256(archive)
    if checksum.read_text(encoding="utf-8").splitlines() != [f"{digest}  {archive.name}"]:
        raise ValueError(f"SHA-256 mismatch for {archive.name}")
    if slug:
        if archive.stat().st_size > 2 * 1024 * 1024:
            raise ValueError(f"{archive.name} exceeds the plugin package size limit")
        with zipfile.ZipFile(archive) as plugin:
            if sorted(plugin.namelist()) != ["LICENSE", "README.md", "manifest.json"]:
                raise ValueError(f"Unexpected files in {archive.name}")
            if plugin.getinfo("manifest.json").file_size > 256 * 1024:
                raise ValueError(f"Manifest exceeds the plugin size limit in {archive.name}")
            if json.loads(plugin.read("manifest.json"))["version"] != version:
                raise ValueError(f"Manifest version does not match {archive.name}")
    return digest


def verify_public(repository, source, tag, release):
    if release is None or release["draft"] or not release["published_at"]:
        return None
    if tag_source(tag) != source:
        raise ValueError(f"Tag {tag} does not identify the expected source {source}")
    slug, version = TAG.fullmatch(tag).groups()
    assets = [asset["name"] for asset in release["assets"] if asset["state"] == "uploaded"]
    archives = [name for name in assets if archive_pattern(slug, version).fullmatch(name)]
    if len(archives) != 1 or sorted(assets) != sorted([archives[0], SUMS]):
        raise ValueError(f"Public release {tag} must contain its ZIP and {SUMS}")
    name = archives[0]
    with tempfile.TemporaryDirectory(prefix="untitled-release-verify-") as directory:
        archive = Path(directory) / name
        checksum = Path(directory) / SUMS
        for path in (archive, checksum):
            url = f"https://github.com/{repository}/releases/download/{tag}/{path.name}"
            command("curl", "--fail", "--silent", "--show-error", "--location", "--retry", "3",
                    "--proto", "=https", "--proto-redir", "=https", "--max-time", "600",
                    "--output", path, url)
        digest = verify_files(archive, checksum, slug, version)
    return {"tag": tag, "source": source, "url": release["html_url"], "asset": name, "sha256": digest}


def upload(repository, tag, path):
    command("gh", "release", "upload", tag, path, "--repo", repository)


def require_publish_source(source, tag, source_policy):
    if source_policy == "approved":
        return require_approved_source(source, tag)
    require_main(source)
    return {}


def publish(repository, source, tag, releases, release, directory, channel, minimum, adopted, source_policy="main"):
    approval = require_publish_source(source, tag, source_policy)
    slug, version = TAG.fullmatch(tag).groups()
    preview = not slug and channel == "preview"
    if release and release["prerelease"] != preview:
        raise ValueError(f"Release {tag} already exists in a different channel")
    if existing := verify_public(repository, source, tag, release):
        return existing
    if slug:
        latest_host = max(published_hosts(releases), default=None)
        if latest_host is None or latest_host[0] < version_number(minimum):
            raise ValueError(f"{tag} requires a publicly released Untitled {minimum} or later")
        require_plugin_version(releases, slug, version)
    else:
        require_host_release_baseline(releases, source, version, adopted, channel, approval)

    archives = [path for path in directory.glob("*.zip") if archive_pattern(slug, version).fullmatch(path.name)]
    if len(archives) != 1:
        raise ValueError(f"Expected one ZIP for {tag} in the packaging directory")
    archive = archives[0]
    marker = f"<!-- untitled-release:{source}:{tag} -->"
    if release and marker not in (release["body"] or "").splitlines():
        raise ValueError(f"Release {tag} is an existing draft from another publication")
    staged = {asset["name"]: asset["state"] for asset in release["assets"]} if release else {}
    if set(staged) - {archive.name, SUMS} or any(state != "uploaded" for state in staged.values()):
        raise ValueError(f"Draft {tag} has unexpected or incomplete uploads; inspect it before retrying")

    with tempfile.TemporaryDirectory(prefix="untitled-release-draft-") as directory_name:
        stage = Path(directory_name)
        checksum = stage / SUMS
        if archive.name in staged:
            # A signed rebuild has a fresh timestamp. Resume using the ZIP already
            # uploaded by this draft, keeping its bytes and corresponding checksum.
            command("gh", "release", "download", tag, "--repo", repository, "--dir", stage,
                    "--pattern", archive.name)
            archive = stage / archive.name
        if SUMS in staged:
            command("gh", "release", "download", tag, "--repo", repository, "--dir", stage, "--pattern", SUMS)
        elif not slug and not staged:
            checksum.write_bytes((directory / SUMS).read_bytes())
        else:
            checksum.write_text(f"{sha256(archive)}  {archive.name}\n", encoding="utf-8")
        verify_files(archive, checksum, slug, version)

        previous_tag = tag_source(tag)
        if previous_tag is None:
            command("gh", "api", "--method", "POST", f"repos/{repository}/git/refs",
                    "-f", f"ref=refs/tags/{tag}", "-f", f"sha={source}")
        elif previous_tag != source:
            raise ValueError(f"Existing {tag} points to {previous_tag}; tags are never replaced")

        if release is None:
            title = f"{slug} {version}" if slug else f"Untitled {version}" + (" Preview" if preview else "")
            if slug:
                description = f"声明式插件 ZIP。最低宿主版本为 Untitled {minimum}。"
            elif preview:
                description = "Developer ID 签名公开预览。未提交 Apple 公证。"
                if approval.get("allow_older_preview") is True:
                    description += " 此预览用于补发指定版本。"
            else:
                description = "Developer ID 签名正式版，已完成 Apple 公证。"
            notes = f"{description}\n\n源码提交：{source}\n\n{marker}"
            flags = ["--prerelease"] if preview else []
            command("gh", "release", "create", tag, "--repo", repository, "--draft", "--verify-tag",
                    "--latest=false", "--title", title, "--notes", notes, *flags)

        if archive.name not in staged:
            upload(repository, tag, archive)
        if SUMS not in staged:
            upload(repository, tag, checksum)
        command("gh", "release", "edit", tag, "--repo", repository, "--draft=false",
                "--latest=true" if not slug and not preview else "--latest=false")

    release = next((item for item in release_list(repository) if item["tag_name"] == tag), None)
    result = verify_public(repository, source, tag, release)
    if result is None:
        raise ValueError(f"GitHub did not return a public release for {tag}; retry verification")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("check-host", "publish", "verify"))
    parser.add_argument("--repo", required=True)
    parser.add_argument("--source", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--directory", type=Path)
    parser.add_argument("--channel", choices=("preview", "stable"), default="preview")
    parser.add_argument("--minimum")
    parser.add_argument("--source-policy", choices=("main", "approved"), default="main")
    args = parser.parse_args()
    try:
        if not re.fullmatch(r"[\w.-]+/[\w.-]+", args.repo) or not SHA.fullmatch(args.source):
            raise ValueError("Use a GitHub owner/repository and a full commit SHA")
        match = TAG.fullmatch(args.tag)
        if not match:
            raise ValueError("Use v<version> for the host or plugin-<slug>-v<version> for a plugin")
        slug, version = match.groups()
        version_number(version)
        releases = release_list(args.repo)
        release = next((item for item in releases if item["tag_name"] == args.tag), None)
        adopted = os.environ.get("UNTITLED_ADOPTED_HOST_BASELINE", "")
        if args.mode == "check-host":
            if slug:
                raise ValueError("Use a host tag for this check")
            approval = require_publish_source(args.source, args.tag, args.source_policy)
            if release and not release["draft"]:
                if tag_source(args.tag) != args.source or release["prerelease"] != (args.channel == "preview"):
                    raise ValueError("Published host tag has a different source or channel")
            else:
                require_host_release_baseline(releases, args.source, version, adopted, args.channel, approval)
            return
        if args.mode == "publish":
            if args.directory is None or (slug and not args.minimum):
                raise ValueError("Specify the package directory and the plugin minimum host version")
            result = publish(args.repo, args.source, args.tag, releases, release, args.directory,
                             args.channel, args.minimum, adopted, args.source_policy)
        else:
            result = verify_public(args.repo, args.source, args.tag, release)
        if result is None:
            parser.exit(3, f"Waiting for a public release of {args.tag}\n")
        print(json.dumps(result))
    except (OSError, ValueError, KeyError, zipfile.BadZipFile, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Release {args.tag} failed: {error}\n")


if __name__ == "__main__":
    main()

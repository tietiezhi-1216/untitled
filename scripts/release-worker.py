#!/usr/bin/env python3
"""Verify a manually approved main commit and prepare a signed macOS preview."""

import argparse
import base64
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
from typing import NamedTuple
from urllib.parse import urlencode

SOURCE = "tietiezhi-1216/untitled"
BRANCH = "main"
CI_PATH = ".github/workflows/ci.yml"
BUNDLE_ID = "com.untitled.app"
DEVELOPER_ID = (
    f'identifier "{BUNDLE_ID}" and anchor apple generic '
    'and certificate 1[field.1.2.840.113635.100.6.2.6] exists '
    'and certificate leaf[field.1.2.840.113635.100.6.1.13] exists'
)


class ReleaseError(Exception):
    pass


class Version(NamedTuple):
    name: str
    build: int


class Approval(NamedTuple):
    commit: str
    run: int
    attempt: int
    version: Version


def run(*args, **kwargs):
    subprocess.run(args, check=True, **kwargs)


def output(*args, **kwargs):
    return subprocess.check_output(args, text=True, **kwargs).strip()


def github(path, **query):
    endpoint = path + ("?" + urlencode(query) if query else "")
    return json.loads(output("gh", "api", "--hostname", "github.com", endpoint))


def version_of(plist):
    if not isinstance(plist, dict) or plist.get("CFBundleIdentifier") != BUNDLE_ID or plist.get("CFBundleExecutable") != "Untitled":
        raise ReleaseError("预期 Untitled 的应用标识与可执行文件。")
    name = plist.get("CFBundleShortVersionString", "")
    build = plist.get("CFBundleVersion", "")
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", str(name)) or not re.fullmatch(r"[1-9][0-9]*", str(build)):
        raise ReleaseError("应用版本必须是三段数字，构建号必须是正整数。")
    return Version(str(name), int(build))


def bundle_version(app):
    return version_of(plistlib.loads((app / "Contents/Info.plist").read_bytes()))


def verify_commit(commit):
    if not re.fullmatch(r"[a-f0-9]{40}", commit):
        raise ReleaseError("请明确指定人工审阅通过的完整 40 位提交 SHA。")
    base = f"repos/{SOURCE}"
    branch = github(f"{base}/branches/{BRANCH}")
    if branch.get("protected") is not True:
        raise ReleaseError("main 未受保护，拒绝签发。")
    tip = branch["commit"]["sha"]
    if tip != commit:
        comparison = github(f"{base}/compare/{commit}...{tip}", per_page=1)
        if comparison.get("status") != "ahead" or comparison["merge_base_commit"]["sha"] != commit:
            raise ReleaseError("指定提交不在受保护的 main 历史中。")

    runs = github(f"{base}/actions/workflows/ci.yml/runs", branch=BRANCH, head_sha=commit)["workflow_runs"]
    eligible = [
        r for r in runs
        if r.get("path") == CI_PATH and r.get("head_branch") == BRANCH and r.get("head_sha") == commit
        and r.get("event") in {"push", "workflow_dispatch"}
        and (r.get("head_repository") or {}).get("full_name") == SOURCE
    ]
    if not eligible:
        raise ReleaseError("找不到针对这个提交的 main 分支 macOS CI 运行。")
    ci = max(eligible, key=lambda r: r["id"])
    if ci.get("status") != "completed" or ci.get("conclusion") != "success":
        raise ReleaseError("该提交最新的 main CI 尚未通过。")
    jobs = github(f"{base}/actions/runs/{ci['id']}/attempts/{ci['run_attempt']}/jobs", per_page=100)["jobs"]
    if not any(j.get("name") == "verify" and j.get("status") == "completed" and j.get("conclusion") == "success"
               for j in jobs):
        raise ReleaseError("该 CI 尝试没有成功执行 verify 任务。")
    info = github(f"{base}/contents/Resources/Info.plist", ref=commit)
    if info.get("type") != "file" or info.get("encoding") != "base64":
        raise ReleaseError("无法读取指定提交的应用版本。")
    version = version_of(plistlib.loads(base64.b64decode(info["content"])))
    return Approval(commit, ci["id"], ci["run_attempt"], version)


def require_upgrade(version, reference):
    def numeric(name):
        return tuple(map(int, name.split(".")))

    if version.build <= reference.build or numeric(version.name) < numeric(reference.name):
        raise ReleaseError(f"候选 {version.name} / build {version.build} 不高于参考版 "
                           f"{reference.name} / build {reference.build}，拒绝覆盖。")


def designated_requirement(app, fingerprint=None):
    requirement = DEVELOPER_ID
    if fingerprint:
        requirement += f' and certificate leaf = H"{fingerprint}"'
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", app)
    run("/usr/bin/codesign", "--verify", "--strict", "-R=" + requirement, app)
    details = output("/usr/bin/codesign", "--display", "-r-", app, stderr=subprocess.STDOUT)
    designated = [line for line in details.splitlines() if line.startswith("designated => ")]
    if len(designated) != 1:
        raise ReleaseError("无法读取应用的签名指定要求。")
    return designated[0]


def require_same_identity(app, fingerprint, reference):
    if designated_requirement(app, fingerprint) != reference:
        raise ReleaseError("签名指定要求与参考版不同；为保留系统授权，拒绝签发。")


def build_environment():
    # GitHub/API and notarization credentials are not build-step environment variables.
    return {k: os.environ[k] for k in ("HOME", "PATH", "TMPDIR", "LANG", "LC_ALL", "DEVELOPER_DIR") if k in os.environ}


def fetch_source(commit, checkout):
    env = dict(build_environment(), GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null", GIT_TERMINAL_PROMPT="0")
    for key in ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY"):
        for name in (key, key.lower()):
            if name in os.environ:
                env[name] = os.environ[name]
    checkout.mkdir(mode=0o700)
    git = ("/usr/bin/git", "-C", checkout, "-c", "core.hooksPath=/dev/null")
    run(*git, "init", "--quiet", "--template=", env=env)
    # Membership in protected main has already been checked via GitHub. Only fetch that immutable tree.
    run(*git, "-c", "http.lowSpeedLimit=1024", "-c", "http.lowSpeedTime=30", "fetch", "--quiet", "--depth=1", "--no-tags",
        f"https://github.com/{SOURCE}.git", commit, env=env, timeout=900)
    run(*git, "checkout", "--quiet", "--detach", commit, env=env)
    if output(*git, "rev-parse", "HEAD", env=env) != commit:
        raise ReleaseError("检出的源码与已批准提交不一致。")


def archive_app(app, archive):
    run("/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, archive)


def notarize(app, work, profile):
    submission = work / "for-notarization.zip"
    archive_app(app, submission)
    response = json.loads(output("/usr/bin/xcrun", "notarytool", "submit", submission, "--keychain-profile", profile,
                                 "--wait", "--timeout", "30m", "--output-format", "json"))
    if response.get("status") != "Accepted" or not response.get("id"):
        raise ReleaseError(f"Apple 公证未通过（{response.get('status', '?')}，ID {response.get('id', '?')}）；不发布。")
    run("/usr/bin/xcrun", "stapler", "staple", app)
    return response["id"]


def create_private_draft(repo, tag, files, approval):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+", repo) or repo.casefold() == SOURCE.casefold():
        raise ReleaseError("验收包只能上传至独立的私有 GitHub 仓库（owner/repo）。")
    info = github(f"repos/{repo}")
    if info.get("visibility") != "private" or not info.get("permissions", {}).get("push"):
        raise ReleaseError("验收目标不是可写的私有仓库，拒绝上传。")
    pages = json.loads(output("gh", "api", "--hostname", "github.com", "--paginate", "--slurp",
                              f"repos/{repo}/releases?per_page=100"))
    refs = github(f"repos/{repo}/git/matching-refs/tags/{tag}")
    if any(r["tag_name"] == tag for page in pages for r in page) or any(r["ref"] == f"refs/tags/{tag}" for r in refs):
        raise ReleaseError("相同验收标签或 Release 已存在，保留已有资产。")
    run("gh", "release", "create", tag, *files, "--repo", f"github.com/{repo}", "--draft", "--prerelease",
        "--latest=false", "--title", f"Untitled {approval.version.name} / {approval.version.build} · 验收预览",
        "--notes", f"源码：{SOURCE}@{approval.commit}\nCI：https://github.com/{SOURCE}/actions/runs/{approval.run}")


def package(args, approval):
    reference = args.reference_app.resolve(strict=True)
    require_upgrade(approval.version, bundle_version(reference))
    requirement = designated_requirement(reference)
    fingerprint = args.signing_identity_file.read_text().strip().upper()
    if not re.fullmatch(r"[A-F0-9]{40}", fingerprint):
        raise ReleaseError("签名身份文件只能包含 Developer ID 签名证书的 40 位 SHA-1 指纹。")
    try:
        run("/usr/bin/xcrun", "notarytool", "history", "--keychain-profile", args.notary_profile, stdout=subprocess.DEVNULL)
    except subprocess.CalledProcessError as error:
        raise ReleaseError("公证配置不可用；请在签发账号的钥匙串配置凭据后重试。") from error

    sdk = output("/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-version")
    version = approval.version
    tag = f"preview-v{version.name}-b{version.build}"
    destination = args.output.resolve()
    destination.mkdir(parents=True, exist_ok=True)
    final = destination / tag
    with (destination / ".release.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise ReleaseError("已有签发任务正在使用该目录。") from error
        if os.path.lexists(final):
            raise ReleaseError(f"{tag} 已存在，不重写同一构建的 ZIP 或 SHA-256。")
        with tempfile.TemporaryDirectory(dir=destination, prefix=".release-") as directory:
            work = Path(directory)
            source = work / "source"
            fetch_source(approval.commit, source)
            if version_of(plistlib.loads((source / "Resources/Info.plist").read_bytes())) != version:
                raise ReleaseError("检出的源码版本与 GitHub 证明不一致。")
            env = dict(build_environment(), UNTITLED_SIGNING_IDENTITY=fingerprint)
            run("/bin/bash", source / "scripts/build-app.sh", "release", cwd=source, env=env)
            app = source / "dist/release/Untitled.app"
            if bundle_version(app) != version:
                raise ReleaseError("产物版本与批准的源码版本不一致。")
            require_same_identity(app, fingerprint, requirement)
            run("/bin/bash", Path(__file__).resolve().with_name("check-app-sdk.sh"), app, sdk)
            archs = set(output("/usr/bin/xcrun", "lipo", "-archs", app / "Contents/MacOS/Untitled").split())
            if not archs or not archs <= {"arm64", "x86_64"}:
                raise ReleaseError("产物架构不受支持。")
            ticket = notarize(app, work, args.notary_profile)

            staged = work / "release"
            staged.mkdir()
            archive = staged / f"Untitled-macOS-{'-'.join(sorted(archs))}-v{version.name}-b{version.build}.zip"
            archive_app(app, archive)
            extracted = work / "verify"
            extracted.mkdir()
            run("/usr/bin/ditto", "-x", "-k", archive, extracted)
            extracted_app = extracted / "Untitled.app"
            require_same_identity(extracted_app, fingerprint, requirement)
            run("/usr/bin/xcrun", "stapler", "validate", extracted_app)
            run("/usr/bin/syspolicy_check", "distribution", extracted_app)
            checksum = hashlib.sha256()
            with archive.open("rb") as file:
                for chunk in iter(lambda: file.read(1024 * 1024), b""):
                    checksum.update(chunk)
            (staged / "SHA256SUMS.txt").write_text(f"{checksum.hexdigest()}  {archive.name}\n")
            (staged / "release.json").write_text(json.dumps({
                "source": SOURCE, "commit": approval.commit, "ciRun": approval.run, "ciAttempt": approval.attempt,
                "version": version.name, "build": version.build, "sdk": sdk, "archs": sorted(archs),
                "notarizationId": ticket, "archive": archive.name,
            }, indent=2) + "\n")
            staged.rename(final)
        print(f"签发包已生成：{final}", flush=True)
        if args.draft_repo:
            create_private_draft(args.draft_repo, tag,
                                 [final / archive.name, final / "SHA256SUMS.txt", final / "release.json"], approval)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    check = commands.add_parser("check", help="只查询 GitHub，不构建、不签名")
    check.add_argument("commit")
    prepare = commands.add_parser("package", help="构建、签名、公证，并可选上传私有验收草稿")
    prepare.add_argument("commit")
    prepare.add_argument("--reference-app", type=Path, required=True, help="已安装或已分发的有效 Developer ID 签名包")
    prepare.add_argument("--signing-identity-file", type=Path, required=True)
    prepare.add_argument("--notary-profile", required=True)
    prepare.add_argument("--output", type=Path, required=True)
    prepare.add_argument("--draft-repo", help="独立私有验收仓库 owner/repo；不指定则仅生成本地包")
    args = parser.parse_args()
    os.umask(0o077)
    try:
        approval = verify_commit(args.commit)
        print(f"{approval.commit} · {approval.version.name} / build {approval.version.build} · "
              f"macOS CI {approval.run} attempt {approval.attempt}", flush=True)
        if args.command == "package":
            package(args, approval)
    except (ReleaseError, OSError, ValueError, KeyError, subprocess.SubprocessError, plistlib.InvalidFileException) as error:
        parser.exit(1, f"签发流程停止：{error}\n")


if __name__ == "__main__":
    main()

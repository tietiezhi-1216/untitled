#!/usr/bin/env python3
"""Submit an Agent's committed worktree and finish delivery after GitHub publishes it."""

import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import time
import zipfile

from release_assets import is_ancestor, release_list, verify_public
from release_plan import command, plan, require_main


PULL_FIELDS = (
    "number,url,state,isCrossRepository,isDraft,labels,headRefName,headRefOid,"
    "baseRefName,mergeCommit,mergedAt,mergeStateStatus,statusCheckRollup"
)
IGNORED_BUILD_OUTPUTS = {".build", ".swiftpm", "DerivedData", "__pycache__", ".DS_Store"}


def git(path, *args):
    return command("git", "-C", path, *args)


def pull(repository, number):
    return json.loads(command("gh", "pr", "view", str(number), "--repo", repository, "--json", PULL_FIELDS))


def await_merge(repository, number, branch, head, deadline):
    while True:
        pr = pull(repository, number)
        if pr["isCrossRepository"] or pr["baseRefName"] != "main" or pr["headRefName"] != branch:
            raise ValueError("PR repository, base or task branch does not match the worktree")
        if pr["state"] == "MERGED" and pr["mergedAt"] and pr["mergeCommit"]:
            command("git", "fetch", "origin")
            source = require_main(pr["mergeCommit"]["oid"])
            if head != pr["headRefOid"]:
                command("git", "fetch", "--no-tags", "origin", f"refs/pull/{number}/head")
                if not is_ancestor(head, pr["headRefOid"]):
                    raise ValueError(f"{pr['url']} does not contain this worktree's committed HEAD")
            return pr, plan(source)
        terminal = pr["state"] != "OPEN" or pr["isDraft"] or pr["mergeStateStatus"] == "DIRTY" or any(
            label["name"] == "no-automerge" for label in pr["labels"]
        )
        failed = any(check.get("name") == "verify" and check.get("conclusion") in
                     {"FAILURE", "TIMED_OUT", "STARTUP_FAILURE"} for check in pr["statusCheckRollup"])
        if terminal or failed:
            raise ValueError(f"{pr['url']} needs attention before merging. The worktree is retained.")
        wait(deadline, f"protected merge of {pr['url']}")


def wait(deadline, event):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise ValueError(f"Timed out waiting for {event}; resume this delivery with --pr")
    time.sleep(min(15, remaining))


def await_releases(repository, release_plan, deadline):
    products = [product for product in [release_plan["host"], *release_plan["plugins"]] if product]
    source = release_plan["source"]
    verified = {}
    while len(verified) < len(products):
        releases = {item["tag_name"]: item for item in release_list(repository)}
        for product in products:
            tag = product["tag"]
            if tag not in verified and (result := verify_public(repository, source, tag, releases.get(tag))):
                verified[tag] = result
                print(f"Verified public download of {tag}: {result['url']}", flush=True)
        if len(verified) == len(products):
            break
        runs = json.loads(command("gh", "run", "list", "--repo", repository, "--workflow", "release.yml",
                                  "--branch", "main", "--limit", "40", "--json",
                                  "displayTitle,status,conclusion,url"))
        run = next((item for item in runs if item["displayTitle"] == f"Release {source}"), None)
        if run and run["status"] == "completed" and run["conclusion"] not in {"success", "skipped"}:
            raise ValueError(f"The release workflow needs attention: {run['url']}. The worktree is retained.")
        pending = ", ".join(product["tag"] for product in products if product["tag"] not in verified)
        wait(deadline, f"public releases {pending}")
    return list(verified.values())


def verify_local_host(expected):
    app = Path("/Applications/Untitled.app")
    if app.resolve() != app:
        raise ValueError("Verify the installed host from /Applications/Untitled.app")
    try:
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    except FileNotFoundError as error:
        raise ValueError("The published host is still pending local installation") from error
    binary = app / "Contents/MacOS/Untitled"
    processes = {line.strip() for line in command("/bin/ps", "-axo", "comm=").splitlines()}
    if (info.get("CFBundleIdentifier") != "com.untitled.app" or
            info.get("CFBundleShortVersionString") != expected["version"] or
            info.get("CFBundleVersion") != expected["build"] or
            str(binary) not in processes):
        raise ValueError(f"Confirm Untitled {expected['version']} ({expected['build']}) is installed and "
                         f"running from {app} before cleanup")
    command("/usr/bin/codesign", "--verify", "--deep", "--strict", app)
    return {"path": str(app), "version": expected["version"], "build": expected["build"]}


def clean_task(task, branch, head):
    if (git(task, "status", "--porcelain") or git(task, "branch", "--show-current") != branch
            or git(task, "rev-parse", "HEAD") != head):
        raise ValueError("The task worktree changed during delivery; keeping it for inspection")


def require_clean_main(main):
    if git(main, "branch", "--show-current") != "main" or git(main, "status", "--porcelain"):
        raise ValueError("The main worktree must be clean and checked out on main before cleanup and sync")


def retain_outputs(main, task, receipt):
    ignored = git(task, "ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z")
    for path in ignored.split("\0"):
        if path and not set(Path(path).parts).intersection(IGNORED_BUILD_OUTPUTS | {"dist"}):
            raise ValueError(f"The worktree contains ignored data to keep before removal: {path}")
    common = git(main, "rev-parse", "--path-format=absolute", "--git-common-dir")
    record = Path(common) / "untitled-delivery" / f"pr-{receipt['pr']}-{receipt['source'][:12]}"
    record.mkdir(parents=True, exist_ok=True)
    outputs = task / "dist"
    if outputs.is_symlink():
        raise ValueError("The task's dist path is a symbolic link; preserve it before removal")
    if outputs.exists():
        destination = record / "dist"
        if destination.exists():
            raise ValueError(f"Output backup already exists at {destination}; preserve both copies before retrying")
        shutil.move(outputs, destination)
    (record / "delivery.json").write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    print(f"Delivery records and retained outputs: {record}", flush=True)


def finish_local(main, task, branch, head, receipt, keep_worktree):
    clean_task(task, branch, head)
    if not keep_worktree:
        require_clean_main(main)
        git(main, "fetch", "origin")
        if not is_ancestor(git(main, "rev-parse", "HEAD"), git(main, "rev-parse", "origin/main")):
            raise ValueError("Local main cannot fast-forward to origin/main; the task worktree is retained")
    retain_outputs(main, task, receipt)
    if keep_worktree:
        print("Delivery verified. The managed worktree is ready to archive.", flush=True)
        return
    git(main, "worktree", "remove", task)
    print(f"Removed task worktree {task}", flush=True)
    require_clean_main(main)
    git(main, "pull", "--ff-only", "origin", "main")
    local = git(main, "rev-parse", "HEAD")
    if local != git(main, "rev-parse", "origin/main"):
        raise ValueError("Local main did not synchronize to origin/main")
    print(f"Local main synchronized at {local}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--worktree", required=True, type=Path)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--body-file", type=Path, help="Push, create or reuse an open PR, and request auto-merge")
    mode.add_argument("--pr", type=int, help="Resume a known PR without pushing")
    parser.add_argument("--wait-minutes", type=int, default=45)
    parser.add_argument("--keep-worktree", action="store_true", help="For a Codex-managed checkout; archive in Codex")
    args = parser.parse_args()
    try:
        if args.wait_minutes < 1:
            raise ValueError("Specify a positive number of minutes")
        main_worktree = Path(command("git", "rev-parse", "--show-toplevel"))
        task = args.worktree.resolve(strict=True)
        body_file = args.body_file.resolve(strict=True) if args.body_file else None
        os.chdir(main_worktree)
        common_args = ("rev-parse", "--path-format=absolute", "--git-common-dir")
        if (task == main_worktree or Path(git(task, "rev-parse", "--show-toplevel")) != task
                or git(task, *common_args) != git(main_worktree, *common_args)):
            raise ValueError("Run from the main checkout with a distinct linked task worktree")
        if git(main_worktree, "branch", "--show-current") != "main":
            raise ValueError("Run from the worktree with main checked out")
        branch = git(task, "branch", "--show-current")
        if not re.fullmatch(r"(agent|codex)/.+", branch):
            raise ValueError("Choose the task's agent/<task> or codex/<task> worktree")
        head = git(task, "rev-parse", "HEAD")
        clean_task(task, branch, head)
        repository = json.loads(command("gh", "repo", "view", "--json", "nameWithOwner,defaultBranchRef"))
        name = repository["nameWithOwner"]
        origin = git(main_worktree, "remote", "get-url", "origin")
        if repository["defaultBranchRef"]["name"] != "main" or origin not in {
            f"git@github.com:{name}.git", f"https://github.com/{name}.git", f"https://github.com/{name}"
        }:
            raise ValueError("origin must be the GitHub repository with protected default main")
        number = args.pr
        if body_file:
            submit = Path(__file__).with_name("submit-agent-pr.py")
            submitted = command("python3", submit, "--body-file", body_file, cwd=task)
            url = submitted.splitlines()[0]
            number = int(url.rsplit("/", 1)[-1])
        print(f"Waiting for delivery of https://github.com/{name}/pull/{number}", flush=True)
        deadline = time.monotonic() + args.wait_minutes * 60
        pr, release_plan = await_merge(name, number, branch, head, deadline)
        print(f"Confirmed protected merge {release_plan['source']}", flush=True)
        published = await_releases(name, release_plan, deadline)
        receipt = {
            "pr": pr["number"], "pr_url": pr["url"], "source": release_plan["source"],
            "merged_at": pr["mergedAt"], "releases": published,
        }
        if release_plan["host"]:
            receipt["installed_host"] = verify_local_host(release_plan["host"])
        finish_local(main_worktree, task, branch, head, receipt, args.keep_worktree)
    except (OSError, ValueError, KeyError, zipfile.BadZipFile, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Agent delivery stopped: {error}\n")


if __name__ == "__main__":
    main()

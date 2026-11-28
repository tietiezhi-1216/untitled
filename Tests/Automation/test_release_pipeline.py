import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile


scripts = Path(__file__).resolve().parents[2] / "scripts"
sys.path.insert(0, str(scripts))
import release_assets
import release_plan
spec = importlib.util.spec_from_file_location("deliver_agent_task", scripts / "deliver-agent-task.py")
delivery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(delivery)
sys.path.remove(str(scripts))

SOURCE = "a" * 40


class GitFixture(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name).resolve()
        self.main = self.directory / "main"
        self.main.mkdir()
        self.git(self.main, "init", "-b", "main", "-q")
        self.git(self.main, "config", "user.name", "Fixture")
        self.git(self.main, "config", "user.email", "fixture@example.invalid")
        self.write("README.md", "Host\n")

    def git(self, worktree, *arguments):
        return subprocess.check_output(["git", "-C", worktree, *arguments], text=True).strip()

    def write(self, file, content):
        destination = self.main / file
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(content if isinstance(content, bytes) else content.encode())

    def commit(self):
        self.git(self.main, "add", "-A")
        self.git(self.main, "commit", "-qm", "Fixture change")
        return self.git(self.main, "rev-parse", "HEAD")


class ReleasePlanTests(GitFixture):
    def setUp(self):
        super().setUp()
        self.host("1.0.0", "1")
        self.manifest("2.0.0")
        self.write("Plugins/example/README.md", "Plugin")
        self.base = self.commit()

    def host(self, marketing_version, build, runtime_version=None):
        self.write("Resources/Info.plist", plistlib.dumps({
            "CFBundleShortVersionString": marketing_version,
            "CFBundleVersion": build,
        }))
        self.write("Sources/Untitled/PluginManifest.swift",
                   'enum HostInfo {\n    static let version = "' + (runtime_version or marketing_version) + '"\n}\n')

    def manifest(self, version, minimum="1.0.0"):
        self.write("Plugins/example/manifest.json", json.dumps({"version": version, "minimumHostVersion": minimum}))

    def plan(self):
        source = self.commit()
        with contextlib.chdir(self.main):
            return release_plan.plan(source)

    def test_workflow_and_catalog_changes_only_merge_source(self):
        self.write(".github/workflows/release.yml", "name: fixture\n")
        self.write("Plugins/catalog.json", "{}\n")
        result = self.plan()
        self.assertIsNone(result["host"])
        self.assertEqual(result["plugins"], [])

    def test_declarative_release_does_not_rebuild_bundled_presentation_metadata(self):
        self.manifest("2.0.1")
        self.write("Sources/Untitled/Resources/BundledPlugins.json", "[]\n")
        result = self.plan()
        self.assertIsNone(result["host"])
        self.assertEqual(result["plugins"], [
            {"slug": "example", "tag": "plugin-example-v2.0.1", "minimum": "1.0.0"},
        ])

    def test_host_and_plugin_versions_are_independent(self):
        self.host("1.0.1", "2")
        self.manifest("2.0.1", "1.0.1")
        result = self.plan()
        self.assertEqual(result["host"], {"tag": "v1.0.1", "version": "1.0.1", "build": "2"})
        self.assertEqual(result["plugins"][0]["minimum"], "1.0.1")

    def test_native_source_moved_to_plugin_directory_still_requires_host_version(self):
        self.write("Plugins/example/Sources/Example.swift", "struct Example {}\n")
        with self.assertRaisesRegex(ValueError, "both the marketing version and build number"):
            self.plan()

    def test_marketing_and_runtime_version_must_agree(self):
        self.host("1.0.1", "2", runtime_version="1.0.0")
        with self.assertRaisesRegex(ValueError, "HostInfo.version"):
            self.plan()

    def test_zip_readme_change_requires_its_own_version(self):
        self.write("Plugins/example/README.md", "New ZIP documentation\n")
        with self.assertRaisesRegex(ValueError, "increasing its plugin version"):
            self.plan()

    def test_minimum_host_version_cannot_exceed_source(self):
        self.manifest("2.0.1", "1.0.1")
        with self.assertRaisesRegex(ValueError, "newer than this source"):
            self.plan()


    def test_maintenance_source_uses_immutable_approval_from_protected_main(self):
        self.git(self.main, "tag", "v1.0.0", self.base)
        self.git(self.main, "switch", "-qc", "release/v1.0.1")
        self.host("1.0.1", "2")
        source = self.commit()
        self.git(self.main, "switch", "-q", "main")
        filename = ".github/approved-release-sources.json"
        self.write(filename, json.dumps({source: {"baseline": "v1.0.0", "tags": ["v1.0.1"]}}))
        approval_sha = self.commit()
        self.git(self.main, "update-ref", "refs/remotes/origin/main", approval_sha)
        self.write(filename, "{}")
        with contextlib.chdir(self.main):
            self.assertEqual(release_plan.require_approved_source(source, "v1.0.1")["tags"], ["v1.0.1"])
            with self.assertRaisesRegex(ValueError, "not approved"):
                release_plan.require_approved_source(source, "v1.0.2")
            with self.assertRaisesRegex(ValueError, "no release approval"):
                release_plan.require_approved_source(self.base)
            with self.assertRaisesRegex(ValueError, "protected origin/main"):
                release_plan.require_main(source)

    def test_maintenance_source_must_include_its_host_baseline(self):
        self.git(self.main, "switch", "-qc", "release/v1.0.2")
        self.host("1.0.2", "3")
        source = self.commit()
        self.git(self.main, "switch", "-q", "main")
        filename = ".github/approved-release-sources.json"
        self.write(filename, json.dumps({source: {"baseline": "v1.0.1", "tags": ["v1.0.2"]}}))
        approval_sha = self.commit()
        self.git(self.main, "tag", "v1.0.1", approval_sha)
        self.git(self.main, "update-ref", "refs/remotes/origin/main", approval_sha)
        with contextlib.chdir(self.main), self.assertRaises(subprocess.CalledProcessError):
            release_plan.require_approved_source(source)


class ReleaseAssetsTests(unittest.TestCase):
    def test_plugin_release_draft_upload_publish_and_public_download(self):
        with tempfile.TemporaryDirectory() as name:
            directory = Path(name)
            archive = directory / "example-2.0.1.zip"
            with zipfile.ZipFile(archive, "w") as zipped:
                zipped.writestr("manifest.json", '{"version":"2.0.1"}')
                zipped.writestr("LICENSE", "Example")
                zipped.writestr("README.md", "Example")
            expected = hashlib.sha256(archive.read_bytes()).hexdigest()
            self.exercise_release(directory, expected)

    def exercise_release(self, directory, expected):
        repository = "fixture/untitled"
        tag = "plugin-example-v2.0.1"
        archive_name = "example-2.0.1.zip"
        host = {
            "tag_name": "v1.0.0", "draft": False,
            "assets": [{"name": "Untitled-macOS-arm64-v1.0.0.zip", "state": "uploaded"}],
        }
        public_url = f"https://github.com/{repository}/releases/tag/{tag}"
        assets, remote_refs, writes = {}, {}, []
        draft = {"tag_name": tag, "draft": True, "prerelease": False, "published_at": None,
                 "body": "", "html_url": public_url, "assets": []}

        def api(*args):
            if args[:2] == ("git", "ls-remote"):
                return remote_refs.get(args[-2], "")
            if args[:4] == ("gh", "api", "--method", "POST"):
                writes.append("tag")
                remote_refs[f"refs/tags/{tag}"] = f"{SOURCE}\trefs/tags/{tag}"
            elif args[:3] == ("gh", "release", "create"):
                self.assertIn("--verify-tag", args)
                self.assertIn("--draft", args)
                writes.append("draft")
                draft["body"] = args[args.index("--notes") + 1]
            elif args[:3] == ("gh", "release", "upload"):
                path = args[4]
                writes.append(path.name)
                assets[path.name] = path.read_bytes()
                draft["assets"].append({"name": path.name, "state": "uploaded"})
            elif args[:3] == ("gh", "release", "edit"):
                self.assertIn("--latest=false", args)
                self.assertEqual(set(assets), {archive_name, "SHA256SUMS.txt"})
                writes.append("publish")
                draft.update({"draft": False, "published_at": "time"})
            elif args[0] == "curl":
                self.assertFalse(draft["draft"])
                self.assertTrue(args[-1].startswith(f"https://github.com/{repository}/releases/download/{tag}/"))
                args[args.index("--output") + 1].write_bytes(assets[args[-1].rsplit("/", 1)[-1]])
            else:
                self.fail(f"Unexpected application call: {args}")
            return ""

        with patch.object(release_assets, "require_main"), patch.object(release_assets, "command", side_effect=api), \
                patch.object(release_assets, "release_list", return_value=[host, draft]):
            result = release_assets.publish(repository, SOURCE, tag, [host], None, directory, "preview", "1.0.0", "")
            self.assertEqual(result, {"tag": tag, "source": SOURCE, "url": public_url, "asset": archive_name,
                                      "sha256": expected})
            self.assertEqual(writes, ["tag", "draft", archive_name, "SHA256SUMS.txt", "publish"])
            writes.clear()
            self.assertEqual(release_assets.publish(repository, SOURCE, tag, [host, draft], draft,
                                                    directory, "preview", "1.0.0", ""), result)
            self.assertEqual(writes, [])
            assets[archive_name] += b"tampered"
            with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
                release_assets.verify_public(repository, SOURCE, tag, draft)

    def test_host_baseline_requires_ancestry_or_explicit_adoption(self):
        published = [{"tag_name": "v1.0.0", "draft": False,
                      "assets": [{"name": "Untitled-macOS-arm64-v1.0.0.zip", "state": "uploaded"}]}]
        baseline = "b" * 40
        with patch.object(release_assets, "tag_source", return_value="c" * 40), \
                patch.object(release_assets, "is_ancestor", side_effect=lambda candidate, _: candidate == baseline), \
                patch.object(release_assets, "require_main", return_value=baseline):
            with self.assertRaisesRegex(ValueError, "published baseline v1.0.0"):
                release_assets.require_host_baseline(published, SOURCE, "1.0.1", "")
            release_assets.require_host_baseline(published, SOURCE, "1.0.1", f"v1.0.0:{baseline}")


    def test_only_recorded_preview_can_use_its_older_public_baseline(self):
        releases = [
            {"tag_name": tag, "draft": False,
             "assets": [{"name": f"Untitled-macOS-arm64-{tag}.zip", "state": "uploaded"}]}
            for tag in ("v1.0.0", "v1.0.2")
        ]
        approval = {"baseline": "v1.0.0", "allow_older_preview": True}
        with patch.object(release_assets, "tag_source", return_value="b" * 40) as tag_source, \
                patch.object(release_assets, "is_ancestor", return_value=True):
            for channel, record in [("preview", {}), ("stable", approval)]:
                with self.subTest(channel=channel, record=record):
                    with self.assertRaisesRegex(ValueError, "already at v1.0.2"):
                        release_assets.require_host_release_baseline(releases, SOURCE, "1.0.1", "", channel, record)
            with self.assertRaisesRegex(ValueError, "has no public host ZIP"):
                release_assets.require_host_release_baseline(releases[1:], SOURCE, "1.0.1", "", "preview", approval)
            release_assets.require_host_release_baseline(releases, SOURCE, "1.0.1", "", "preview", approval)
            tag_source.assert_called_once_with("v1.0.0")


class LocalFinishTests(GitFixture):
    def setUp(self):
        super().setUp()
        self.write(".gitignore", "dist/\n.signing-identity\n")
        self.head = self.commit()
        self.branch = "agent/verification"
        self.task = self.directory / "task"
        self.remote = self.directory / "remote.git"
        self.remote.mkdir()
        self.git(self.remote, "init", "--bare", "-b", "main", "-q")
        self.git(self.main, "remote", "add", "origin", self.remote)
        self.git(self.main, "push", "-q", "origin", "main")
        self.git(self.main, "worktree", "add", "-qb", self.branch, self.task)
        self.receipt = {"pr": 7, "source": SOURCE}

    def test_clean_worktree_removal_preserves_outputs_and_fast_forwards_main(self):
        (self.task / "dist").mkdir()
        (self.task / "dist" / "receipt.txt").write_text("Keep this")
        writer = self.directory / "writer"
        self.git(self.directory, "clone", "-q", self.remote, writer)
        self.git(writer, "config", "user.name", "Fixture")
        self.git(writer, "config", "user.email", "fixture@example.invalid")
        (writer / "README.md").write_text("New merged code\n")
        self.git(writer, "commit", "-qam", "Merge equivalent")
        self.git(writer, "push", "-q", "origin", "main")
        with contextlib.chdir(self.main), contextlib.redirect_stdout(io.StringIO()):
            delivery.finish_local(self.main, self.task, self.branch, self.head, self.receipt, False)
        self.assertFalse(self.task.exists())
        self.assertEqual(self.git(self.main, "rev-parse", "HEAD"), self.git(writer, "rev-parse", "HEAD"))
        saved = self.main / ".git" / "untitled-delivery" / f"pr-7-{SOURCE[:12]}"
        self.assertEqual((saved / "dist" / "receipt.txt").read_text(), "Keep this")
        self.assertEqual(json.loads((saved / "delivery.json").read_text()), self.receipt)

    def test_dirty_main_or_ignored_private_file_preserves_task(self):
        (self.main / "README.md").write_text("Uncommitted developer changes\n")
        with contextlib.chdir(self.main):
            with self.assertRaisesRegex(ValueError, "main worktree must be clean"):
                delivery.finish_local(self.main, self.task, self.branch, self.head, self.receipt, False)
            self.git(self.main, "restore", "README.md")
            (self.task / ".signing-identity").touch()
            with self.assertRaisesRegex(ValueError, "ignored data"):
                delivery.finish_local(self.main, self.task, self.branch, self.head, self.receipt, False)
        self.assertTrue((self.task / ".signing-identity").is_file())

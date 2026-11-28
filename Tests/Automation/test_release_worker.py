import base64
from contextlib import redirect_stdout
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("release_worker", Path(__file__).resolve().parents[2] / "scripts/release-worker.py")
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)
SOURCE = worker.SOURCE
SHA = "1" * 40
VERSION = worker.Version("0.13.53", 122)
APPROVAL = worker.Approval(SHA, 123, 2, VERSION)
ReleaseError = worker.ReleaseError


def app_plist(version=VERSION):
    return plistlib.dumps({
        "CFBundleIdentifier": "com.untitled.app", "CFBundleExecutable": "Untitled",
        "CFBundleShortVersionString": version.name, "CFBundleVersion": str(version.build),
    })


class ReleaseCommitTests(unittest.TestCase):
    def setUp(self):
        self.branch = {"protected": True, "commit": {"sha": SHA}}
        self.compare = {"status": "ahead", "merge_base_commit": {"sha": SHA}}
        self.ci = {"id": 123, "run_attempt": 2, "status": "completed", "conclusion": "success", "event": "push",
                   "path": ".github/workflows/ci.yml", "head_repository": {"full_name": SOURCE},
                   "head_branch": "main", "head_sha": SHA}
        self.runs = [self.ci]
        self.jobs = [{"name": "verify", "status": "completed", "conclusion": "success"}]
        self.info = {"type": "file", "encoding": "base64", "content": base64.b64encode(app_plist()).decode()}

    def github(self, path, **query):
        base = f"repos/{SOURCE}"
        if path == f"{base}/branches/main":
            return self.branch
        if path == f"{base}/compare/{SHA}...{'2' * 40}":
            return self.compare
        if path == f"{base}/actions/workflows/ci.yml/runs":
            self.assertEqual(query, {"branch": "main", "head_sha": SHA})
            return {"workflow_runs": self.runs}
        if path == f"{base}/actions/runs/123/attempts/2/jobs":
            return {"jobs": self.jobs}
        if path == f"{base}/contents/Resources/Info.plist":
            self.assertEqual(query, {"ref": SHA})
            return self.info
        self.fail(f"Unexpected API request: {path}")

    def verify(self):
        with patch.object(worker, "github", self.github):
            return worker.verify_commit(SHA)

    def test_protected_main_and_exact_successful_attempt(self):
        self.assertEqual(self.verify(), APPROVAL)
        self.branch["commit"]["sha"] = "2" * 40
        self.assertEqual(self.verify(), APPROVAL)

    def test_rejects_other_refs_and_unprotected_or_diverged_main(self):
        with self.assertRaisesRegex(ReleaseError, "40 位"):
            worker.verify_commit("main")
        self.branch["protected"] = False
        with self.assertRaisesRegex(ReleaseError, "未受保护"):
            self.verify()
        self.branch = {"protected": True, "commit": {"sha": "2" * 40}}
        self.compare["merge_base_commit"]["sha"] = "3" * 40
        with self.assertRaisesRegex(ReleaseError, "不在"):
            self.verify()

    def test_pr_fork_another_commit_or_workflow_cannot_authorize(self):
        for override in ({"event": "pull_request"}, {"head_repository": {"full_name": "fork/untitled"}},
                         {"head_sha": "2" * 40}, {"path": ".github/workflows/other.yml"}, {"head_branch": "topic"}):
            with self.subTest(override=override):
                self.runs = [dict(self.ci, **override)]
                with self.assertRaisesRegex(ReleaseError, "找不到"):
                    self.verify()

    def test_latest_failed_run_or_skipped_job_does_not_authorize(self):
        self.runs = [self.ci, dict(self.ci, id=124, conclusion="failure")]
        with self.assertRaisesRegex(ReleaseError, "尚未通过"):
            self.verify()
        self.runs = [self.ci]
        self.jobs[0]["conclusion"] = "skipped"
        with self.assertRaisesRegex(ReleaseError, "verify"):
            self.verify()


class SigningPackageTests(unittest.TestCase):
    def test_never_downgrades_version_or_build(self):
        worker.require_upgrade(VERSION, worker.Version("0.13.52", 121))
        worker.require_upgrade(VERSION, worker.Version("0.13.53", 121))
        for reference in [worker.Version("0.13.54", 121), VERSION, worker.Version("0.13.52", 123)]:
            with self.subTest(reference=reference), self.assertRaisesRegex(ReleaseError, "拒绝覆盖"):
                worker.require_upgrade(VERSION, reference)

    def test_mismatching_designated_requirement_rejected(self):
        with patch.object(worker, "designated_requirement", lambda *_: "different identity"):
            with self.assertRaisesRegex(ReleaseError, "签名指定要求"):
                worker.require_same_identity(Path("Untitled.app"), "A" * 40, "installed identity")

    def test_accepted_notarization_and_downloadable_zip_gate_draft(self):
        # Exercise the orchestration against fake system tools: no real signing, Apple or GitHub writes.
        for notary_status, extraction_verifies in [("Invalid", True), ("Accepted", False), ("Accepted", True)]:
            with self.subTest(status=notary_status, extraction_verifies=extraction_verifies), tempfile.TemporaryDirectory() as directory:
                root = Path(directory).resolve()
                tag = "preview-v0.13.53-b122"
                reference = root / "installed.app"
                (reference / "Contents").mkdir(parents=True)
                (reference / "Contents/Info.plist").write_bytes(app_plist(worker.Version("0.13.52", 121)))
                identity = root / "identity"
                identity.write_text("A" * 40)
                args = SimpleNamespace(reference_app=reference, signing_identity_file=identity, notary_profile="test",
                                       output=root / "out", draft_repo="owner/private-releases")
                trace = []

                def checkout(commit, source):
                    self.assertEqual(commit, SHA)
                    (source / "Resources").mkdir(parents=True)
                    (source / "Resources/Info.plist").write_bytes(app_plist())

                def run(executable, *argv, **kwargs):
                    if str(argv[0]).endswith("/scripts/build-app.sh"):
                        self.assertNotIn("GH_TOKEN", kwargs["env"])
                        app = kwargs["cwd"] / "dist/release/Untitled.app/Contents"
                        app.mkdir(parents=True)
                        (app / "Info.plist").write_bytes(app_plist())
                    elif executable == "/usr/bin/ditto" and argv[0] == "-c":
                        argv[-1].write_bytes(b"test zip")
                    elif executable == "/usr/bin/syspolicy_check":
                        trace.append("policy")
                    elif argv[:2] == ("stapler", "staple"):
                        trace.append("staple")
                    elif argv[:2] == ("stapler", "validate"):
                        trace.append("validate")

                def output(_executable, *argv):
                    if argv[0] == "--sdk":
                        return "27.0"
                    if argv[0] == "lipo":
                        return "arm64"
                    if argv[:2] == ("notarytool", "submit"):
                        return json.dumps({"status": notary_status, "id": "test-ticket"})
                    self.fail(f"Unexpected fake system command: {argv}")

                def verify(app, *_):
                    if app.parent.name == "verify" and not extraction_verifies:
                        raise ReleaseError("ZIP 验签失败")

                def draft(_repo, actual_tag, files, _approval):
                    self.assertEqual(actual_tag, tag)
                    self.assertEqual(trace, ["staple", "validate", "policy"])
                    self.assertTrue(all(p.is_file() and p.parent == args.output / tag for p in files))
                    trace.append("draft")

                with redirect_stdout(io.StringIO()), patch.multiple(
                    worker, fetch_source=checkout, run=run, output=output, require_same_identity=verify,
                    designated_requirement=lambda _: "installed identity", create_private_draft=draft,
                ):
                    if notary_status != "Accepted" or not extraction_verifies:
                        with self.assertRaises(ReleaseError):
                            worker.package(args, APPROVAL)
                        self.assertFalse((args.output / tag).exists())
                        self.assertNotIn("draft", trace)
                    else:
                        worker.package(args, APPROVAL)
                        self.assertEqual(trace[-1], "draft")
                        sidecar = json.loads((args.output / tag / "release.json").read_text())
                        self.assertEqual(sidecar["commit"], SHA)
                        self.assertEqual(sidecar["notarizationId"], "test-ticket")
                        checksum = (args.output / tag / "SHA256SUMS.txt").read_text()
                        self.assertEqual(checksum, f"{hashlib.sha256(b'test zip').hexdigest()}  {sidecar['archive']}\n")
                        with self.assertRaisesRegex(ReleaseError, "不重写"):
                            worker.package(args, APPROVAL)

    def test_draft_refuses_public_destination_or_existing_assets(self):
        private = "owner/artifacts"
        tag = "preview-v0.13.53-b122"
        with patch.object(worker, "github", lambda _: {"visibility": "public", "permissions": {"push": True}}):
            with self.assertRaisesRegex(ReleaseError, "私有仓库"):
                worker.create_private_draft(private, tag, [], APPROVAL)
        with patch.multiple(worker, github=lambda path: [] if "/git/" in path else
                            {"visibility": "private", "permissions": {"push": True}},
                            output=lambda *_: json.dumps([[{"tag_name": tag}]])):
            with self.assertRaisesRegex(ReleaseError, "已存在"):
                worker.create_private_draft(private, tag, [], APPROVAL)


if __name__ == "__main__":
    unittest.main()

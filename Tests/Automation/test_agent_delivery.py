import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('submit_agent_pr', Path(__file__).resolve().parents[2] / 'scripts/submit-agent-pr.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
SHA = 'a' * 40
URL = 'https://github.com/owner/repo/pull/1'


class AgentDeliveryTests(unittest.TestCase):
    def invoke(self, *, dirty=False, branch='agent/test', origin=None, prs=None, race=False, merged=False):
        calls = []
        count = 0
        def run(*args):
            nonlocal count
            calls.append(args)
            if args[:3] == ('git', 'status', '--porcelain'): return ' M file' if dirty else ''
            if args[:3] == ('git', 'branch', '--show-current'): return branch
            if args[:3] == ('git', 'rev-parse', 'HEAD'): return SHA
            if args[:4] == ('gh', 'repo', 'view', '--json'):
                return json.dumps({'nameWithOwner':'owner/repo','defaultBranchRef':{'name':'main'}})
            if args[:3] == ('git', 'remote', 'get-url'): return origin or 'git@github.com:owner/repo.git'
            if args[:3] == ('git', 'log', '-1'): return 'Test delivery'
            if args[:3] == ('gh', 'pr', 'list'):
                count += 1
                return json.dumps(prs if prs is not None else ([{'url':URL,'number':1,'isDraft':False,'labels':[]}] if race and count > 1 else []))
            if args[:3] == ('gh', 'pr', 'create'):
                if race: raise subprocess.CalledProcessError(1,args)
                return URL
            if args[:3] == ('gh', 'pr', 'merge') and merged: raise subprocess.CalledProcessError(1,args)
            if args[:3] == ('gh', 'pr', 'view'): return json.dumps({'state':'MERGED'})
            return ''
        with tempfile.TemporaryDirectory() as directory:
            body = Path(directory)/'body.md';body.write_text('# Behavior\n\nFake validation, no real API writes.\n')
            argv = ['submit-agent-pr.py','--body-file',str(body)]
            with patch.object(module,'run',side_effect=run), patch.object(sys,'argv',argv), contextlib.redirect_stdout(io.StringIO()):
                module.main()
        return calls

    def test_create_and_enroll_exact_head_without_admin_or_force(self):
        calls = self.invoke()
        self.assertEqual(sum(c[:3]==('gh','pr','create') for c in calls),1)
        merge = next(c for c in calls if c[:3]==('gh','pr','merge'))
        self.assertIn('--auto',merge);self.assertIn('--squash',merge)
        self.assertEqual(merge[-2:],('--match-head-commit',SHA))
        self.assertFalse(any('--admin' in c or '--force-with-lease' in c for c in calls))

    def test_existing_pr_reused(self):
        calls = self.invoke(prs=[{'url':URL,'number':1,'isDraft':False,'labels':[]}])
        self.assertFalse(any(c[:3]==('gh','pr','create') for c in calls))

    def test_server_side_creation_race_is_idempotent(self):
        calls = self.invoke(race=True)
        self.assertTrue(any(c[:3]==('gh','pr','merge') for c in calls))

    def test_server_side_merge_race_is_success_only_when_actually_merged(self):
        calls = self.invoke(merged=True)
        self.assertTrue(any(c[:3]==('gh','pr','view') for c in calls))

    def test_dirty_worktree_refused(self):
        with self.assertRaisesRegex(SystemExit,'dirty worktree'): self.invoke(dirty=True)

    def test_protected_or_unmanaged_branch_refused(self):
        for branch in ['main','feature/test']:
            with self.subTest(branch=branch), self.assertRaisesRegex(SystemExit,'agent/<task>'): self.invoke(branch=branch)

    def test_wrong_push_destination_refused(self):
        with self.assertRaisesRegex(SystemExit,'origin does not match'): self.invoke(origin='git@github.com:elsewhere/repo.git')

    def test_explicit_draft_or_opt_out_not_overridden(self):
        for pr in [{'url':URL,'isDraft':True,'labels':[]},{'url':URL,'isDraft':False,'labels':[{'name':'no-automerge'}]}]:
            with self.subTest(pr=pr), self.assertRaisesRegex(SystemExit,'policy unchanged'): self.invoke(prs=[pr])


if __name__ == '__main__': unittest.main()

#!/usr/bin/env python3
"""Finish an authorized Agent change: push, idempotent PR, protected squash auto-merge.

Uses the operator's existing gh login locally. Never copies a token to Actions.
No commit, force-push, base reset, review approval, release, or application install.
"""
import argparse
import json
import re
import subprocess
import sys


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--title', help='PR title; defaults to the latest commit subject')
    parser.add_argument('--body-file', required=True, help='Markdown describing behavior, validation and remaining limits')
    args = parser.parse_args()
    if run('git', 'status', '--porcelain'):
        raise SystemExit('Commit the intended changes first; refusing to push a dirty worktree.')
    branch = run('git', 'branch', '--show-current')
    if not re.fullmatch(r'(agent|codex)/.+', branch):
        raise SystemExit('Use an agent/<task> branch (existing codex/<task> branches are also supported).')
    head = run('git', 'rev-parse', 'HEAD')
    repository = json.loads(run('gh', 'repo', 'view', '--json', 'nameWithOwner,defaultBranchRef'))
    name = repository['nameWithOwner']
    if repository['defaultBranchRef']['name'] != 'main':
        raise SystemExit('This workflow expects protected main as the default branch.')
    # Resolve an explicit destination so an unrelated origin cannot receive code.
    origin = run('git', 'remote', 'get-url', '--push', 'origin')
    if origin not in (f'git@github.com:{name}.git', f'https://github.com/{name}.git', f'https://github.com/{name}'):
        raise SystemExit('origin does not match the authenticated gh repository; inspect it instead of pushing.')
    with open(args.body_file, encoding='utf-8') as body:
        if not body.read().strip():
            raise SystemExit('PR body must describe the change and actual validation.')
    run('git', 'push', '-u', 'origin', f'HEAD:refs/heads/{branch}')
    prs = json.loads(run('gh', 'pr', 'list', '--repo', name, '--base', 'main', '--head', branch,
                         '--state', 'open', '--json', 'number,url,isDraft,labels'))
    if prs:
        pr = prs[0]
        if pr['isDraft'] or any(label['name'] == 'no-automerge' for label in pr['labels']):
            raise SystemExit('Existing PR is draft or opted out; leaving its policy unchanged: '+pr['url'])
        url = pr['url']
    else:
        title = args.title or run('git', 'log', '-1', '--format=%s')
        try:
            url = run('gh', 'pr', 'create', '--repo', name, '--base', 'main', '--head', branch,
                      '--title', title, '--body-file', args.body_file)
        except subprocess.CalledProcessError:
            # The GitHub fallback may have created the same PR after our push.
            prs = json.loads(run('gh', 'pr', 'list', '--repo', name, '--base', 'main', '--head', branch,
                                 '--state', 'open', '--json', 'number,url,isDraft,labels'))
            if not prs or prs[0]['isDraft'] or any(label['name'] == 'no-automerge' for label in prs[0]['labels']):
                raise
            url = prs[0]['url']
    # gh label create --force updates metadata only; it does not change branch rules.
    run('gh', 'label', 'create', 'agent-automerge', '--repo', name, '--color', '0969da',
        '--description', 'Trusted agent PR: merge after required checks; no-automerge opts out.', '--force')
    run('gh', 'pr', 'edit', url, '--add-label', 'agent-automerge')
    try:
        run('gh', 'pr', 'merge', url, '--auto', '--squash', '--match-head-commit', head)
    except subprocess.CalledProcessError:
        state = json.loads(run('gh', 'pr', 'view', url, '--json', 'state'))
        if state['state'] != 'MERGED':
            raise
    print(url)
    print('Protected squash auto-merge requested. Wait for merge or report failed checks/conflicts; queued is not merged.')


if __name__ == '__main__':
    try:
        main()
    except subprocess.CalledProcessError as error:
        sys.exit(error.returncode)

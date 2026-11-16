'use strict';

const MANAGED = 'agent-automerge';
const OPT_OUT = 'no-automerge';
const CI_PATH = '.github/workflows/ci.yml';
const isAgentBranch = branch => /^(agent|codex)\/.+/.test(branch || '');
const labels = pr => (pr.labels || []).map(label => label.name);
const sameRepository = (pr, id) => pr.head?.repo?.id === id && pr.base?.repo?.id === id && pr.base.ref === 'main';
const blocked = pr => pr.draft || labels(pr).includes(OPT_OUT);
const failed = run => run.status === 'completed' && !['success', 'neutral', 'skipped', 'action_required'].includes(run.conclusion);

async function automate({ github, context, core, mode = 'all' }) {
  const repo = context.repo;
  const { data: repository } = await github.rest.repos.get(repo);
  if (repository.fork || repository.default_branch !== 'main') return;
  // Read-scoped installation tokens omit these optional admin-visible fields.
  // Do not mistake absence for false or expand registration to admin permissions;
  // the merge/auto-merge APIs still enforce the actual repository settings.
  if (repository.allow_auto_merge === false || repository.allow_squash_merge === false) {
    throw new Error('Repository must allow auto-merge and squash merging; branch protection must remain enabled.');
  }
  const { data: ci } = await github.rest.actions.getWorkflow({ ...repo, workflow_id: 'ci.yml' });
  const permissionCache = new Map();
  async function writer(login) {
    if (!login) return false;
    if (!permissionCache.has(login)) {
      const { data } = await github.rest.repos.getCollaboratorPermissionLevel({ ...repo, username: login });
      permissionCache.set(login, ['admin', 'maintain', 'write'].includes(data.permission));
    }
    return permissionCache.get(login);
  }
  async function disable(pr) {
    if (pr.auto_merge) {
      await github.graphql('mutation($id:ID!){disablePullRequestAutoMerge(input:{pullRequestId:$id}){pullRequest{id}}}', { id: pr.node_id });
    }
  }
  async function register(pr) {
    if (blocked(pr)) return;
    if (!labels(pr).includes(MANAGED)) {
      try {
        await github.rest.issues.createLabel({ ...repo, name: MANAGED, color: '0969da', description: 'Trusted agent PR: merge after required checks; no-automerge opts out.' });
      } catch (error) { if (error.status !== 422) throw error; }
      await github.rest.issues.addLabels({ ...repo, issue_number: pr.number, labels: [MANAGED] });
    }
  }

  // workflow_run is privileged. Treat its payload as metadata only: never check out
  // the head, load artifacts/caches from it, or interpolate its strings into a shell.
  const run = context.payload.workflow_run;
  if (mode !== 'reconcile' && context.eventName === 'workflow_run' && run?.event === 'push' &&
      run.workflow_id === ci.id && run.path?.split('@')[0] === CI_PATH &&
      run.head_repository?.id === repository.id && isAgentBranch(run.head_branch) &&
      /^[0-9a-f]{40}$/.test(run.head_sha || '') && await writer(run.actor?.login)) {
    const { data: branch } = await github.rest.repos.getBranch({ ...repo, branch: run.head_branch });
    if (branch.commit.sha === run.head_sha) {
      const { data: comparison } = await github.rest.repos.compareCommitsWithBasehead({ ...repo, basehead: `main...${run.head_branch}` });
      const closed = await github.paginate(github.rest.pulls.list, { ...repo, state: 'closed', base: 'main', head: `${repo.owner}:${run.head_branch}`, per_page: 100 });
      // Squash leaves the old branch divergent; explicit closure also pauses
      // this head. Late CI must not recreate either PR without a new push SHA.
      const delivered = closed.some(pr => pr.head.sha === run.head_sha);
      if (comparison.ahead_by > 0 && !delivered) {
        const query = { ...repo, state: 'open', base: 'main', head: `${repo.owner}:${run.head_branch}` };
        let { data: existing } = await github.rest.pulls.list(query);
        let pr = existing[0];
        if (!pr) {
          const title = (run.head_commit?.message?.split('\n')[0] || `Agent: ${run.head_branch}`).slice(0, 240);
          try {
            ({ data: pr } = await github.rest.pulls.create({ ...repo, head: run.head_branch, base: 'main', title,
              body: '自动创建的 Agent PR。\n\n- 必须通过受保护 main 的全部必需检查。\n- 检查失败或冲突不会强行合并；落后于 main 时正常合入最新基线后重新检查。\n- 设为 Draft 或添加 `no-automerge` 标签可暂停自动交付。\n\n具体行为和验证范围见提交说明；CI 通过不等于真机验收。',
              maintainer_can_modify: true }));
          } catch (error) {
            if (error.status !== 422) throw error;
            ({ data: existing } = await github.rest.pulls.list(query));
            if (!existing[0]) throw error;
            pr = existing[0];
          }
        }
        if (sameRepository(pr, repository.id) && !blocked(pr)) await register(pr);
      }
    } else core.info('Ignoring stale push run: branch head has changed.');
  }

  if (mode === 'register') return;

  // Only opt-in PRs are reconciled. Old, unrelated and conflicting PRs are not
  // silently enrolled by a timer, a similarly named workflow, or a fork.
  const open = await github.paginate(github.rest.pulls.list, { ...repo, state: 'open', base: 'main', per_page: 100 });
  for (const item of open) {
    if (!labels(item).includes(MANAGED)) continue;
    const { data: pr } = await github.rest.pulls.get({ ...repo, pull_number: item.number });
    if (pr.state !== 'open' || !sameRepository(pr, repository.id) || !isAgentBranch(pr.head.ref)) continue;
    if (blocked(pr)) { await disable(pr); continue; }
    const bot = pr.user?.login === 'github-actions[bot]' && pr.user?.type === 'Bot';
    if (!bot && !await writer(pr.user?.login)) { await disable(pr); continue; }
    const { data: currentBranch } = await github.rest.repos.getBranch({ ...repo, branch: pr.head.ref });
    if (currentBranch.commit.sha !== pr.head.sha) continue;
    const { data: runs } = await github.rest.actions.listWorkflowRuns({ ...repo, workflow_id: ci.id, head_sha: pr.head.sha, per_page: 100 });
    const currentRuns = runs.workflow_runs.filter(r => r.head_sha === pr.head.sha &&
      r.head_repository?.id === repository.id && r.workflow_id === ci.id && r.path?.split('@')[0] === CI_PATH);
    // GitHub-token-created PRs can require workflow approval. Approve only this
    // known, same-repository CI for a registered trusted PR, never fork workflows
    // or deployment environments. No PR review or protection check is fabricated.
    for (const pending of currentRuns.filter(r => r.conclusion === 'action_required')) {
      await github.rest.actions.approveWorkflowRun({ ...repo, run_id: pending.id });
      core.info(`Approved CI workflow ${pending.id} for trusted PR #${pr.number}.`);
    }
    const { data: comparison } = await github.rest.repos.compareCommitsWithBasehead({ ...repo, basehead: `main...${pr.head.ref}` });
    const inFlight = currentRuns.some(r => r.status !== 'completed');
    const hasFailure = currentRuns.some(failed);
    const green = currentRuns.some(r => r.conclusion === 'success');
    if (comparison.behind_by > 0 && pr.mergeable === true && green && !inFlight && !hasFailure) {
      // The expected head protects against racing a new push; this is a regular
      // merge of main into the feature branch, not a force-push or reset.
      await github.rest.pulls.updateBranch({ ...repo, pull_number: pr.number, expected_head_sha: pr.head.sha });
      // update-branch is asynchronous (202). Never dispatch against its old
      // head; if it is still pending, the next reconciliation will find missing CI.
      for (let attempt = 0; attempt < 6; attempt++) {
        const { data: updated } = await github.rest.repos.getBranch({ ...repo, branch: pr.head.ref });
        if (updated.commit.sha !== pr.head.sha) {
          // Token pushes do not trigger push CI. Explicit dispatch is a supported
          // exception and the CI job still has only read permissions.
          await github.rest.actions.createWorkflowDispatch({ ...repo, workflow_id: ci.id, ref: pr.head.ref });
          break;
        }
        await new Promise(resolve => setTimeout(resolve, 1000));
      }
      core.info(`Requested protected base update for PR #${pr.number}; fresh-head CI will be reconciled.`);
      continue;
    }
    if (pr.mergeable === false || pr.mergeable_state === 'dirty') {
      core.warning(`PR #${pr.number} has conflicts; leaving it for its agent to resolve.`);
      continue;
    }
    if (!currentRuns.length) {
      await github.rest.actions.createWorkflowDispatch({ ...repo, workflow_id: ci.id, ref: pr.head.ref });
    }
    if (pr.mergeable_state === 'clean' && comparison.behind_by === 0 && green && !inFlight && !hasFailure) {
      // A queued auto-merge can remain pending after checks finish. This is the
      // ordinary protected merge endpoint, not admin bypass: GitHub rechecks all
      // branch rules, and sha makes a racing head change fail rather than merge.
      const { data: result } = await github.rest.pulls.merge({ ...repo, pull_number: pr.number, sha: pr.head.sha, merge_method: 'squash' });
      if (!result.merged) throw new Error(`Protected merge of PR #${pr.number} was not completed.`);
      core.info(`Completed protected squash merge for PR #${pr.number}.`);
      continue;
    }
    if (pr.mergeable === null) {
      core.info(`PR #${pr.number} mergeability is still being calculated; retry on the next event.`);
      continue;
    }
    if (!pr.auto_merge) {
      // Queue blocked PRs with GitHub's own protection rules. Never approve a
      // PR review, forge a status, force a merge, or use admin bypass.
      await github.graphql('mutation($id:ID!){enablePullRequestAutoMerge(input:{pullRequestId:$id,mergeMethod:SQUASH}){pullRequest{id}}}', { id: pr.node_id });
      core.info(`Queued protected squash auto-merge for PR #${pr.number}.`);
    }
  }
}

module.exports = automate;
module.exports.isAgentBranch = isAgentBranch;

'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const automate = require('./agent-pr.cjs');
const SHA = 'a'.repeat(40);
const NEXT = 'b'.repeat(40);
const REPO = { id: 42, default_branch: 'main', allow_auto_merge: true, allow_squash_merge: true, fork: false };
const ciRun = overrides => ({ id: 100, workflow_id: 7, path: '.github/workflows/ci.yml', event: 'push',
  head_sha: SHA, head_branch: 'agent/task', head_repository: { id: 42 }, actor: { login: 'writer' },
  status: 'completed', conclusion: 'success', ...overrides });
const pull = overrides => ({ number: 1, node_id: 'PR_1', state: 'open', draft: false, labels: [{ name: 'agent-automerge' }],
  head: { ref: 'agent/task', sha: SHA, repo: { id: 42 } }, base: { ref: 'main', repo: { id: 42 } },
  user: { login: 'writer', type: 'User' }, mergeable: true, mergeable_state: 'blocked', auto_merge: null, ...overrides });

function setup(options = {}) {
  const state = { prs: options.prs || [], runs: options.runs || [ciRun()], sha: SHA,
    comparison: { ahead_by: 1, behind_by: 0, ...options.comparison }, calls: [] };
  const record = (name, args) => state.calls.push([name, args]);
  const github = { rest: {
    repos: {
      get: async () => ({ data: { ...REPO, ...options.repository } }),
      getBranch: async () => ({ data: { commit: { sha: state.sha } } }),
      getCollaboratorPermissionLevel: async () => ({ data: { permission: options.permission || 'write' } }),
      compareCommitsWithBasehead: async () => ({ data: state.comparison }),
    },
    actions: {
      getWorkflow: async () => ({ data: { id: 7 } }),
      listWorkflowRuns: async () => ({ data: { workflow_runs: state.runs } }),
      approveWorkflowRun: async args => { record('approve-ci', args); },
      createWorkflowDispatch: async args => { record('dispatch-ci', args); },
    },
    issues: {
      createLabel: async args => { record('create-label', args); },
      addLabels: async args => {
        record('label', args);
        state.prs.find(p => p.number === args.issue_number).labels.push({ name: 'agent-automerge' });
      },
    },
    pulls: {
      list: async (args = {}) => ({ data: state.prs.filter(pr => !args.state || args.state === 'all' || pr.state === args.state) }),
      get: async args => ({ data: state.prs.find(p => p.number === args.pull_number) }),
      create: async args => {
        record('create-pr', args);
        const pr = pull({ labels: [], user: { login: 'github-actions[bot]', type: 'Bot' }, title: args.title });
        state.prs.push(pr); return { data: pr };
      },
      updateBranch: async args => { record('update-branch', args); state.sha = NEXT; },
      merge: async args => { record('protected-merge', args); return { data: { merged: true } }; },
    },
  }, paginate: async (method, args) => (await method(args)).data,
  graphql: async (query, args) => {
    const disabled = query.includes('disablePullRequest');
    record(disabled ? 'disable-auto' : 'enable-auto', args);
    state.prs.find(p => p.node_id === args.id).auto_merge = disabled ? null : { merge_method: 'squash' };
  } };
  const core = { info: () => {}, warning: text => record('warning', text) };
  const context = { repo: { owner: 'owner', repo: 'repo' }, eventName: options.event || 'workflow_run',
    payload: { workflow_run: options.run || ciRun() } };
  return { state, go: () => automate({ github, context, core, mode: options.mode }), count: name => state.calls.filter(([n]) => n === name).length };
}

test('only standard agent branch namespaces qualify', () => {
  for (const ref of ['agent/fix', 'codex/ui', 'agent/a/b']) assert.equal(automate.isAgentBranch(ref), true);
  for (const ref of ['main', 'fork/fix', 'release/v1', 'agent/', 'xagent/fix', undefined]) assert.equal(automate.isAgentBranch(ref), false);
});

test('a trusted current push creates one PR and queues squash; reruns are idempotent', async () => {
  const s = setup(); await s.go(); await s.go();
  assert.equal(s.count('create-pr'), 1); assert.equal(s.count('enable-auto'), 1);
  assert.equal(s.state.prs[0].labels[0].name, 'agent-automerge');
});

for (const [name, run, options] of [
  ['fork run', ciRun({ head_repository: { id: 999 } }), {}],
  ['impostor workflow ID', ciRun({ workflow_id: 999 }), {}],
  ['impostor workflow path', ciRun({ path: '.github/workflows/other.yml' }), {}],
  ['ordinary branch', ciRun({ head_branch: 'feature/handwritten' }), {}],
  ['read-only actor', ciRun(), { permission: 'read' }],
  ['PR run cannot enroll an old branch', ciRun({ event: 'pull_request' }), {}],
  ['stale SHA', ciRun({ head_sha: 'c'.repeat(40) }), {}],
]) test(`does not create or register a PR from ${name}`, async () => {
  const s = setup({ run, ...options }); await s.go();
  assert.equal(s.count('create-pr'), 0); assert.equal(s.count('enable-auto'), 0);
});

test('late CI after a squash merge does not reopen the delivered head', async () => {
  const s = setup({ prs: [pull({ state: 'closed', merged_at: '2026-01-01T00:00:00Z' })] }); await s.go();
  assert.equal(s.count('create-pr'), 0); assert.equal(s.count('enable-auto'), 0);
});

test('late CI respects an explicitly closed PR at the same head', async () => {
  const s = setup({ prs: [pull({ state: 'closed', merged_at: null })] }); await s.go();
  assert.equal(s.count('create-pr'), 0);
});

test('draft and no-automerge PRs are never registered by the fallback', async () => {
  for (const pr of [pull({ draft: true, labels: [] }), pull({ labels: [{ name: 'no-automerge' }] })]) {
    const s = setup({ prs: [pr] }); await s.go();
    assert.equal(s.count('label'), 0); assert.equal(s.count('enable-auto'), 0);
  }
});

test('draft and explicit opt-out cancel a previously queued auto-merge', async () => {
  for (const extra of [{ draft: true }, { labels: [{ name: 'agent-automerge' }, { name: 'no-automerge' }] }]) {
    const s = setup({ event: 'pull_request_target', prs: [pull({ ...extra, auto_merge: {} })] }); await s.go();
    assert.equal(s.count('disable-auto'), 1); assert.equal(s.count('enable-auto'), 0);
  }
});

test('registration does not need merge/update permissions; reconciliation never creates PRs', async () => {
  const registration = setup({ mode: 'register' }); await registration.go();
  assert.equal(registration.count('create-pr'), 1); assert.equal(registration.count('enable-auto'), 0);
  const reconciliation = setup({ mode: 'reconcile' }); await reconciliation.go();
  assert.equal(reconciliation.count('create-pr'), 0);
});

test('a PR that changes its base cannot be auto-merged into another branch', async () => {
  const s = setup({ event: 'schedule', prs: [pull({ base: { ref: 'release', repo: { id: 42 } } })] }); await s.go();
  assert.deepEqual(s.state.calls, []);
});

test('a timer does not enroll unrelated legacy PRs', async () => {
  const s = setup({ event: 'schedule', prs: [pull({ labels: [] })] }); await s.go();
  assert.equal(s.count('enable-auto'), 0); assert.equal(s.count('update-branch'), 0);
});

test('even a labeled fork PR cannot gain write-side actions', async () => {
  const s = setup({ event: 'schedule', prs: [pull({ head: { ref: 'agent/fork', sha: SHA, repo: { id: 999 } } })] }); await s.go();
  assert.deepEqual(s.state.calls, []);
});

test('a green behind branch is updated with an expected SHA and fresh read-only CI', async () => {
  const s = setup({ event: 'schedule', prs: [pull()], comparison: { behind_by: 1 } }); await s.go();
  assert.equal(s.count('update-branch'), 1); assert.equal(s.count('dispatch-ci'), 1);
  assert.equal(s.state.calls.find(([name]) => name === 'update-branch')[1].expected_head_sha, SHA);
  assert.equal(s.count('enable-auto'), 0);
});

test('failed or in-flight CI cannot be buried by automatic base updates or reruns', async () => {
  for (const run of [ciRun({ conclusion: 'failure' }), ciRun({ status: 'in_progress', conclusion: null })]) {
    const s = setup({ event: 'schedule', prs: [pull()], runs: [run], comparison: { behind_by: 1 } }); await s.go();
    assert.equal(s.count('update-branch'), 0); assert.equal(s.count('dispatch-ci'), 0);
    // Enrolling auto-merge does not bypass GitHub's required checks.
  }
});

test('conflicts are left intact without forced updates or a direct merge', async () => {
  const s = setup({ event: 'schedule', prs: [pull({ mergeable: false, mergeable_state: 'dirty' })], comparison: { behind_by: 2 } }); await s.go();
  assert.equal(s.count('update-branch'), 0); assert.equal(s.count('enable-auto'), 0);
});

test('only approval-required CI from this repository and exact current head is approved', async () => {
  const s = setup({ event: 'schedule', prs: [pull()], runs: [
    ciRun({ conclusion: 'action_required' }),
    ciRun({ id: 101, conclusion: 'action_required', head_repository: { id: 999 } }),
    ciRun({ id: 102, conclusion: 'action_required', head_sha: NEXT }),
    ciRun({ id: 103, conclusion: 'action_required', workflow_id: 8 }),
  ] }); await s.go();
  assert.equal(s.count('approve-ci'), 1);
  assert.equal(s.state.calls.find(([n]) => n === 'approve-ci')[1].run_id, 100);
});

test('missing CI requests explicit dispatch, never invents a success status', async () => {
  const s = setup({ event: 'schedule', prs: [pull()], runs: [] }); await s.go();
  assert.equal(s.count('dispatch-ci'), 1);
});

test('ready PR completion uses protected squash API with the exact head SHA', async () => {
  const s = setup({ event: 'schedule', prs: [pull({ mergeable_state: 'clean', auto_merge: {} })] }); await s.go();
  assert.equal(s.count('protected-merge'), 1);
  const args = s.state.calls.find(([n]) => n === 'protected-merge')[1];
  assert.equal(args.sha, SHA); assert.equal(args.merge_method, 'squash');
  assert.equal(s.count('enable-auto'), 0);
});

test('a ready-looking PR never merges while CI is pending, failing, or absent', async () => {
  for (const runs of [[], [ciRun({ conclusion: 'failure' })], [ciRun(), ciRun({ status: 'in_progress', conclusion: null })]]) {
    const s = setup({ event: 'schedule', prs: [pull({ mergeable_state: 'clean' })], runs }); await s.go();
    assert.equal(s.count('protected-merge'), 0);
  }
});

test('read-scoped repo metadata may omit optional merge settings without granting admin', async () => {
  const s = setup({ repository: { allow_auto_merge: undefined, allow_squash_merge: undefined } }); await s.go();
  assert.equal(s.count('create-pr'), 1);
});

test('repository settings fail closed, and an independent fork never operates upstream', async () => {
  await assert.rejects(setup({ repository: { allow_auto_merge: false } }).go(), /must allow/);
  const s = setup({ repository: { fork: true } }); await s.go(); assert.deepEqual(s.state.calls, []);
});

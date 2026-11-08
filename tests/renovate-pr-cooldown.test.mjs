#!/usr/bin/env node
// Behaviour test for the pr-cooldown script in
// .github/workflows/renovate-pr-cooldown.yml (ADR 0005, ADR 0014).
//
// The script block is extracted from the workflow and run against an
// in-memory model of a repository: commits with the change they carry,
// force-push history, earlier commit statuses, and the compare / GraphQL /
// status APIs the script uses. Every scenario checks the commit status the
// script sets; some also check how many API calls it needed.
//
// Node built-ins only, so it runs anywhere `node` exists. An optional first
// argument points at another copy of the workflow (for mutation checks).

import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const workflowPath = process.argv[2] || join(root, '.github/workflows/renovate-pr-cooldown.yml');
const workflow = readFileSync(workflowPath, 'utf8');

// Lines after `script: |-`, de-indented, until the block ends.
const extractScript = (text) => {
  const lines = text.split('\n');
  const start = lines.findIndex((line) => /^ {10}script: \|-\s*$/.test(line));
  assert.ok(start >= 0, 'script block not found in renovate-pr-cooldown.yml');
  const body = [];
  for (const line of lines.slice(start + 1)) {
    if (line.trim() !== '' && !line.startsWith(' '.repeat(12))) break;
    body.push(line.slice(12));
  }
  return body.join('\n');
};

const script = extractScript(workflow);
const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor;
const run = new AsyncFunction('github', 'context', 'core', 'require', 'process', script);

const dayMs = 24 * 60 * 60 * 1000;
const daysAgo = (days) => new Date(Date.now() - days * dayMs).toISOString().replace(/\.\d{3}Z$/, 'Z');

// A commit carries the change the PR proposes at that point: `change` is the
// list of added/removed lines, 'binary' for a diff without a patch, or
// 'missing' when the commit can no longer be compared.
const commit = (oid, ageDays, change) => ({ oid, committedDate: daysAgo(ageDays), change });
const v = (version, digest = 'aaa') => [
  '-    image: ghcr.io/example/app:1.0.0@sha256:000',
  `+    image: ghcr.io/example/app:${version}@sha256:${digest}`,
];
const patchOf = (change) => ['@@ -1,2 +1,2 @@', ' services:', ...change].join('\n');
// The fingerprint the workflow computes for a one-file change (compose.yaml).
const fingerprintOf = (change) => {
  const hash = createHash('sha256');
  hash.update('modified\0\0compose.yaml\n');
  for (const line of patchOf(change).split('\n')) if (line.startsWith('+') || line.startsWith('-')) hash.update(`${line}\n`);
  return hash.digest('hex');
};
// A status an earlier run set on a commit.
const record = (change, sinceDaysAgo, creator = 'github-actions[bot]') => ({
  context: 'pr-cooldown',
  creator: { login: creator },
  description: `Soaking: 3 day(s) left of 14-day cooldown (change ${fingerprintOf(change).slice(0, 16)} since ${daysAgo(sinceDaysAgo)})`,
});

const evaluate = async ({
  chain,
  pushes = [],
  pushTotal,
  records = {},
  author = 'renovate[bot]',
  branch = 'renovate/docker-gated-ghcr.io-example-app-1.x',
  historyError = false,
  reportedHead,
}) => {
  const commits = new Map();
  for (const c of [...chain, ...pushes.flatMap((p) => [p.before, p.after]).filter(Boolean)]) commits.set(c.oid, c);
  const head = chain[chain.length - 1];
  const statuses = [];
  const warnings = [];
  const calls = { compare: 0, statuses: 0, graphql: 0, getCommit: 0 };

  const github = {
    rest: {
      pulls: { list: 'pulls.list' },
      repos: {
        getCommit: async ({ ref }) => {
          calls.getCommit += 1;
          return { data: { commit: { committer: { date: commits.get(ref).committedDate } } } };
        },
        compareCommitsWithBasehead: async ({ basehead }) => {
          calls.compare += 1;
          const [base, sha] = basehead.split('...');
          assert.equal(base, 'main', 'compares against the PR base branch');
          const c = commits.get(sha);
          if (!c || c.change === 'missing') throw new Error('Not Found');
          if (c.change === 'binary') {
            return { data: { files: [{ filename: 'app.bin', status: 'modified', changes: 0 }] } };
          }
          return {
            data: { files: [{ filename: 'compose.yaml', status: 'modified', changes: c.change.length, patch: patchOf(c.change) }] },
          };
        },
        listCommitStatusesForRef: async ({ ref }) => {
          calls.statuses += 1;
          return { data: records[ref] ? [records[ref]] : [] };
        },
        createCommitStatus: async (status) => {
          statuses.push(status);
        },
      },
    },
    paginate: async () => {
      throw new Error('only pull_request events are used in this test');
    },
    graphql: async (query, variables) => {
      calls.graphql += 1;
      assert.match(query, /HEAD_REF_FORCE_PUSHED_EVENT/);
      assert.equal(variables.number, 7);
      if (historyError) throw new Error('GraphQL unavailable');
      const listed = reportedHead ? [...chain.slice(0, -1), reportedHead] : chain;
      return {
        repository: {
          pullRequest: {
            commits: {
              totalCount: listed.length,
              nodes: listed.map((c) => ({ commit: { oid: c.oid, committedDate: c.committedDate } })),
            },
            timelineItems: {
              totalCount: pushTotal ?? pushes.length,
              nodes: pushes.map((p) => ({
                createdAt: daysAgo(p.ageDays),
                beforeCommit: p.before ? { oid: p.before.oid, committedDate: p.before.committedDate } : null,
                afterCommit: p.after ? { oid: p.after.oid } : null,
              })),
            },
          },
        },
      };
    },
  };

  const pr = { number: 7, head: { sha: head.oid, ref: branch }, base: { ref: 'main' }, user: { login: author } };
  const context = { repo: { owner: 'DevSecNinja', repo: 'example' }, eventName: 'pull_request', payload: { pull_request: pr } };
  const core = { info: () => {}, warning: (message) => warnings.push(message) };
  const env = {
    COOLDOWN_DAYS: '14',
    GATED_PREFIXES: 'renovate/docker-gated-',
    BOT_LOGIN: 'renovate[bot]',
    STATUS_CONTEXT: 'pr-cooldown',
  };

  await run(github, context, core, createRequire(import.meta.url), { env });
  assert.equal(statuses.length, 1, 'exactly one status per PR');
  const [status] = statuses;
  assert.equal(status.sha, head.oid);
  assert.equal(status.context, 'pr-cooldown');
  assert.ok(status.description.length <= 140, 'status descriptions are capped at 140 characters');
  return { ...status, warnings, calls };
};

// Force pushes are listed oldest first, like the GraphQL timeline. `after`
// defaults to the `before` of the next push, or the current head.
const history = (chainHead, ...entries) =>
  entries.map((entry, i) => ({ ...entry, after: entry.after ?? (entries[i + 1] ? entries[i + 1].before : chainHead) }));

const expectSoaked = (status, name) =>
  assert.equal(status.state, 'success', `${name}: expected the cooldown to be met, got: ${status.description}`);
const expectDaysLeft = (status, days, name) => {
  assert.equal(status.state, 'pending', `${name}: expected pending, got: ${status.description}`);
  assert.match(status.description, new RegExp(`^Soaking: ${days} day\\(s\\) left of 14-day cooldown`), name);
};
const expectRecord = (status, change, name) =>
  assert.match(
    status.description,
    new RegExp(`change ${fingerprintOf(change).slice(0, 16)} since \\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}Z\\)$`),
    `${name}: the status must record the change for the next run`,
  );

const scenarios = {
  async 'never rebased, 10 days old'() {
    const status = await evaluate({ chain: [commit('r1', 10, v('1.1.0'))] });
    expectDaysLeft(status, 4, this.name);
    expectRecord(status, v('1.1.0'), this.name);
  },
  async 'never rebased, 15 days old'() {
    expectSoaked(await evaluate({ chain: [commit('r1', 15, v('1.1.0'))] }), this.name);
  },
  async 'rebased yesterday without changing the update keeps the clock'() {
    const head = commit('r2', 1, v('1.1.0'));
    expectSoaked(
      await evaluate({ chain: [head], pushes: history(head, { ageDays: 1, before: commit('r1', 15, v('1.1.0')) }) }),
      this.name,
    );
  },
  async 'several rebases, all keeping the update'() {
    const head = commit('r4', 0.5, v('1.1.0'));
    expectSoaked(
      await evaluate({
        chain: [head],
        pushes: history(
          head,
          { ageDays: 9, before: commit('r1', 16, v('1.1.0')) },
          { ageDays: 4, before: commit('r2', 9, v('1.1.0')) },
          { ageDays: 0.5, before: commit('r3', 4, v('1.1.0')) },
        ),
      }),
      this.name,
    );
  },
  async 'a newer version restarts the clock'() {
    const head = commit('r3', 3, v('1.3.0'));
    expectDaysLeft(
      await evaluate({
        chain: [head],
        pushes: history(
          head,
          { ageDays: 20, before: commit('r1', 25, v('1.1.0')) },
          { ageDays: 3, before: commit('r2', 20, v('1.2.0')) },
        ),
      }),
      11,
      this.name,
    );
  },
  async 'a rebase after a version bump counts from the bump'() {
    const head = commit('r4', 1, v('1.3.0'));
    expectDaysLeft(
      await evaluate({
        chain: [head],
        pushes: history(
          head,
          { ageDays: 20, before: commit('r1', 25, v('1.1.0')) },
          { ageDays: 6, before: commit('r2', 20, v('1.2.0')) },
          { ageDays: 1, before: commit('r3', 6, v('1.3.0')) },
        ),
      }),
      8,
      this.name,
    );
  },
  async 'a re-pushed digest for the same version restarts the clock'() {
    const head = commit('r2', 1, v('1.1.0', 'bbb'));
    expectDaysLeft(
      await evaluate({ chain: [head], pushes: history(head, { ageDays: 1, before: commit('r1', 15, v('1.1.0', 'aaa')) }) }),
      13,
      this.name,
    );
  },
  async '"Update branch" merge commit keeps the clock'() {
    expectSoaked(
      await evaluate({ chain: [commit('r1', 15, v('1.1.0')), commit('m1', 1, v('1.1.0'))] }),
      this.name,
    );
  },
  async 'a merge that changes the update restarts the clock'() {
    expectDaysLeft(
      await evaluate({ chain: [commit('r1', 15, v('1.1.0')), commit('m1', 2, v('1.1.1'))] }),
      12,
      this.name,
    );
  },
  async 'a commit pushed on top with another change restarts the clock'() {
    expectDaysLeft(
      await evaluate({ chain: [commit('r1', 15, v('1.1.0')), commit('h1', 2, [...v('1.1.0'), '+    restart: always'])] }),
      12,
      this.name,
    );
  },
  async 'a change pushed between two force pushes counts from the newer one'() {
    // r1 (1.1.0) was force-pushed at 20d; a human then pushed h1 (1.2.0) on
    // top; a rebase at 2d kept 1.2.0. The change arrived after the older push.
    const head = commit('r2', 2, v('1.2.0'));
    expectDaysLeft(
      await evaluate({
        chain: [head],
        pushes: [
          { ageDays: 20, before: commit('r0', 25, v('1.0.5')), after: commit('r1', 20, v('1.1.0')) },
          { ageDays: 2, before: commit('h1', 15, v('1.2.0')), after: head },
        ],
      }),
      12,
      this.name,
    );
  },
  async 'a force-pushed-away commit that cannot be compared counts as a change'() {
    const head = commit('r2', 1, v('1.1.0'));
    const status = await evaluate({ chain: [head], pushes: history(head, { ageDays: 1, before: commit('gone', 15, 'missing') }) });
    expectDaysLeft(status, 13, this.name);
    assert.ok(status.warnings.some((w) => w.includes('main...gone')), 'warns about the failed comparison');
  },
  async 'a force push without a before commit counts as a change'() {
    const head = commit('r2', 1, v('1.1.0'));
    expectDaysLeft(await evaluate({ chain: [head], pushes: [{ ageDays: 1, before: null, after: head }] }), 13, this.name);
  },
  async 'more force pushes than inspected count from the oldest inspected'() {
    const head = commit('r3', 1, v('1.1.0'));
    expectDaysLeft(
      await evaluate({
        chain: [head],
        pushes: history(
          head,
          { ageDays: 5, before: commit('r1', 6, v('1.1.0')) },
          { ageDays: 1, before: commit('r2', 5, v('1.1.0')) },
        ),
        pushTotal: 150,
      }),
      9,
      this.name,
    );
  },
  async 'the walk stops once the change predates the cooldown'() {
    // The oldest commit can no longer be compared, but the walk never needs it.
    const head = commit('r3', 1, v('1.1.0'));
    const status = await evaluate({
      chain: [head],
      pushes: history(
        head,
        { ageDays: 30, before: commit('gone', 40, 'missing') },
        { ageDays: 15, before: commit('r1', 30, v('1.1.0')) },
        { ageDays: 1, before: commit('r2', 15, v('1.1.0')) },
      ),
    });
    expectSoaked(status, this.name);
    assert.equal(status.warnings.length, 0, 'never compares the commit it does not need');
  },
  async 'a very long history is capped and counted conservatively'() {
    const head = commit('r60', 0, v('1.1.0'));
    const entries = Array.from({ length: 60 }, (_, i) => ({ ageDays: 6 - i * 0.1, before: commit(`r${i}`, 7 - i * 0.1, v('1.1.0')) }));
    const status = await evaluate({ chain: [head], pushes: history(head, ...entries) });
    assert.equal(status.state, 'pending', `${this.name}: ${status.description}`);
    assert.ok(status.calls.compare <= 52, `${this.name}: compare calls are capped (got ${status.calls.compare})`);
  },
  async 'a recorded status on the head is reused without comparing'() {
    const head = commit('r2', 1, v('1.1.0'));
    const status = await evaluate({
      chain: [head],
      pushes: history(head, { ageDays: 1, before: commit('r1', 20, v('1.1.0')) }),
      records: { r2: record(v('1.1.0'), 20) },
    });
    expectSoaked(status, this.name);
    assert.deepEqual(status.calls, { compare: 0, statuses: 1, graphql: 0, getCommit: 0 }, `${this.name}: one call only`);
  },
  async 'after a rebase, the record on the replaced commit carries the clock over'() {
    // r1 was evaluated before the rebase; its record says 1.1.0 since 20d,
    // although the history before it is no longer comparable.
    const head = commit('r2', 0.1, v('1.1.0'));
    const status = await evaluate({
      chain: [head],
      pushes: history(
        head,
        { ageDays: 25, before: commit('gone', 30, 'missing') },
        { ageDays: 0.1, before: commit('r1', 20, v('1.1.0')) },
      ),
      records: { r1: record(v('1.1.0'), 20) },
    });
    expectSoaked(status, this.name);
    assert.equal(status.calls.compare, 1, `${this.name}: only the new head is compared`);
  },
  async 'a record for a different change marks the force push as the change'() {
    const head = commit('r2', 2, v('1.2.0'));
    expectDaysLeft(
      await evaluate({
        chain: [head],
        pushes: history(head, { ageDays: 2, before: commit('r1', 20, v('1.1.0')) }),
        records: { r1: record(v('1.1.0'), 20) },
      }),
      12,
      this.name,
    );
  },
  async 'a record written by another identity is ignored'() {
    const head = commit('r2', 1, v('1.1.0'));
    expectDaysLeft(await evaluate({ chain: [head], records: { r2: record(v('1.1.0'), 30, 'mallory') } }), 13, this.name);
  },
  async 'a diff without patches falls back to the head commit date'() {
    const head = commit('r2', 1, 'binary');
    const status = await evaluate({ chain: [head], pushes: history(head, { ageDays: 1, before: commit('r1', 15, 'binary') }) });
    expectDaysLeft(status, 13, this.name);
    assert.match(status.description, /head commit: diff not comparable/);
  },
  async 'unreadable history falls back to the head commit date'() {
    const status = await evaluate({ chain: [commit('r2', 1, v('1.1.0'))], historyError: true });
    expectDaysLeft(status, 13, this.name);
    assert.match(status.description, /head commit: history unavailable/);
  },
  async 'a branch that moved during evaluation falls back to the head commit date'() {
    const status = await evaluate({ chain: [commit('r2', 1, v('1.1.0'))], reportedHead: commit('r3', 0, v('1.1.0')) });
    expectDaysLeft(status, 13, this.name);
    assert.match(status.description, /branch moved during evaluation/);
  },
  async 'PRs by others are not gated'() {
    const status = await evaluate({ chain: [commit('h1', 0, v('9.9.9'))], author: 'DevSecNinja' });
    assert.equal(status.state, 'success');
    assert.equal(status.description, 'No cooldown required');
  },
  async 'Renovate branches without the gated prefix are not gated'() {
    const status = await evaluate({ chain: [commit('r1', 0, v('1.1.0'))], branch: 'renovate/all-non-major' });
    assert.equal(status.state, 'success');
    assert.equal(status.description, 'No cooldown required');
  },
};

let passed = 0;
const total = Object.keys(scenarios).length;
for (const [name, scenario] of Object.entries(scenarios)) {
  try {
    await scenario.call({ name });
    passed += 1;
  } catch (error) {
    console.error(`✖ ${name}\n  ${error.message}`);
    process.exitCode = 1;
  }
}
if (process.exitCode) {
  console.error(`✖ ${total - passed} of ${total} pr-cooldown scenarios failed.`);
} else {
  console.log(`✓ pr-cooldown: ${passed} scenarios set the expected status (rebases keep the soak, changes restart it).`);
}

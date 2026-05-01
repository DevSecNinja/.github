# Workflow trigger conventions

Org-wide rules for how GitHub Actions workflows in `DevSecNinja/*` repos
configure their `on:` triggers, `concurrency:` blocks, and Grafana IRM
paging. The aim is to make every Actions run pull its weight — no
duplicate executions, no silent skips, no runaway concurrent runs.

## Why this exists

A small flurry of commits to a PR can fire lint + test on the PR, then
again on `push: main` after merge, and once more on release-please's
response to that same push. Multiply by the set of checks branch
protection requires and the noise drowns out signal — and burns Actions
minutes for nothing.

This doc lays down the rules. They're conservative defaults; deviate
when a workflow genuinely needs more, but document the reason in the
workflow file.

---

## Trigger surface

**Default for CI workflows: `on: pull_request` only.**
Branch protection guarantees the merge commit is identical to the last
PR head that passed checks, so re-running the same lint/test on
`push: main` immediately after merge is duplicate work.

Keep `push: branches: [main]` **only** when the workflow has
post-merge-only work to do:

- **Documentation publishing** (e.g. `docs.yml` deploys mkdocs/Pages
  from `main`).
- **release-please** (`release-please.yml` must run on every commit to
  `main` to keep the release PR up to date).
- **Scheduled scans that also want a `main` snapshot** (e.g.
  `image-security.yml` runs weekly and on push to `main` so the latest
  shipped image set is always represented).
- **Label / repo config workflows** where the PR run validates and the
  `main` run applies (e.g. `label-sync.yml`).
- **TODO-to-issue conversion** (`todo-to-issue.yml`) — only meaningful
  on the integrated `main` history.

**Avoid `pull_request_target`** unless absolutely required. It runs the
target-branch workflow with write tokens against PR-author code, and
mis-configuration is a well-known supply-chain footgun. If you must use
it, restrict to specific event types (e.g. `[labeled]`) and never check
out the PR head with the elevated token.

---

## Concurrency

Always set workflow-level concurrency. The right shape depends on
whether mid-run cancellation is safe.

**For PR-validation CI (lint / test) — cancellable:**

```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.event.pull_request.number || github.ref }}
  cancel-in-progress: true
```

This collapses redundant runs when a contributor pushes several commits
in a row. The `pull_request.number || github.ref` fallback keeps groups
distinct between PR runs and any `push` runs of the same workflow.

**For release / docs-publish / release-please — NOT cancellable:**

```yaml
concurrency:
  group: <stable-name>-${{ github.ref }}
  cancel-in-progress: false
```

Mid-run cancellation can corrupt state: half-uploaded release assets,
partially-deployed Pages builds, release-please's own retry-on-empty-PR
logic interrupted mid-write. Let the run finish; queue the next one.

**Reusable workflows (`on: workflow_call`) generally should not declare
their own concurrency** — the caller owns it. A reusable that sets its
own group can collide with the caller's group across repos and serialize
unrelated runs.

---

## Draft PRs

GitHub fires `pull_request` events on draft PRs by default. We do
**not** add `if: github.event.pull_request.draft == false` guards.

release-please opens its release PRs as draft on purpose
(`draft-pull-request: true`) so contributors can spot them mid-cycle
without merging by accident. If we skip CI on drafts, the
required-status-checks list is never satisfied and the release PR can't
merge — defeating the whole flow.

If a particular workflow is genuinely too expensive to run on drafts
(e.g. multi-hour image scans), gate that _job_ on a label
(`if: contains(github.event.pull_request.labels.*.name, 'full-scan')`)
rather than on draft state.

---

## Path filters

We avoid `paths:` / `paths-ignore:` on workflows whose checks are
**required by branch protection**. The interaction is fragile: a
required check that's _skipped_ via path filter blocks merge until you
add a no-op "skipped means success" job — more complexity than the
filter saves.

Path filters are fine on workflows that are **not** required to merge
(scheduled scans, optional previews, advisory jobs).

---

## Notify Grafana IRM

The `notify-irm` job pages the homelab on-call via the composite action
at
[`DevSecNinja/.github/.github/actions/notify-irm`](../actions/notify-irm/).
Conventions:

1. **Gate on `github.ref == 'refs/heads/main'` only.** Do _not_ also
   gate on `github.event_name == 'push'` — that silently skips paging
   on `workflow_dispatch` reruns, which is exactly when an operator is
   most likely to need confirmation that the rerun succeeded or paged.
   See
   [DevSecNinja/dotfiles#265](https://github.com/DevSecNinja/dotfiles/pull/265)
   and
   [DevSecNinja/truenas-apps#317](https://github.com/DevSecNinja/truenas-apps/pull/317).
2. **Don't add `notify-irm` to PR-only CI workflows** (lint, test,
   `ci`). Without `push: main` it's unreachable, and pages on
   PR-validation are low-value: failed PRs can't merge anyway, and the
   author is already looking at the run.
3. **Page on workflows that produce real artifacts or modify shared
   state**: deploy, release publish, release-please, docs publish,
   scheduled scans.
4. Always shape the job like:

   ```yaml
   notify-irm:
     needs: [<previous jobs>]
     if: ${{ always() && github.ref == 'refs/heads/main' }}
     uses: DevSecNinja/.github/.github/workflows/notify-irm.yml@<sha> # vX.Y.Z
     with:
       job-failed: ${{ contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled') }}
   ```

   `always()` is required so the job runs even when an upstream job
   failed; the explicit `cancelled` check ensures cancellations also
   page (otherwise a stuck deploy that an operator cancels looks like
   a green run from IRM's point of view).

---

## Release flow with release-please

release-please uses a draft-then-publish pattern with an opt-in
`release-please.yml` per repo. The configuration that works reliably
across the org:

- `release-please-config.json`: `skip-github-release: false`,
  `draft: true`, `force-tag-creation: true`, `draft-pull-request: true`.
- After the release PR merges, release-please pushes the `vX.Y.Z` tag
  and creates a _draft_ GitHub Release with the changelog body.
- A separate caller workflow (e.g. `release.yml`) listens on
  `push: tags: ["v*"]`, fetches the draft body via
  `gh release view --json body --jq .body`, builds / uploads / attests
  artifacts, then flips `--draft=false` to publish.

**Trigger downstream release workflows on `push: tags`, NOT on
`release: created`.** The `release: created` event from
release-please's GitHub App token does not propagate reliably to
workflows in the same repo — tag-push events do. See
[DevSecNinja/dotfiles#263](https://github.com/DevSecNinja/dotfiles/pull/263)
and
[DevSecNinja/dotfiles#266](https://github.com/DevSecNinja/dotfiles/pull/266)
for the diagnosis trail.

The draft-publish pattern is also compatible with **Immutable
Releases** — the API only constrains a Release once it's been
published, so the draft can be edited freely up until the final flip.

`workflow_dispatch` as a manual escape hatch is fine for one-offs
(re-publish a botched release, etc.) but tightens immutability if
removed once the tag-push path is proven.

See
[DevSecNinja/truenas-apps#325](https://github.com/DevSecNinja/truenas-apps/pull/325)
for an end-to-end example caller.

---

## Conventional Commits gate

The `commit-msg` lefthook (where used) verifies messages with
`cog verify`. PRs that squash-merge should ensure the _squash title_
also follows Conventional Commits — that's the line release-please
parses. Use the GitHub merge-queue / "default to PR title" repo setting
to make this automatic.

---

## Quick reference

| Workflow type               | Triggers                                                    | Concurrency   | Notify IRM |
| --------------------------- | ----------------------------------------------------------- | ------------- | ---------- |
| Lint / test (PR-validation) | `pull_request`                                              | cancel=true   | no         |
| Docs publish                | `push: main`, `pull_request` (preview-only)                 | cancel=false  | yes        |
| release-please              | `push: main`, `workflow_dispatch`                           | cancel=false  | yes        |
| Release publish             | `push: tags ["v*"]`                                         | cancel=false  | yes        |
| Image security scan         | `schedule`, `workflow_dispatch`, `pull_request`             | cancel=false  | yes        |
| Label sync                  | `push: main` (apply), `pull_request` (validate), `schedule` | cancel=false  | optional   |
| TODO-to-issue               | `push: main`                                                | n/a           | optional   |
| Reusable workflow           | `workflow_call`                                             | none (caller) | n/a        |

---

## Related docs

- [`docs/release-please-onboarding.md`](release-please-onboarding.md) —
  the release flow these conventions assume.
- [`docs/architecture.md`](architecture.md) — fleet architecture
  overview and reusable-workflow catalogue.

# ADR 0012: Rebase automerge branches when they fall behind

## Status

Accepted. Supersedes the global `rebaseWhen: "conflicted"` of
[ADR 0010](0010-batch-renovate-updates-to-save-actions-minutes.md); amends
[ADR 0005](0005-pr-age-cooldown-for-untrusted-timestamps.md) (strict branch
protection).

## Context

[ADR 0010](0010-batch-renovate-updates-to-save-actions-minutes.md) set
`rebaseWhen: "conflicted"` in `.renovate/base.json5` for every repository, so
Renovate stopped rebasing open PRs each time `main` moved. It saved Actions
minutes, but it works against the automerge policy of
[ADR 0004](0004-automerge-non-major-after-soak.md):

- Renovate's documentation says `rebaseWhen=conflicted` "is not recommended if
  you have enabled Renovate automerge", because two updates can be merged one
  after another without being tested together, and because automerge stops
  working as soon as a PR falls behind in a repository that requires branches
  to be up to date.
- Branch automerge (`automergeType: "branch"`: lock-file maintenance and the
  dotfiles devcontainer rule) needs the branch to be current. When `main` has
  moved, Renovate's branch worker sees the merge status `stale`, and with
  `rebaseWhen` `conflicted` or `never` it logs "Branch cannot automerge because
  it is behind base branch and rebaseWhen setting disallows rebasing - raising
  a PR instead" (`lib/workers/repository/update/branch/index.ts`). The
  no-PR, no-CI path silently turns into a PR.

The user standardised on requiring branches to be up to date before merging
("strict" required status checks) on public repositories, so CI always tests
exactly what lands on `main`. Neither alternative to strict mode is available:
a merge queue, which tests PRs against the latest base without making authors
update them, is only available for repositories owned by an organization, and
DevSecNinja repositories are owned by a personal account.

Meanwhile the CI cost of rebasing is already bounded by other ADR 0010
settings: one weekly `all-non-major` PR instead of one per dependency, a
Saturday-only schedule, and `updateNotScheduled: false` (Renovate does not push
to open branches outside the window).

## Decision

1. **`rebaseWhen: "auto"` globally** (Renovate's default, stated explicitly in
   `base.json5`). Renovate resolves it per branch
   (`determineRebaseWhenValue` in `lib/workers/repository/update/branch/reuse.ts`)
   to `behind-base-branch` when the branch automerges, has the keep-updated
   label, or the repository requires up-to-date branches; to `conflicted` when
   the base branch has a merge queue or none of those apply.
2. **The docker-gated rule keeps `rebaseWhen: "conflicted"`.** The
   `pr-cooldown` check measures the age of the PR head commit
   ([ADR 0005](0005-pr-age-cooldown-for-untrusted-timestamps.md)); a rebase
   rewrites that commit and restarts the 14-day clock.
3. **Strict required status checks on public repositories**, with one
   exception: **repositories that require `pr-cooldown` keep strict off**
   (today only `truenas-apps`). Under strict protection a behind-base gated PR
   can only merge after "Update branch" or a rebase, both of which create a new
   head commit and restart the cooldown, so on an active repository it would
   never merge. Lifting this exception needs a cooldown that is not reset by
   rebases.
4. No per-repository `rebaseWhen` override is needed any more:
   ADR 0010 asked strict repositories to set `rebaseWhen: "behind-base-branch"`
   themselves; `auto` already resolves to that for them.

## Alternatives considered

- **Keep `conflicted` globally.** Rejected: automerged updates can land
  untested together, automerge stalls on strict repositories, and branch
  automerge degrades to PRs.
- **`behind-base-branch` globally.** Rejected: it also rebases PRs that do not
  automerge in non-strict repositories, which buys nothing; `auto` rebases
  exactly where it matters.
- **A merge queue instead of strict checks.** Not available to repositories
  owned by a personal account.
- **Leave strict protection off.** Rejected by the user: an up-to-date
  requirement is the only way to guarantee CI tested the merge result.

## Consequences

- An open automerge PR that falls behind `main` is rebased (and its CI re-run)
  on Renovate's next run inside the Saturday window. With the weekly group
  that is usually one PR, so the extra cost is small and bounded by the window.
- Lock-file maintenance and the dotfiles devcontainer image are rebased and
  branch-merged again instead of turning into PRs.
- Automerged updates are tested against the latest `main` before they merge.
- Gated (`docker-gated-`) PRs are unchanged and still only merge in
  repositories without strict protection.

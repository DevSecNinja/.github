# ADR 0014: Measure the pr-cooldown soak from the proposed change

## Status

Accepted. Amends [ADR 0005](0005-pr-age-cooldown-for-untrusted-timestamps.md)
(what the cooldown measures) and lifts the `pr-cooldown` exception of
[ADR 0013](0013-rebase-automerge-branches-when-behind.md).

## Context

[ADR 0005](0005-pr-age-cooldown-for-untrusted-timestamps.md) enforces a 14-day
soak for Docker images from registries without a trusted release timestamp:
those Renovate branches carry the `renovate/docker-gated-` prefix, and the
required `pr-cooldown` status only turns green once the PR is old enough. "Old
enough" meant the **committer date of the PR head commit**, so that a newer
version restarts the clock.

But a rebase also creates a new head commit. To keep the clock running, gated
PRs used `rebaseWhen: "conflicted"`, which only works without "require branches
to be up to date" protection: under strict protection a gated PR that falls
behind `main` can only merge after "Update branch" or a rebase, and both
restart the cooldown, so it never merges on an active repository.
[ADR 0013](0013-rebase-automerge-branches-when-behind.md) therefore had to keep
`truenas-apps` (the only repository requiring `pr-cooldown`) non-strict, while
the standard is strict protection on every public repository. The head-commit
clock was already wrong without strict protection: in `truenas-apps`, a mass
rebase on 2026-10-26 restarted the clock of `#886` (frigate 0.18.2, proposed
since 2026-10-16) and `#908` (karakeep 0.34.1, since 2026-10-22) although
neither update changed.

The soak is about the **update**, not about a commit. It should restart when
what the PR proposes changes — a newer version, or the same tag re-pushed with
a different digest — and survive anything that only moves the branch.

## Decision

`renovate-pr-cooldown.yml` measures how long the **change the PR proposes** has
been on its branch:

1. **Fingerprint.** The change is the set of added and removed lines of the
   three-dot diff `base...head` (the compare API diffs from the merge base),
   hashed with SHA-256 together with each file's name and status. A rebase or a
   merge from the base branch leaves it unchanged; a new version or digest
   changes it. A diff whose files lack a patch (binary, oversized), or that hits
   the compare API's 300-file cap, cannot be fingerprinted.
2. **Trace.** The start of the soak is when that fingerprint first appeared,
   found from the PR's history (GraphQL): first the commits on the branch
   (pushes on top, such as "Update branch" merges or human commits), then the
   force-push timeline, newest first, comparing the commit each push replaced.
   The trace stops at the first push that brought a different change, or as soon
   as the change is known to predate the cooldown window.
3. **Record.** Every status records what it found:
   `change <first 16 hex> since <ISO time>`. A later run reuses the record on the
   same commit (scheduled re-evaluation: one API call) or on the commit the
   newest force push replaced (a rebase: a few calls), instead of walking the
   whole history again. Only the latest status in the `pr-cooldown` context
   written by `github-actions[bot]` (the workflow token) is trusted.
4. **Fail towards waiting.** Anything that cannot be established — a diff
   without patches, an unreadable history, a branch that moves during
   evaluation — falls back to the old head-commit date. Every shortcut (history
   not inspected, more than 50 comparisons, a force-pushed-away commit that can
   no longer be compared) returns a _later_ start, never an earlier one.
5. **Gated PRs rebase like everything else.** The docker-gated rule no longer
   sets `rebaseWhen: "conflicted"`; the global `auto` applies, so Renovate
   rebases gated PRs that fall behind, and they merge under strict protection.
   With that, no preset rule sets `conflicted` (enforced by
   `tests/renovate-batching-contract.sh`), and the dotfiles devcontainer rule no
   longer needs to override it.

## Alternatives considered

- **Use the PR title.** Renovate renames the PR when the version changes, so
  the newest `renamed` timeline event marks the change. Rejected: a tag
  re-pushed with a different digest keeps the title, which would let a swapped
  image skip the soak — exactly what the soak guards against.
- **Have Renovate record a timestamp.** Renovate writes no proposal time into
  the branch or PR (its PR-body metadata holds versions, not times), and
  Mend-hosted Renovate cannot run custom post-upgrade commands.
- **Keep `conflicted` and update the branch only once soaked** (pr-cooldown
  adding Renovate's keep-updated label, or calling "Update branch" with the App
  token). Fewer CI runs on soaking PRs, but it needs write permissions the
  check does not have today (a breaking change for callers), and a merge commit
  from another identity makes Renovate treat the branch as modified and stop
  maintaining it. Could still be added on top of this design.
- **Walk the full history on every run, without records.** Correct, but
  `truenas-apps` alone has gated PRs with up to 48 force pushes and `main` moves
  about twice a day; repeated walks would approach the 1,000-requests-per-hour
  limit of the workflow token. Measured on its 10 gated PRs: 48 API calls for a
  first run without records, then about 1 per PR.
- **Patch-ids per commit** (`git patch-id`). Equivalent to the fingerprint but
  needs a clone with the full history in the check; the compare API gives the
  same information without one.

## Consequences

- Gated PRs merge under "require branches to be up to date" protection, so
  strict protection can be the standard on every public repository, including
  `truenas-apps`.
- Rebases no longer restart the soak; only a different proposed change does.
  Gated PRs whose update was proposed long ago (like `#886` and `#908` above)
  become mergeable once the new check runs.
- Renovate now rebases gated PRs whenever they fall behind (inside the
  repository's schedule), which re-runs their CI. In `truenas-apps`, whose own
  schedule is "at any time", that means CI runs on soaking gated PRs as `main`
  moves — free on a public repository, but more queue time.
- Each status description now carries the change fingerprint and its start,
  which also makes the soak easy to audit.
- During the rollout, a caller still pinned to an older `renovate-pr-cooldown`
  restarts a gated PR's clock when Renovate rebases it. That self-heals: the new
  version recomputes the start from the PR's history on its first run, so
  callers should bump the pin before enabling strict protection.
- The trust boundary is unchanged: anyone who can forge a `pr-cooldown` status
  with the workflow token (a workflow with `statuses: write` in the same
  repository) could already set the status to success directly.

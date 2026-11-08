# ADR 0010: Batch Renovate updates and consolidate CI jobs to save Actions minutes

## Status

Accepted

## Context

Private repositories get a fixed monthly allowance of GitHub Actions minutes;
public repositories do not consume it. In October 2026 the private
repositories used exactly the 2,000 included Linux minutes and hit the cap on
October 30. Roughly 97% of those minutes were triggered by `renovate[bot]`.

Three effects multiplied each other:

1. **Every job is billed at least one full minute.** A job that runs for nine
   seconds costs a minute. The shared [`lint.yml`](../../.github/workflows/lint.yml)
   fans out into one job per linter (about eleven), so a lint run costs about
   eight minutes even when every linter finishes in seconds — 37 lint runs cost
   296 minutes in one repository. A sampled [`pages.yml`](../../.github/workflows/pages.yml)
   run in which only `Validate inputs` (4 s) and `Detect Cloudflare
   configuration` (5 s) ran, with everything else skipped, was still billed
   two minutes.
2. **Renovate pushes far more often than it ships.** With the ADR 0004
   automerge policy, Renovate's default `rebaseWhen: auto` resolves to
   `behind-base-branch`, so every automerge rebased every other open Renovate
   PR, and every rebase re-ran CI on all of them. One PR per dependency for
   frequently releasing tools (mise, wrangler, …) made it worse: one repository
   ran its Pages workflow 244 times for only 12 Renovate branches (55 runs for
   `renovate/mise` alone).
3. **Events that cannot change the result still start runs.** Renovate edits
   its PR bodies on most runs, which fires `pull_request: edited`; closing a
   Renovate PR ran the Pages workflow only to skip preview cleanup; Renovate's
   Dependency Dashboard issue edits fired the issue labeler.

A separate bug added failed runs on top: `actions/open-pr` pushed with a bare
`--force-with-lease`, which a fresh checkout cannot satisfy when the working
branch already exists on the remote, so the weekly config sync failed in every
private repository with `! [rejected] … (stale info)`.

## Decision

Apply the savings centrally, for every repository, so callers inherit them by
bumping a pin (workflows) or automatically (Renovate presets are read from
`main`).

### Renovate (`.renovate/`)

- **One weekly PR for all non-major updates** (`groups.json5`): every
  `minor`, `patch`, `pin`, `pinDigest` and `digest` update joins the
  `all non-major dependencies` group (branch `renovate/all-non-major`). The rule
  is the last one in `groups.json5`, so it overrides the specific groups (mise,
  postgres, vite, chezmoi) for non-major updates — those still land together,
  just in the weekly PR — while the specific groups keep their own PRs for
  major updates.
- **Opt-outs keep their own branch** (`packageRules.json5`, after the group):
  every `docker-gated-` dependency (ADR 0005) and the dotfiles devcontainer
  image set `groupName: null`. A gated dependency inside the group would lose
  the `renovate/docker-gated-` prefix, so the `pr-cooldown` gate would not see
  it and it would auto-merge with no soak at all; and each new release of any
  grouped dependency would reset its cooldown clock.
- **`rebaseWhen: "conflicted"` globally** (`base.json5`), previously only on
  the gated rule. Branch protection is non-strict, so a behind-base PR still
  auto-merges.
- **A single weekly window**: `* 0-7 * * 6` (Saturday 00:00–07:59
  Europe/Amsterdam) instead of Friday plus the whole weekend. Automerge is
  unaffected: GitHub merges once checks pass, whenever that is.
- **Monthly lock-file maintenance** (`* 0-7 1 * *`) instead of Renovate's
  weekly default.
- **Vulnerability fixes stay immediate and separate**: `vulnerabilityAlerts`
  explicitly keeps `groupName: null` and `schedule: ["at any time"]` (Renovate's
  defaults, made explicit). Major updates are never grouped and stay manual.

`tests/renovate-batching-contract.sh` enforces the rule order this depends on.

### Workflows

- **Single-job lint** (`lint.yml`): a new `lint-job-mode` input. `single` runs
  every enabled linter as a step of one `all linters` job (one billed job, mise
  installed once); `parallel` keeps one job per linter; `auto` (default) picks
  `single` for private repositories (`github.event.repository.private`) and
  `parallel` for public ones, where minutes are free and per-linter checks give
  clearer signal. Linter steps use `continue-on-error` and a final step reports
  every failure, so one failing linter does not hide the others.
  `tests/lint-job-modes-contract.sh` keeps the two copies of each linter script
  identical.
- **Pages event gating** (`pages.yml`): `validate-inputs`, which every other
  job needs, is skipped for `pull_request: edited` events that do not change
  the base branch, and for `closed` events where no preview can exist
  (Renovate/Dependabot PRs, fork PRs, previews disabled) — so those events
  bill zero minutes. `detect-cloudflare` is skipped for Renovate/Dependabot PRs,
  which never get previews. Bot PRs are recognised by PR author as well as
  actor, so a human pressing "Update branch" on a Renovate PR deploys no
  preview either. The test job still runs on every bot PR.
- **Issue labeler** (`labeler.yml`): skip issues authored by `renovate[bot]`.
- **`open-pr`**: lease the push against the branch tip read with
  `git ls-remote` (an empty lease means "must not exist yet"), and skip the
  push when the branch already has the same tree on the same base, so an
  unchanged sync does not re-run the PR's CI. Reusable workflows that pin an
  older `open-pr` fetch the working branch first, which unblocks the old bare
  lease.

`tests/workflow-job-conditions.py` evaluates the job conditions of `pages.yml`,
`lint.yml` and `labeler.yml` against representative events and fails when the
set of running (billed) jobs changes; `tests/open-pr-push.sh` reproduces the
stale-info failure and verifies the fix against a local remote.

### Templates

`workflow-templates/` adopt the same conventions for new repositories:
workflow-level `concurrency` keyed on the PR number with
`cancel-in-progress: ${{ github.event_name == 'pull_request' }}` (a running
default-branch run is never cancelled, but a queued one is superseded by a
newer push), no `edited` trigger for Pages, `issues: write` for config sync,
daily instead of 6-hourly cooldown checks, weekly instead of daily label sync,
and no TODO-to-issue runs for Renovate's automerge pushes.

## Alternatives considered

- **Make the private repositories public.** Rejected for the repositories that
  must stay private; it is a per-repository decision, not a CI convention.
- **Apply the Renovate settings only to private repositories.** Rejected: the
  same churn costs public repositories queue time and noise, and one policy is
  easier to reason about than two.
- **`group:allNonMajor` preset.** Rejected in favour of an explicit rule: the
  preset only matches `minor` and `patch` (so `pin`/`digest` updates would
  still open separate PRs) and its position in the extends chain could not be
  controlled relative to the opt-outs.
- **YAML anchors to share the linter scripts between both lint modes.**
  Rejected for now: GitHub supports anchors, but zizmor's anchor support is in
  beta and warns on every run of a security-sensitive reusable workflow. The
  contract test makes the duplication safe instead.
- **Parallel steps inside the single lint job.** Deferred: GitHub added them in
  June 2026, but linter support is still experimental, and the linters are
  quick enough sequentially.
- **Fold `validate-inputs` into another Pages job** to save one more minute per
  run. Rejected: every job needs it, and the gating above already removes it
  from the runs that do not need it.

## Consequences

- A typical week produces one non-major Renovate PR per repository (plus
  gated images, majors and security fixes), and a merge no longer re-runs CI on
  every other open Renovate PR.
- A single failing update blocks the whole weekly batch until it is fixed or
  excluded; that is the accepted trade-off. Split the culprit out with a
  repository-level rule if it cannot be fixed quickly.
- **Repositories whose ruleset requires branches to be up to date before
  merging** (`strict_required_status_checks_policy: true`) must override with
  `rebaseWhen: "behind-base-branch"` in their own `renovate.json5`; otherwise
  their automerge PRs stall behind the base branch. At the time of writing
  that applies to `home-assistant-win-companion` and `net-worth-calculator`.
- Private repositories see one `all linters` check instead of one check per
  linter, and a lint run takes longer wall-clock. Repositories that require
  per-linter checks and opt into `single` must require `all linters` instead —
  skipped per-linter jobs report success.
- Renovate PRs no longer get Cloudflare previews in any case, including when a
  human updates the branch.
- Open individual Renovate PRs are closed and superseded by the grouped PR on
  the first scheduled run after the presets change.

# ADR 0001: Reusable workflows must not default package versions

- **Status:** Accepted
- **Date:** 2026-04-20
- **Scope:** `DevSecNinja/.github` — all reusable workflows under `.github/workflows/`

## Context

This repository hosts reusable workflows (`on: workflow_call`) that are consumed
by other repositories in the organization. Several of these workflows install
third-party tooling — most notably [`mise`](https://mise.jdx.dev/), which in
turn pins the versions of every linter, formatter, and security scanner the
caller runs.

If the reusable workflow hard-codes a tool version (or provides a default that
most callers omit), bumping that version in this repository effectively ships
a new version to every consumer the next time their workflow runs — _without_
that consumer's CI ever having validated the new version against their code.
The caller carries the operational risk of an upgrade that was never tested
against their repository.

The [`jdx/mise`] toolchain is particularly impactful here: a single
`mise-version` input controls the resolution of _all_ tool versions in the
caller's `.mise.toml`, so a silent bump can cascade through the entire lint /
release pipeline.

[`jdx/mise`]: https://github.com/jdx/mise

## Decision

> **Reusable workflows in `DevSecNinja/.github` MUST NOT specify default values
> for package / tool version inputs. Every such input MUST be declared with
> `required: true`. The calling repository MUST provide the version, and
> SHOULD annotate it with a `# renovate:` comment so Renovate can raise a PR
> (which runs the caller's CI) when a new version is released.**

This rule applies to any input whose value resolves to a version of software
installed or executed by the workflow (for example: `mise-version`,
`node-version`, `python-version`, `go-version`, tool container tags, etc.).

It does **not** apply to:

- GitHub Action `uses:` references pinned to a full commit SHA. Those are
  owned by the reusable workflow itself and are implicitly versioned through
  the workflow ref (`@<sha>`) the caller selects.
- Non-version configuration inputs (file paths, feature toggles, labels, …).
  These may and should have sensible defaults to keep callers terse.

## Consequences

### Pros

- **Caller owns the risk.** A version bump always runs through the caller's
  CI before merging, because it arrives as a PR in the caller's repository
  (either a hand-written change or a Renovate PR against the caller's
  `with: version: …` line).
- **No silent fan-out of breakage.** Changing a tool version in this
  repository cannot break downstream repositories on its own.
- **Per-repository cadence.** Each consumer can pin older versions or stage
  upgrades independently. Repositories with stricter change-control can hold
  back safely.
- **Renovate handles the grunt work.** With the `# renovate:` marker on the
  caller's `with:` block, Renovate opens one PR per caller per release, and
  the caller's existing test / lint jobs act as the validation gate.
- **Upgrades become visible.** The version string lives in the caller's
  repository, so code review, blame, and commit history all reflect which
  version is actually in use.

### Cons

- **More boilerplate for callers.** Every consumer must set the version
  input explicitly; they cannot rely on a "just works" default.
- **Breaking change to add a required input.** Introducing a new required
  version input means every existing caller breaks until they update their
  `with:` block. Communicate such changes via a release note and, where
  possible, via a grace period using a temporary non-required input.
- **No central emergency bump.** A CVE in a tool cannot be patched across
  the organization from this repository alone. Mitigation: rely on Renovate
  (configured via `config-sync`) to fan out the update, and document the
  advisory.
- **Version drift across consumers.** Different consumers may pin different
  versions at the same time. This is a feature (staged rollout) but can
  complicate support — always ask consumers which version they are on before
  debugging.

## Guidance

### For reusable workflows in this repository

- Declare every version input as `required: true` with a clear description:

  ```yaml
  on:
    workflow_call:
      inputs:
        mise-version:
          description: "mise version to install"
          required: true
          type: string
  ```

- Pass the input through to the installing action via `${{ inputs.<name> }}`.
  Never hard-code a version number elsewhere in the workflow.
- Pin `uses:` references to full commit SHAs with a version comment, per the
  org-wide Copilot instructions.

### For calling repositories

- Set the version explicitly in `with:` and annotate with `# renovate:` so
  the value is maintained automatically:

  ```yaml
  jobs:
    lint:
      uses: DevSecNinja/.github/.github/workflows/lint.yml@<sha> # main
      with:
        # renovate: datasource=github-releases depName=jdx/mise
        mise-version: "2026.4.3"
  ```

- Treat the value as production configuration — review it in PRs, keep it
  in lockstep with `.mise.toml` when applicable, and merge Renovate PRs
  only after CI is green.

### For workflow templates in `workflow-templates/`

- Templates SHOULD show the `# renovate:` marker and a real version value so
  that repositories created from the template start in a compliant state.

## Compliance

- `lint.yml` — `mise-version` and `golangci-lint-version` required ✅
- `release.yml` — `mise-version` required ✅
- `autofix.yml` — `mise-version` required ✅
- `config-sync.yml`, `label-sync.yml`, `labeler.yml`, `todo-to-issue.yml` —
  no tool version inputs (compliant by construction) ✅

Any new reusable workflow added to this repository MUST be reviewed against
this ADR before merging.

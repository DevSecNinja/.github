# APM Sync — onboarding a repo

How to keep a repo's installed [APM (Agent Package Manager)](https://microsoft.github.io/apm/)
primitives — prompts, instructions, agents, skills — up to date with their
upstream packages (e.g. `DevSecNinja/ai-toolkit`).

**The model: Renovate bumps the pin, a workflow materializes it.**

APM dependencies are pinned to an exact tag in `apm.yml`
(`DevSecNinja/ai-toolkit#v0.1.1`). That gives reproducible installs, but it means
`apm update` can't advance them — it only re-resolves the *same* exact tag. So we
use the same tool that versions everything else in the org:

1. **Renovate** maintains the `#vX.Y.Z` tag pin in `apm.yml` (via a custom manager
   in [`.renovate/customManagers.json5`](../.renovate/customManagers.json5)).
   It opens a normal `v0.1.1 → v0.2.0` PR — version-aware, with the usual soak,
   grouping, and changelog links.
2. The [`apm-materialize.yml`](../.github/workflows/apm-materialize.yml) workflow
   runs on that PR, executes `apm install` to re-resolve `apm.lock.yaml` and
   redeploy the primitives into the harness directories, and commits the result
   back onto the PR branch. You review the complete diff and merge.

> Why a workflow and not a Renovate `postUpgradeTask`: this org uses **Mend-hosted
> Renovate**, which doesn't run arbitrary postUpgrade commands. The workflow does
> the materialization instead.

This is the agentic-primitive counterpart to
[config-sync](../.github/workflows/config-sync.yml): config-sync distributes
static files (linters, editorconfig, renovate), APM distributes installable agent
primitives.

---

## Prerequisites

- The repo already depends on at least one APM package. Run this once locally and
  commit the result:

  ```sh
  apm install DevSecNinja/ai-toolkit#v0.2.0 --target copilot
  git add apm.yml apm.lock.yaml .github/   # plus any other harness dirs APM wrote
  git commit -m "feat: install ai-toolkit APM primitives"
  ```

  > Pin an explicit `#vX.Y.Z` so Renovate can track it. `apm_modules/` is the
  > package cache — APM adds it to `.gitignore` on first install; don't commit it.

- The `RELEASE_PLEASE_APP_ID` variable + `RELEASE_PLEASE_APP_PRIVATE_KEY` secret
  (the same App used for release-please). The materialize workflow commits with
  the App token so required CI re-runs on the updated PR.

- The repo extends the org Renovate presets (so it inherits the apm.yml custom
  manager):

  ```json5
  {
    extends: ["github>DevSecNinja/.github//.renovate/customManagers.json5"],
  }
  ```

  (The synced `renovate.json5` already does this.)

---

## Per-repo adoption

Add the materialize workflow. Pin it to a release tag of `DevSecNinja/.github`.

### `.github/workflows/apm-materialize.yml`

```yaml
---
name: APM Materialize
on:
  pull_request:
    paths:
      - apm.yml
  workflow_dispatch:
permissions:
  contents: read
jobs:
  materialize:
    # renovate: datasource=github-tags depName=DevSecNinja/.github
    uses: DevSecNinja/.github/.github/workflows/apm-materialize.yml@<sha> # vX.Y.Z
    permissions:
      contents: write
    secrets: inherit
```

> The reference implementation currently lives as a repo-local workflow in
> `DevSecNinja/.github` itself (it pushes back to the PR branch, so it isn't a
> `workflow_call` reusable yet). Copy
> [`.github/workflows/apm-materialize.yml`](../.github/workflows/apm-materialize.yml)
> into the consuming repo and pin the action SHAs.

---

## What a run does

1. Triggers on any PR that changes `apm.yml` (Renovate's bump PR, or a manual edit).
2. Installs the pinned `apm` CLI (`pip install apm-cli`).
3. Runs `apm install` — re-resolves `apm.lock.yaml` to the new pin and redeploys
   the primitives into the harness directories (`.github/`, `.claude/`, …).
4. Commits the materialized files back onto the PR branch (via the App token, so
   CI re-runs). When nothing changed, it's a no-op.

You review the combined diff (pin bump + lockfile + deployed files) and merge.

---

## Troubleshooting

### The materialize commit lands but no CI runs on it

The push used `GITHUB_TOKEN` instead of the App. Confirm `RELEASE_PLEASE_APP_ID`
(variable) + `RELEASE_PLEASE_APP_PRIVATE_KEY` (secret) exist and the workflow's
App-token step is wired. Quick unblock: a human closes and reopens the PR.

### Renovate isn't opening apm.yml bump PRs

Check the repo extends `.renovate/customManagers.json5` (the apm.yml manager
lives there) and that the dependency is pinned to a `#vX.Y.Z` tag, not an
unpinned ref or a branch.

### `No apm.yml in this repo; nothing to materialize`

The repo hasn't installed any APM package yet. Do the one-time `apm install
<pkg>#vX.Y.Z` in the prerequisites and commit `apm.yml` + `apm.lock.yaml`.

---

## Related docs

- [`.github/workflows/apm-materialize.yml`](../.github/workflows/apm-materialize.yml) — the materialize workflow.
- [`.renovate/customManagers.json5`](../.renovate/customManagers.json5) — the apm.yml tag manager.
- [`.github/workflows/config-sync.yml`](../.github/workflows/config-sync.yml) — static-file sync sibling.
- [Release Please onboarding](release-please-onboarding.md) — shares the App auth setup.
- [APM consumer docs](https://microsoft.github.io/apm/consumer/) — `install`, `update`, `outdated`.

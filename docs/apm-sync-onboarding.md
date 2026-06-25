# APM Sync — onboarding a repo

How to keep a repo's installed [APM (Agent Package Manager)](https://microsoft.github.io/apm/)
primitives — prompts, instructions, agents, skills — up to date with their
upstream packages (e.g. `DevSecNinja/ai-toolkit`).

**The model: Renovate bumps the pin, a post-merge workflow materializes it.**

APM dependencies are pinned to an exact tag in `apm.yml`
(`DevSecNinja/ai-toolkit#v0.1.1`). That gives reproducible installs, but it means
`apm update` can't advance them — it only re-resolves the _same_ exact tag. So we
use the same tool that versions everything else in the org:

1. **Renovate** maintains the `#vX.Y.Z` tag pin in `apm.yml` (via a custom manager
   in [`.renovate/customManagers.json5`](../.renovate/customManagers.json5)).
   It opens a normal `v0.1.1 → v0.2.0` PR that changes **only the manifest text**,
   so it rebases, automerges, and autocloses like any other Renovate PR.
2. Once that bump lands on `main`, the
   [`apm-materialize.yml`](../.github/workflows/apm-materialize.yml) workflow runs
   `apm install` to re-resolve `apm.lock.yaml` and redeploy the primitives, and
   opens a **separate** `chore: materialize APM primitives` PR with the result.

> **Why post-merge, not on the Renovate PR:** pushing the materialized files onto
> Renovate's own branch corrupts Renovate's branch ownership — it stops rebasing
> and automerging the PR and refuses to autoclose it when superseded
> ("branch already modified"). So the materialize step never touches the bump PR;
> it runs after merge and opens its own PR.
>
> (A Renovate `postUpgradeTask` would fold both into one commit, but this org uses
> **Mend-hosted Renovate**, which doesn't run arbitrary postUpgrade commands.)

This is the agentic-primitive counterpart to
[config-sync](../.github/workflows/config-sync.yml): config-sync distributes
static files (linters, editorconfig, renovate), APM distributes installable agent
primitives.

---

## Prerequisites

- The repo already depends on at least one APM package. Run this once locally and
  commit the result:

  ```sh
  apm install DevSecNinja/ai-toolkit#v0.3.0 --target copilot
  git add apm.yml apm.lock.yaml .github/   # plus any other harness dirs APM wrote
  git commit -m "feat: install ai-toolkit APM primitives"
  ```

  > Pin an explicit `#vX.Y.Z` so Renovate can track it. `apm_modules/` is the
  > package cache — APM adds it to `.gitignore` on first install; don't commit it.

- The `RELEASE_PLEASE_APP_ID` variable + `RELEASE_PLEASE_APP_PRIVATE_KEY` secret
  (the same App used for release-please). The materialize workflow opens its PR
  with the App token so required CI runs on it.

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

Add a thin caller workflow that invokes the central `apm-materialize` reusable on
pushes to `main` that touch `apm.yml`. Pin it to a release tag of
`DevSecNinja/.github`.

### `.github/workflows/apm-materialize.yml`

```yaml
---
name: APM Materialize
on:
  push:
    branches: [main]
    paths:
      - apm.yml
  workflow_dispatch:
permissions:
  contents: read
concurrency:
  group: apm-materialize
  cancel-in-progress: false
jobs:
  materialize:
    # renovate: datasource=github-tags depName=DevSecNinja/.github
    uses: DevSecNinja/.github/.github/workflows/apm-materialize.yml@<sha> # vX.Y.Z
    permissions:
      contents: write
      pull-requests: write
    with:
      # renovate: datasource=pypi depName=apm-cli
      apm-cli-version: "0.21.0"
      app-id: ${{ vars.RELEASE_PLEASE_APP_ID }}
    secrets:
      app-private-key: ${{ secrets.RELEASE_PLEASE_APP_PRIVATE_KEY }}
```

Pin `<sha>` to a release-tagged commit of `DevSecNinja/.github`; the `# renovate:`
comments let Renovate bump both the reusable and the `apm` CLI version.

---

## What a run does

1. Triggers **after** an `apm.yml` change lands on `main` (a merged Renovate bump,
   or a manual edit) — or via `workflow_dispatch`.
2. Installs the pinned `apm` CLI (`pip install apm-cli`).
3. Runs `apm install` — re-resolves `apm.lock.yaml` to the new pin and redeploys
   the primitives into the harness directories (`.github/`, `.claude/`, …).
4. Opens a separate `chore: materialize APM primitives` PR (App token → CI runs).
   When nothing changed, it's a no-op (no PR).

Net flow per upstream release: **Renovate bump PR** (manifest only, automerges) →
**materialize PR** (lockfile + deployed files, you review and merge). `main` is
briefly ahead on `apm.yml` until the materialize PR merges — harmless for
agent-context files.

---

## Troubleshooting

### The materialize PR opens but no CI runs on it

The PR was opened with `GITHUB_TOKEN` instead of the App. Confirm
`RELEASE_PLEASE_APP_ID` (variable) + `RELEASE_PLEASE_APP_PRIVATE_KEY` (secret)
exist and the workflow's App-token step is wired.

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

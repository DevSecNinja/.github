# APM Sync — onboarding a repo

Step-by-step guide for keeping a repo's installed
[APM (Agent Package Manager)](https://microsoft.github.io/apm/) primitives —
prompts, instructions, agents, hooks — up to date with their upstream packages,
using the central [`apm-sync.yml`](../.github/workflows/apm-sync.yml) reusable
workflow.

The end state: a scheduled (or manually dispatched) job runs `apm update`, and
when an upstream package (e.g. `DevSecNinja/ai-toolkit`) ships new primitives, it
opens a `chore: sync APM primitives` PR you merge to adopt them. **Branch
protection is respected end-to-end — no bypass actor needed.**

This is the agentic-primitive counterpart to
[config-sync](../.github/workflows/config-sync.yml): config-sync distributes
static files (linters, editorconfig, renovate), APM-sync distributes installable
agent primitives.

---

## Prerequisites

- The repo already depends on at least one APM package. Run this once locally and
  commit the result:

  ```sh
  apm install DevSecNinja/ai-toolkit --target copilot
  git add apm.yml apm.lock.yaml .github/   # plus any other harness dirs APM wrote
  git commit -m "feat: install ai-toolkit APM primitives"
  ```

  > `apm_modules/` is the package cache — APM adds it to `.gitignore` on first
  > install. Don't commit it.

- (Recommended) The same `RELEASE_PLEASE_APP_ID` variable +
  `RELEASE_PLEASE_APP_PRIVATE_KEY` secret used for release-please, so the sync PR
  is opened by the App identity and required CI checks fire on it. Without the
  App, the PR still opens via `GITHUB_TOKEN` but won't retrigger CI.

---

## Per-repo adoption

Add a thin caller workflow. Pin `apm-version` to a real `apm` CLI release tag
(the caller owns the version — see
[ADR 0001](design-decisions/0001-reusable-workflow-version-inputs.md)).

### `.github/workflows/apm-sync.yml`

```yaml
---
name: APM Sync
on:
  schedule:
    - cron: "0 6 * * 1" # Mondays 06:00 UTC
  workflow_dispatch:
permissions:
  contents: read
concurrency:
  group: apm-sync
  cancel-in-progress: false
jobs:
  apm-sync:
    # renovate: datasource=github-tags depName=DevSecNinja/.github
    uses: DevSecNinja/.github/.github/workflows/apm-sync.yml@<sha> # vX.Y.Z
    permissions:
      contents: write
      pull-requests: write
    with:
      # renovate: datasource=github-releases depName=microsoft/apm
      apm-version: v0.13.0
      app-id: ${{ vars.RELEASE_PLEASE_APP_ID }}
    secrets:
      app-private-key: ${{ secrets.RELEASE_PLEASE_APP_PRIVATE_KEY }}
```

Pin `<sha>` to a release-tagged commit of `DevSecNinja/.github`; the `# renovate:`
comments let Renovate bump both the reusable and the `apm` CLI version.

### Optional inputs

| Input           | Default          | Purpose                                                        |
| --------------- | ---------------- | -------------------------------------------------------------- |
| `apm-version`   | _(required)_     | `apm` CLI release to install.                                  |
| `packages`      | _(all)_          | Space-separated package names to update; empty refreshes all.  |
| `target-branch` | `main`           | Base branch the PR targets.                                    |
| `pr-branch`     | `chore/apm-sync` | Working branch for the sync PR.                                |
| `app-id`        | _(empty)_        | GitHub App ID so the PR triggers required CI.                  |

---

## What a run does

1. Installs the pinned `apm` CLI.
2. Runs `apm update --yes` (optionally scoped to `packages`), which re-resolves
   every dependency in `apm.yml` to its latest matching ref, rewrites
   `apm.lock.yaml`, and redeploys the compiled primitives into the harness
   directories.
3. If anything changed, opens (or force-updates) `chore: sync APM primitives`.
4. You review and merge. Nothing is auto-merged.

When there are no upstream changes, the job ends quietly with no PR.

---

## Troubleshooting

### The sync PR opens but no CI runs on it

The PR was opened with `GITHUB_TOKEN` instead of the App — `app-id` was empty.
Set `RELEASE_PLEASE_APP_ID` (variable) + `RELEASE_PLEASE_APP_PRIVATE_KEY`
(secret) and pass `app-id` as shown above. Quick unblock for an already-open PR:
a human closes and reopens it.

### `No apm.yml in this repo; nothing to sync`

The repo hasn't installed any APM package yet. Do the one-time
`apm install <pkg>` in the prerequisites and commit `apm.yml` + `apm.lock.yaml`.

### Nothing happens / no PR

`apm update` found no newer refs. Run `apm outdated` locally to confirm, or pin a
new ref in `apm.yml`. Install never silently bumps — the workflow only adopts
what `apm update` resolves.

---

## Related docs

- [`.github/workflows/apm-sync.yml`](../.github/workflows/apm-sync.yml) — the reusable.
- [`.github/workflows/config-sync.yml`](../.github/workflows/config-sync.yml) — static-file sync sibling.
- [Release Please onboarding](release-please-onboarding.md) — shares the App auth setup.
- [APM consumer docs](https://microsoft.github.io/apm/consumer/) — `install`, `update`, `outdated`.

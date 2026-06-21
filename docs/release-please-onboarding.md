# Release Please — onboarding a new repo

Step-by-step guide for adopting the central
[`release-please.yml`](../.github/workflows/release-please.yml)
reusable workflow in a `DevSecNinja/*` repo.

The end state: every push to `main` opens or updates a `chore(main):
release vX.Y.Z` PR that you merge to ship. **Branch protection is
respected end-to-end — no bypass actor needed.**

---

## Prerequisites

Before the first repo can adopt this, the org/account needs a **shared
GitHub App**. This is a _one-time_ setup. Skip ahead to [Per-repo adoption](#per-repo-adoption) if the App already exists (it does for
DevSecNinja — see below).

### One-time: create the GitHub App

> Personal accounts can use App credentials too — secrets just live at
> the **repo level** instead of the org level.

1. Go to <https://github.com/settings/apps/new> (or org-level: _Org
   Settings → Developer settings → GitHub Apps → New GitHub App_).
2. Fill in:
   - **Name**: `DevSecNinja Release Please` (or org equivalent).
   - **Homepage URL**: this repo's URL.
   - **Description** (255 char max):

     > Opens release PRs via release-please across the DevSecNinja org.
     > Uses short-lived App tokens so release PRs trigger required CI
     > status checks under branch protection — replacing the legacy
     > `cog bump` direct-push flow.

   - **Webhook → Active**: ❌ uncheck (no webhooks needed).
3. **Repository permissions**:
   - `Contents`: **Read and write** (push the release branch + tag).
   - `Pull requests`: **Read and write** (open / update the release PR).
   - `Metadata`: Read-only (auto-required).
4. **Where can this GitHub App be installed?**: _Only on this account_.
5. Create the App. From the App's settings page, capture the **App
   ID** (numeric, top of the page).
6. **Generate a private key** ("Private keys" section → _Generate a
   private key_). Save the downloaded `.pem` file securely — you'll
   only need it once per repo to copy into a secret.
7. **Install the App** on the repos that will adopt release-please
   ("Install App" tab on the App's public page).

For reference, the DevSecNinja App is `DevSecNinja Release Please`
(App ID `3563533`).

---

## Per-repo adoption

You'll do these once per repo. Order matters — do the **App install +
secrets** before merging the workflow PR, otherwise the first run will
fail with `Bad credentials` instead of just falling back to
`GITHUB_TOKEN`.

### 1. Install the App on the repo

From the App's public page, _Install App → Configure_, and tick the
repo. Or navigate to _Repo Settings → Integrations → GitHub Apps →
Configure_.

### 2. Add the secret + variable

In _Repo Settings → Secrets and variables → Actions_:

- **Variables tab → New repository variable**
  - Name: `RELEASE_PLEASE_APP_ID`
  - Value: the App's numeric ID (e.g. `3563533`).
  - App IDs are not sensitive — a variable is fine and surfaces in logs
    for easier debugging.
- **Secrets tab → New repository secret**
  - Name: `RELEASE_PLEASE_APP_PRIVATE_KEY`
  - Value: the _full_ contents of the `.pem` file generated in the
    one-time setup, including `-----BEGIN/END RSA PRIVATE KEY-----`
    lines.

> Renovate cannot manage these. They are configured once per repo and
> rotated only if the App's private key is compromised.

### 3. Enable Actions PR-creation

_Repo Settings → Actions → General → Workflow permissions →_
**✅ "Allow GitHub Actions to create and approve pull requests"** →
Save.

This is a separate, GitHub-side guardrail and **cannot** be granted via
workflow YAML `permissions:` alone. Without it, release-please's first
run fails with:

> `GitHub Actions is not permitted to create or approve pull requests`

(The workflow successfully creates the branch + commit; only the
final PR-open step is blocked.)

### 4. Add the three release-please files

Commit the following on a feature branch:

#### `.github/workflows/release-please.yml`

Use the [`workflow-templates/release-please.yml`](../workflow-templates/release-please.yml)
in this repo (also available via the GitHub UI's "New workflow"
picker), or paste:

```yaml
---
name: Release Please
on:
  push:
    branches: [main]
  workflow_dispatch:
permissions:
  contents: read
concurrency:
  group: release-please
  cancel-in-progress: false
jobs:
  release-please:
    uses: DevSecNinja/.github/.github/workflows/release-please.yml@<sha> # vX.Y.Z
    permissions:
      contents: write
      pull-requests: write
    with:
      app-id: ${{ vars.RELEASE_PLEASE_APP_ID }}
    secrets:
      app-private-key: ${{ secrets.RELEASE_PLEASE_APP_PRIVATE_KEY }}
```

Pin `<sha>` to a release-tagged commit of `DevSecNinja/.github`. The
`# vX.Y.Z` version comment on the `uses:` line is all Renovate needs:
its GitHub Actions manager tracks reusable-workflow callers natively and
auto-bumps both the pinned SHA and the comment when new tags ship. No
separate `# renovate:` annotation is required (and adding one is dropped
on the next bump).

#### `release-please-config.json`

Minimal single-package config for the simple language strategy (just
tracks a manifest, no language-specific bumping):

```json
{
  "$schema": "https://raw.githubusercontent.com/googleapis/release-please/main/schemas/config.json",
  "release-type": "simple",
  "include-component-in-tag": false,
  "include-v-in-tag": true,
  "skip-github-release": true,
  "bump-minor-pre-major": true,
  "bump-patch-for-minor-pre-major": false,
  "draft": false,
  "prerelease": false,
  "packages": {
    ".": {
      "release-type": "simple",
      "package-name": "<your-repo-name>",
      "changelog-path": "CHANGELOG.md"
    }
  }
}
```

**`skip-github-release: true` is mandatory** when the repo already has
a tag-triggered `release.yml` (which most do, via `release-publish` or
the central simple `release.yml`). Otherwise release-please will create
a duplicate release that conflicts with the existing one — and on
Immutable-Releases repos that's an unrecoverable error.

#### `.release-please-manifest.json`

Pin to the _current_ released version (the one matching the latest
`v*` tag):

```json
{ ".": "X.Y.Z" }
```

release-please bumps this file inside its release PRs. **Do not have
Renovate manage it** — the bump is the release.

### 5. (Optional) Retire local `cog bump`

If the repo had `cog bump` driving releases (cog hooks in `cog.toml`,
`task release:bump` in Taskfile, etc.):

- Strip `pre_bump_hooks` and `post_bump_hooks` from `cog.toml`. Keep
  the file for `cog verify` in the lefthook commit-msg hook.
- Remove `task release:bump` and any CI-gate tasks (`release:check-ci`,
  `release:changelog`). Keep `task release:notes` / `task release:build`
  if they're useful for local previews.
- Update any onboarding / contributor docs to point at this guide.

Reference implementations:

- [`DevSecNinja/dotfiles`](https://github.com/DevSecNinja/dotfiles) —
  with assets + Sigstore attestations.
- [`DevSecNinja/truenas-apps`](https://github.com/DevSecNinja/truenas-apps) —
  notes-only release.

### 6. Merge the PR and watch the first release

On merge to `main`:

1. The release-please workflow fires.
2. Within a minute it opens `chore(main): release vX.Y.Z`.
3. **All required CI checks run on it** (because the PR was opened by
   the App, not `GITHUB_TOKEN`).
4. Once green, you merge it like any normal PR.
5. release-please creates the `vX.Y.Z` tag on the merge commit.
6. The tag-triggered `release.yml` publishes the GitHub Release.

> Trigger downstream release workflows on `push: tags`, **not** on
> `release: created` — see
> [Release flow with release-please](workflow-trigger-conventions.md#release-flow-with-release-please)
> for the rationale.

---

## Troubleshooting

### `GitHub Actions is not permitted to create or approve pull requests`

Step 3 above wasn't done. Toggle the setting and re-run the workflow
(or just push another commit — the workflow runs on every push to main).

### `Bad credentials` from `actions/create-github-app-token`

- Check the App is **installed** on the repo (step 1).
- Check `RELEASE_PLEASE_APP_PRIVATE_KEY` contains the entire `.pem`
  including header/footer lines.
- Check `RELEASE_PLEASE_APP_ID` is the App ID, not the Installation ID
  (different number).

### Release PR opens but no CI runs on it

The PR was opened by `github-actions[bot]` instead of the App — step 2
was skipped or `app-id` is empty. Verify in _Repo Settings → Variables
→ Actions_ that `RELEASE_PLEASE_APP_ID` exists and is non-empty.

Quick unblock for an already-open release PR: a _human user_ closes
and reopens it (which fires `pull_request` events from a user identity,
triggering CI). Then fix the underlying setting so future PRs don't
need manual nudging.

### release-please opens no PR despite mergeable commits

release-please needs at least one **non-`chore`** Conventional Commit
since the last tag (or a `chore` with `Release-As: X.Y.Z` footer) to
open a PR. Check the Actions log — it explains exactly which commits
it considered.

Force a release with no qualifying commits: push an empty commit:

```sh
git commit --allow-empty -m "chore: cut release

Release-As: 0.5.0"
git push
```

### The release PR's version is wrong

Override with `Release-As: X.Y.Z` in any commit footer on `main`.
release-please picks it up on the next push and rewrites the open PR
to use that version.

---

## Related docs

- [`.github/workflows/release-please.yml`](../.github/workflows/release-please.yml) — the reusable.
- [`actions/release-publish/README.md`](../actions/release-publish/README.md) — the
  composite that publishes the GitHub Release on tag push.
- [`docs/workflow-trigger-conventions.md`](workflow-trigger-conventions.md) —
  org-wide rules for `on:`, concurrency, and IRM paging.
- [`docs/architecture.md`](architecture.md) — fleet architecture overview.

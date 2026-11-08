# Release Please — onboarding a new repo

Step-by-step guide for adopting the central
[`release-please.yml`](../.github/workflows/release-please.yml)
reusable workflow in a `DevSecNinja/*` repo.

The end state: every push to `main` opens or updates a `chore(main):
release vX.Y.Z` PR that you merge to ship. **GitHub App authentication
is mandatory, and branch protection is respected end-to-end — no bypass
actor needed.**

Release Please authenticates as the shared **DevSecNinja Automation**
GitHub App, the same App Config Sync and APM Sync use. The full
credential contract — App permissions, the `AUTOMATION_APP_ID` /
`AUTOMATION_APP_PRIVATE_KEY` names, how they are provisioned and passed —
lives in [`automation-app.md`](automation-app.md); this guide covers only
what is specific to Release Please.

---

## Prerequisites

The App already exists for DevSecNinja: **DevSecNinja Automation**
(`devsecninja-automation`, App ID `3563533`), with repository
permissions **Contents** and **Pull requests** (read and write) plus
Metadata. Skip ahead to [Per-repo adoption](#per-repo-adoption).

### One-time: create the GitHub App (other accounts only)

> Personal accounts can use App credentials too — secrets just live at
> the **repo level** (or in a repo environment) instead of the org level.

1. Go to <https://github.com/settings/apps/new> (or org-level: _Org
   Settings → Developer settings → GitHub Apps → New GitHub App_).
2. Fill in:
   - **Name**: `<Org> Automation`.
   - **Homepage URL**: this repo's URL.
   - **Description** (255 char max):

     > Opens automation PRs (release-please, config sync, APM sync)
     > with short-lived App tokens so they trigger required CI under
     > branch protection.

   - **Webhook → Active**: ❌ uncheck (no webhooks needed).
3. **Repository permissions** — only these:
   - `Contents`: **Read and write** (push branches, release commits and tags).
   - `Pull requests`: **Read and write** (open / update PRs, labels).
   - `Metadata`: Read-only (auto-required).

   Never add Administration, Workflows, Secrets or Actions — see
   [App permissions](automation-app.md#app-permissions).
4. **Where can this GitHub App be installed?**: _Only on this account_.
5. Create the App. From the App's settings page, capture the **App
   ID** (numeric, top of the page).
6. **Generate a private key** ("Private keys" section → _Generate a
   private key_) and store it in 1Password with the App ID
   (`op://Private/GitHub Automation App/{app-id,private-key}` is what
   the dotfiles provisioning module expects).
7. **Install the App** on the repos that will use it ("Install App" tab
   on the App's public page).

---

## Per-repo adoption

You'll do these once per repo. Order matters — do the **App install +
credentials** before merging the workflow PR. The reusable workflow
deliberately fails closed when either credential is missing; it never
falls back to `GITHUB_TOKEN`.

### 1. Install the App on the repo

From the App's public page, _Install App → Configure_, and tick the
repo. Or navigate to _Repo Settings → Integrations → GitHub Apps →
Configure_.

### 2. Provision the credentials

Provision the variable `AUTOMATION_APP_ID` and the secret
`AUTOMATION_APP_PRIVATE_KEY` from 1Password with the dotfiles
`GitHubRepoConfig` module (`-Check AppCredential`, then apply without
`-WhatIf`), as described in
[Per-repository credentials](automation-app.md#per-repository-credentials).
On public repos it stores them in the `production` environment, pinned
to the default branch; on private repos at repository level. Either
works with the caller below.

> Renovate cannot manage these. They are provisioned once per repo and
> rotated only if the App's private key is compromised.

### 3. Leave Actions PR-creation off

_Repo Settings → Actions → General → Workflow permissions →_
**"Allow GitHub Actions to create and approve pull requests"** is **not
required**: that setting governs `GITHUB_TOKEN` only, and Release Please
opens its PR with the App token. Leave it **off** (or turn it off), so
no workflow can approve pull requests with `GITHUB_TOKEN`.

### 4. Choose a publication pattern

The authentication contract is the same for both supported patterns:
the App installation and the `AUTOMATION_APP_ID` /
`AUTOMATION_APP_PRIVATE_KEY` credentials are mandatory.

#### Pattern A: Direct Release Please GitHub Release

Set `"skip-github-release": false`. Release Please creates the version
tag and GitHub Release after the release PR merges. Do not configure a
competing tag-triggered publisher for the same tag.

This is the default for simple consumers that do not publish release
assets, attestations, or custom notes. This repository uses Pattern A.

#### Pattern B: Split tag publisher

Set `"skip-github-release": true` and provide a `release.yml` triggered
by `push` on `v*` tags. Release Please still creates the version tag;
the option skips only the formal GitHub Release. The tag-triggered
workflow owns release notes, assets, attestations, and publication.

Use Pattern B when a repository needs custom release assets or
attestations, or must generate custom release notes at publication time.

### 5. Add the three release-please files

Commit the following on a feature branch:

#### `.github/workflows/release-please.yml`

Use the [`workflow-templates/release-please.yml`](../workflow-templates/release-please.yml)
starter in this repo (also in the GitHub UI's "New workflow" picker), or
paste the snippet below. Copies of the template from before v3.4.0 pass the
legacy `RELEASE_PLEASE_APP_*` names, which only exist in repos onboarded
earlier — a repo provisioned with just the standard names needs the v3.4.0+
snippet.

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
    uses: DevSecNinja/.github/.github/workflows/release-please.yml@<sha> # v3.4.0
    permissions:
      contents: write
      pull-requests: write
    secrets:
      AUTOMATION_APP_PRIVATE_KEY: ${{ secrets.AUTOMATION_APP_PRIVATE_KEY }}
```

The App ID is read from the `AUTOMATION_APP_ID` variable automatically;
the private key has to be passed by the calling job, as above. Repos
onboarded before v3.4.0 pass the legacy names explicitly
(`app-id: ${{ vars.RELEASE_PLEASE_APP_ID }}` and
`app-private-key: ${{ secrets.RELEASE_PLEASE_APP_PRIVATE_KEY }}`); that
keeps working — see
[Migrating from `RELEASE_PLEASE_APP_*`](automation-app.md#migrating-from-release_please_app_).

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
  "skip-github-release": false,
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

The example uses the Pattern A default. Switch to
`skip-github-release: true` only when the repo has a tag-triggered
publisher via `release-publish` or the central simple `release.yml`. It
does **not** prevent tag creation; it prevents Release Please from
creating the formal GitHub Release.

#### `.release-please-manifest.json`

Pin to the _current_ released version (the one matching the latest
`v*` tag):

```json
{ ".": "X.Y.Z" }
```

release-please bumps this file inside its release PRs. **Do not have
Renovate manage it** — the bump is the release.

### 6. (Optional) Retire local `cog bump`

If the repo had `cog bump` driving releases (cog hooks in `cog.toml`,
`task release:bump` in Taskfile, etc.):

- Strip `pre_bump_hooks` and `post_bump_hooks` from `cog.toml`. Keep
  the file for `cog verify` in the lefthook commit-msg hook.
- Remove `task release:bump` and any CI-gate tasks (`release:check-ci`,
  `release:changelog`). Keep `task release:notes` / `task release:build`
  if they're useful for local previews.
- Update any onboarding / contributor docs to point at this guide.

Pattern B reference implementations:

- [`DevSecNinja/dotfiles`](https://github.com/DevSecNinja/dotfiles) —
  with assets + Sigstore attestations.
- [`DevSecNinja/truenas-apps`](https://github.com/DevSecNinja/truenas-apps) —
  notes-only release.

### 7. Merge the PR and watch the first release

On merge to `main`:

1. The release-please workflow fires.
2. Within a minute it opens `chore(main): release vX.Y.Z`.
3. **All required CI checks run on it** (because the PR was opened by
   the App, not `GITHUB_TOKEN`).
4. Once green, you merge it like any normal PR.
5. Release Please creates the `vX.Y.Z` tag on the merge commit.
6. Pattern A has Release Please create the GitHub Release directly;
   Pattern B has the tag-triggered `release.yml` publish it.

> Trigger downstream release workflows on `push: tags`, **not** on
> `release: created` — see
> [Release flow with release-please](workflow-trigger-conventions.md#release-flow-with-release-please)
> for the rationale.

---

## Troubleshooting

### `GitHub Actions is not permitted to create or approve pull requests`

The run used `GITHUB_TOKEN` instead of the App — only possible with a
central workflow pinned below v3.0.0, which allowed that fallback.
Bump the pin and provision the App credentials (steps 1–2); do not
enable the Actions setting.

### `GitHub App authentication required`

The preflight found no App ID or no private key. "AUTOMATION_APP_ID is
set, but the calling job does not pass the AUTOMATION_APP_PRIVATE_KEY
secret" means the caller lacks the `secrets:` mapping from step 5.
Otherwise provision the credentials (step 2).

### `Bad credentials` from `actions/create-github-app-token`

- Check the App is **installed** on the repo (step 1).
- Check `AUTOMATION_APP_PRIVATE_KEY` contains the entire `.pem`
  including header/footer lines.
- Check `AUTOMATION_APP_ID` is the App ID, not the client ID or the
  Installation ID (different values).

See [Troubleshooting](automation-app.md#troubleshooting) for the
environment and permission errors shared with the other workflows.

### Release PR opens but no CI runs on it

Current versions fail before running Release Please when either App
credential is missing. If a PR was opened by `github-actions[bot]`, the
caller is pinned to an older central workflow that allowed the
`GITHUB_TOKEN` fallback. Update its central workflow pin and provision
the credentials.

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

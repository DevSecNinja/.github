# Architecture & Usage Guide

This document covers the design of `DevSecNinja/.github` and how consuming
repositories use it.

## Repository layout

```text
.
├── .github/
│   ├── workflows/          # Reusable workflow definitions (on: workflow_call)
│   ├── skills/             # Copilot skill definitions
│   ├── CODEOWNERS
│   ├── ISSUE_TEMPLATE/
│   ├── PULL_REQUEST_TEMPLATE.md
│   ├── SECURITY.md
│   ├── copilot-instructions.md   # Org-wide Copilot coding standards
│   └── labels-base.yaml          # Base label set synced to all repos
├── .renovate/              # Renovate shared preset fragments
├── actions/                # Composite actions (run inside the caller's job)
├── config-sync/
│   ├── files/              # Files auto-synced to every repo (read-only)
│   └── templates/          # Starting-point files — copy & adapt per repo
├── docs/
│   └── design-decisions/   # Architecture Decision Records (ADRs)
├── profile/
│   └── README.md           # Organisation profile shown on github.com/DevSecNinja
└── workflow-templates/     # Starter workflows for the GitHub Actions UI picker
```

---

## Reusable workflows

All reusable workflows live in `.github/workflows/` and are called with
`on: workflow_call`. Pin the `uses:` ref to a full commit SHA with a version
comment and supply the required inputs.

> **Version inputs are always required.** The calling repo owns the tool
> version and annotates it with a `# renovate:` comment so Renovate opens a PR
> (which runs the caller's CI) when a new version is released.
> See [ADR 0001](design-decisions/0001-reusable-workflow-version-inputs.md).

### Lint (`lint.yml`)

Runs up to eleven linters. By default, linter failures are reported without
failing the workflow; set `lint-fail-on-error` to `true` to make lint failures
fail the workflow. Toggle individual linters on/off with boolean inputs; all
linter toggles default to `true`.

| Input                   | Description                                      |
| ----------------------- | ------------------------------------------------ |
| `mise-version`          | **Required.** mise version to install.           |
| `golangci-lint-version` | **Required.** golangci-lint version to install.  |
| `go-version-file`       | Go version file for setup-go. Default: `go.mod`. |
| `lint-config-dir`       | Optional linter config directory. Default: `""`. |
| `lint-fail-on-error`    | Fail when a linter fails. Default: `false`.      |
| `lint-dprint`           | Markdown formatting (dprint). Default: `true`.   |
| `lint-yamlfmt`          | YAML formatting (yamlfmt). Default: `true`.      |
| `lint-yamllint`         | YAML linting (yamllint). Default: `true`.        |
| `lint-actionlint`       | GitHub Actions linting. Default: `true`.         |
| `lint-gitleaks`         | Secret scanning (gitleaks). Default: `true`.     |
| `lint-go`               | Go linting (golangci-lint). Default: `true`.     |
| `lint-shellcheck`       | Shell linting (shellcheck). Default: `true`.     |
| `lint-shfmt`            | Shell formatting (shfmt). Default: `true`.       |
| `lint-checkov`          | IaC security scan (checkov). Default: `true`.    |
| `lint-trivy`            | Filesystem scan (trivy). Default: `true`.        |
| `lint-zizmor`           | Actions security scan (zizmor). Default: `true`. |
| `lint-config-drift`     | Config-drift check. Default: `false`.            |

**Example caller:**

```yaml
jobs:
  lint:
    uses: DevSecNinja/.github/.github/workflows/lint.yml@<sha> # v1.0.0
    permissions:
      contents: read
      security-events: write
    with:
      # renovate: datasource=github-releases depName=jdx/mise
      mise-version: "2026.4.5"
      # renovate: datasource=github-releases depName=golangci/golangci-lint
      golangci-lint-version: "v2.11.4"
      # lint-config-dir: config-sync/files
      # lint-fail-on-error: true
```

### Auto-fix formatting (`autofix.yml`)

Runs dprint, yamlfmt, and shfmt in write mode, then commits and pushes any
formatting changes.

| Input                | Description                                            |
| -------------------- | ------------------------------------------------------ |
| `mise-version`       | **Required.** mise version to install.                 |
| `autofix-config-dir` | Optional formatter config directory. Default: `""`.    |
| `autofix-dprint`     | Markdown formatting (dprint). Default: `true`.         |
| `autofix-yamlfmt`    | YAML formatting (yamlfmt). Default: `true`.            |
| `autofix-shfmt`      | Shell formatting (shfmt). Default: `true`.             |
| `commit-message`     | Commit message. Default: `style: auto-fix formatting`. |

### Release (`release.yml`)

Creates a GitHub Release from a version tag using `git-cliff` for release
notes.

| Input          | Description                            |
| -------------- | -------------------------------------- |
| `mise-version` | **Required.** mise version to install. |
| `tag`          | **Required.** Tag name, e.g. `v1.2.3`. |

**Example caller:**

```yaml
on:
  push:
    tags: ["v*"]

jobs:
  release:
    uses: DevSecNinja/.github/.github/workflows/release.yml@<sha> # v1.0.0
    permissions:
      contents: write
    with:
      # renovate: datasource=github-releases depName=jdx/mise
      mise-version: "2026.4.5"
      tag: ${{ github.ref_name }}
```

### Pages (`pages.yml`)

Runs configurable site validation commands, deploys the production artifact to
GitHub Pages and/or Cloudflare Pages from the configured production branch, and
optionally deploys same-repository pull request previews to Cloudflare Pages.
Cloudflare jobs detect missing Cloudflare secrets before any deploy work. Missing
secrets fail production Cloudflare deploys and skip preview-only deploys.

| Input                          | Description                                                                           |
| ------------------------------ | ------------------------------------------------------------------------------------- |
| `node-version`                 | **Required.** Node.js version to install.                                             |
| `node-cache`                   | Package manager cache for test and production jobs. Default: empty (disabled).        |
| `wrangler-version`             | **Required.** Wrangler version to install for previews; inputs cannot be conditional. |
| `production-branch`            | Branch that deploys to production. Default: `main`.                                   |
| `artifact-path`                | Directory uploaded to Pages. Default: `.`.                                            |
| `install-command`              | Dependency install command. Default: `npm ci`.                                        |
| `test-command`                 | Validation command block. Default: empty.                                             |
| `test-setup-command`           | Optional command after install and before tests.                                      |
| `build-command`                | Optional build command before deployment.                                             |
| `pre-deploy-command`           | Optional production-only pre-upload command.                                          |
| `pre-preview-command`          | Optional preview-only pre-deploy command.                                             |
| `update-sitemap-lastmod`       | Update sitemap `<lastmod>` dates. Default: `false`.                                   |
| `sitemap-path`                 | Sitemap file path. Default: `sitemap.xml`.                                            |
| `github-pages`                 | Deploy production to GitHub Pages. Default: `true`.                                   |
| `cloudflare-preview`           | Enable Cloudflare pull request previews. Default: `true`.                             |
| `cloudflare-production`        | Deploy production to Cloudflare Pages. Default: `false`.                              |
| `cloudflare-project-name`      | Cloudflare Pages project; lowercase letters, numbers, and hyphens only.               |
| `cloudflare-production-branch` | Cloudflare production branch. Default: `main`.                                        |
| `preview-comment-marker`       | Marker used to update the preview PR comment.                                         |

**Example caller:**

```yaml
on:
  push:
    branches: ["main"]
  pull_request:
    types: [opened, edited, synchronize, reopened, closed]
  workflow_dispatch:

jobs:
  pages:
    uses: DevSecNinja/.github/.github/workflows/pages.yml@35c54636d55aa4d3aa727a98500ad87571e50be2 # v1.0.0
    permissions:
      contents: read
      deployments: write
      id-token: write
      issues: write
      pages: write
      pull-requests: write
    with:
      # renovate: datasource=node-version depName=node
      node-version: "24"
      # renovate: datasource=npm depName=wrangler
      wrangler-version: "3"
      test-setup-command: npx playwright install webkit --with-deps
      test-command: |
        npm run test:unit
        npm run test:html
        npm run test:a11y
        npm run test:e2e
      update-sitemap-lastmod: true
      # Optional Cloudflare production instead of GitHub Pages:
      # github-pages: false
      # cloudflare-production: true
      # cloudflare-project-name: "my-site"
    secrets:
      CLOUDFLARE_ACCOUNT_ID: ${{ secrets.CLOUDFLARE_ACCOUNT_ID }}
      CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}
```

### Config Sync (`config-sync.yml`)

Syncs files from `config-sync/files/` to the calling repository. Runs on a
weekly schedule and opens a PR when files drift.

**Source layout mirrors target layout.** A file at
`config-sync/files/<path>` is synced to `<repo>/<path>`, recursively. For
example, `config-sync/files/.github/CODEOWNERS` lands at
`<repo>/.github/CODEOWNERS`.

**Per-repo opt-out.** List paths (one per line, repo-relative) in
`.github/.config-sync-ignore` to skip them during sync. `#` comments and
blank lines are allowed. The `unmanaged` repo topic remains the
all-or-nothing escape hatch.

| Input            | Description                                                           |
| ---------------- | --------------------------------------------------------------------- |
| `sync-templates` | Also bootstrap files from `config-sync/templates/`. Default: `false`. |
| `central-ref`    | Git ref of `DevSecNinja/.github` to sync from. Default: `main`.       |

**Example caller:**

```yaml
jobs:
  sync:
    uses: DevSecNinja/.github/.github/workflows/config-sync.yml@<sha> # v1.0.0
    permissions:
      contents: write
      pull-requests: write
    # with:
    #   sync-templates: true   # also bootstrap template files for new repos
```

### Label Sync (`label-sync.yml`)

Syncs the repository's `.github/labels.yaml` (merged with the org base labels)
to the actual GitHub labels on the repo.

**Example caller:**

```yaml
jobs:
  label-sync:
    uses: DevSecNinja/.github/.github/workflows/label-sync.yml@<sha> # v1.0.0
    permissions:
      contents: read
      issues: write
```

### Labeler (`labeler.yml`)

Auto-labels pull requests and issues based on path patterns
(`pr-labeler.yaml`) and keyword rules (`issue-labeler.yaml`).

**Example caller:**

```yaml
jobs:
  labeler:
    uses: DevSecNinja/.github/.github/workflows/labeler.yml@<sha> # v1.0.0
    permissions:
      contents: read
      pull-requests: write
      issues: write
```

### TODO to Issue (`todo-to-issue.yml`)

Converts `TODO` comments in code to GitHub Issues on push to the default
branch.

**Example caller:**

```yaml
jobs:
  run:
    uses: DevSecNinja/.github/.github/workflows/todo-to-issue.yml@<sha> # v1.0.0
    permissions:
      contents: read
      issues: write
    with:
      auto_assign: false
      label: "todo-to-issue"
```

### Assign Issue to CODEOWNERS (`assign-issue-to-codeowners.yml`)

Assigns newly-opened issues (or a specific issue when triggered manually) to
the users listed in CODEOWNERS.

**Example caller:**

```yaml
jobs:
  assign:
    uses: DevSecNinja/.github/.github/workflows/assign-issue-to-codeowners.yml@<sha> # v1.0.0
    with:
      issue-number: ${{ inputs.issue-number || 0 }}
    permissions:
      contents: read
      issues: write
```

---

## Composite actions

Composite actions live in `actions/` and run **inside the caller's job**.
Use them when the action needs to operate on the caller's working tree,
OIDC subject, or pre-existing job state — things a reusable workflow
(which runs on its own runner) cannot see.

Pin the `uses:` ref to a full commit SHA with a version comment, just
like reusable workflows.

### Open PR (`actions/open-pr/`)

Opens (or force-updates) a pull request from the current working tree.
Use it whenever a job has produced changes that should land via PR
review rather than a direct push to a protected branch — signing,
formatting, generated-content updates.

Key properties:

- Uses only the preinstalled `gh` CLI; no third-party action.
- Default `GITHUB_TOKEN` does not retrigger workflows on the bot's
  push, so it is safe inside loops like sign-on-push.
- Reuses the existing PR (force-pushes its branch) when one already
  exists for the same `branch -> base` pair, so repeat runs do not
  spam duplicate PRs.
- Branch protection on the base branch stays fully enforced.

| Input            | Required | Default                     | Description                                                              |
| ---------------- | -------- | --------------------------- | ------------------------------------------------------------------------ |
| `branch`         | yes      | —                           | Working branch to create or force-push to.                               |
| `title`          | yes      | —                           | PR title (also default commit message). Conventional Commit subject.     |
| `base`           | no       | `main`                      | Branch to merge into.                                                    |
| `body`           | no       | `""`                        | PR body (Markdown).                                                      |
| `commit-message` | no       | `title`                     | Override the commit message.                                             |
| `paths`          | no       | `.`                         | Newline-delimited pathspecs to `git add`.                                |
| `labels`         | no       | `""`                        | Newline-delimited labels.                                                |
| `draft`          | no       | `false`                     | Open as draft.                                                           |
| `signoff`        | no       | `false`                     | Add `Signed-off-by` trailer.                                             |
| `if-no-changes`  | no       | `skip`                      | `skip` = exit 0; `fail` = error when nothing to commit.                  |
| `git-user-name`  | no       | `github-actions[bot]`       | Commit author name.                                                      |
| `git-user-email` | no       | github-actions[bot] noreply | Commit author email.                                                     |
| `github-token`   | no       | `${{ github.token }}`       | Token for `git push` and `gh`. Override with PAT/App for cross-repo PRs. |

Outputs: `changed`, `created`, `pr-number`, `pr-url`.

**Example caller — sign artifacts and open a PR:**

```yaml
name: Sign Scripts
on:
  push:
    branches: [main]
    paths: ['**.ps1']

jobs:
  sign:
    runs-on: windows-latest
    permissions:
      contents: write
      pull-requests: write
    steps:
      - uses: actions/checkout@v6
        with: { fetch-depth: 0 }

      - name: Sign scripts
        shell: pwsh
        run: ./sign.ps1

      - uses: DevSecNinja/.github/actions/open-pr@<sha>
        with:
          branch: chore/sign-scripts
          title: 'chore: sign scripts'
          paths: '**/*.ps1'
          labels: |
            automated
            chore
```

See [`actions/open-pr/README.md`](../actions/open-pr/README.md) for full
documentation and more examples.

### Harden runner (`actions/harden-runner/`)

Wraps `step-security/harden-runner` for runtime monitoring and optional egress
blocking inside the caller's job. This is a composite action rather than a
reusable workflow because runner hardening has to execute in the same job as the
build, test, or release steps it protects.

Start in audit mode, review the observed egress, then switch high-value jobs to
block mode with explicit `allowed-endpoints`.

See [`actions/harden-runner/README.md`](../actions/harden-runner/README.md) and
[ADR 0002](design-decisions/0002-runtime-ci-hardening.md).

### Release publish (`actions/release-publish/`)

Generates Conventional-Commit release notes via `git-cliff` and creates
an immutable GitHub Release with optional asset upload and preset notes
blocks. Composite (not reusable workflow) so any preceding
`actions/attest-build-provenance` step in the caller's job stays bound
to the caller's OIDC subject. See
[`actions/release-publish/README.md`](../actions/release-publish/README.md).

---

## Workflow templates

The `workflow-templates/` directory contains starter workflows that appear in
the GitHub UI under **Actions → New workflow** for repositories in this
organisation. Each template has a matching `.properties.json` file that
provides the display name, description, and category shown in the picker.

| Template                         | Purpose                                |
| -------------------------------- | -------------------------------------- |
| `lint.yml`                       | Linting pipeline                       |
| `pages.yml`                      | GitHub Pages deploy and PR previews    |
| `release.yml`                    | GitHub Release on tag push             |
| `config-sync.yml`                | Weekly config drift sync               |
| `label-sync.yml`                 | Sync labels from `.github/labels.yaml` |
| `labeler.yml`                    | Auto-label PRs and issues              |
| `todo-to-issue.yml`              | Convert TODO comments to issues        |
| `assign-issue-to-codeowners.yml` | Assign issues to CODEOWNERS            |

---

## Config sync

### Auto-synced files (`config-sync/files/`)

These files are kept identical across all repositories. The `config-sync.yml`
workflow opens a PR whenever a repo's copy drifts from the source. **Do not
edit these files in individual repos** — submit a change here instead.

The directory tree mirrors the layout in the calling repo: a file at
`config-sync/files/<path>` is synced to `<repo>/<path>`. To opt a single
repo out of a specific path, list it in `.github/.config-sync-ignore` at
the repo root.

| File                 | Purpose                                       |
| -------------------- | --------------------------------------------- |
| `.editorconfig`      | Editor formatting defaults                    |
| `.github/CODEOWNERS` | Canonical CODEOWNERS (default `@DevSecNinja`) |
| `.gitleaks.toml`     | Gitleaks allow-list                           |
| `.markdownlint.yaml` | Markdown lint rules                           |
| `.shellcheckrc`      | ShellCheck configuration                      |
| `.yamlfmt.yaml`      | yamlfmt formatting rules                      |
| `.yamllint.yaml`     | yamllint rules                                |
| `dprint.json`        | dprint Markdown formatter config              |
| `issue-labeler.yaml` | Issue auto-label rules                        |
| `pr-labeler.yaml`    | PR auto-label rules                           |
| `renovate.json5`     | Renovate base config reference                |

### Templates (`config-sync/templates/`)

These are **starting-point** files. Copy them into a new repository and adapt
as needed — they are not auto-synced. See
[`config-sync/templates/README.md`](../config-sync/templates/README.md) for
details.

---

## Renovate configuration

The `.renovate/` directory contains shared Renovate preset fragments imported
by individual repositories via their `renovate.json5`.

| Preset                  | Purpose                                                       |
| ----------------------- | ------------------------------------------------------------- |
| `base.json5`            | Core scheduling and PR settings                               |
| `autoMerge.json5`       | Auto-merge rules for patch/minor updates                      |
| `groups.json5`          | Dependency grouping                                           |
| `labels.json5`          | Label assignment for Renovate PRs                             |
| `packageRules.json5`    | Per-ecosystem rules                                           |
| `customManagers.json5`  | Custom regex managers (e.g. `mise-version` in workflow files) |
| `semanticCommits.json5` | Conventional Commits for Renovate PRs                         |

### Auto-merge strategy

PRs that Renovate can auto-merge are tagged with the **`merge: auto`** label.
Their titles also carry a trailing **`[automerge]`** suffix (via
`commitMessageSuffix`) so auto-merge PRs are easy to spot at a glance.
Code Owners are not requested as reviewers for routine Renovate PRs. Renovate
can still assign Code Owners if an automerge PR cannot merge cleanly.

**What auto-merges (minor + patch, via GitHub platform automerge):**

| Ecosystem                         | Scope                               | Condition                    |
| --------------------------------- | ----------------------------------- | ---------------------------- |
| GitHub Actions                    | `actions/*`, `docker/*`, `github/*` | All versions                 |
| Docker images                     | All                                 | Current version ≥ 1.0        |
| GitHub releases                   | All                                 | Current version ≥ 1.0        |
| Mise tools                        | All                                 | Current version ≥ 1.0        |
| npm                               | All                                 | Current version ≥ 1.0        |
| pip                               | All                                 | Current version ≥ 1.0        |
| Go modules                        | All                                 | Current version ≥ 1.0        |
| DevSecNinja devcontainer (digest) | `ghcr.io/devsecninja/*`             | Always (no wait time)        |
| Lock file maintenance             | All                                 | Always (branch merge, no PR) |

**What does NOT auto-merge:**

- Major version updates (all ecosystems)
- Pre-1.0 packages (`0.x` — semver minor can introduce breaking changes)
- GitHub Actions from untrusted organisations
- Digest-only updates (disabled entirely for supply-chain safety, except DevSecNinja devcontainer images)

### Safety nets

- **14-day `minimumReleaseAge`** on all dependency updates — ensures community
  vetting before adoption.
- **CI must pass** — `platformAutomerge: true` uses GitHub's native
  auto-merge, which respects required status checks.
- **OSV vulnerability alerts** bypass `minimumReleaseAge` (set to `0`) so
  security fixes merge immediately.
- **Schedule** — Renovate only runs on weekends and Fridays.
- **Digest updates disabled** — prevents merging potentially hijacked tags (except
  DevSecNinja-owned devcontainer images on `ghcr.io/devsecninja/`, which are trusted
  internal images and auto-merge immediately with no wait time).

### Consuming the preset

Repositories import the shared fragments in their `renovate.json5`:

```json5
{
  extends: [
    "config:recommended",
    "helpers:pinGitHubActionDigests",
    ":dependencyDashboard",
    ":semanticCommits",
    "github>DevSecNinja/.github//.renovate/autoMerge.json5",
    "github>DevSecNinja/.github//.renovate/base.json5",
    "github>DevSecNinja/.github//.renovate/customManagers.json5",
    "github>DevSecNinja/.github//.renovate/groups.json5",
    "github>DevSecNinja/.github//.renovate/labels.json5",
    "github>DevSecNinja/.github//.renovate/packageRules.json5",
    "github>DevSecNinja/.github//.renovate/semanticCommits.json5",
  ],
}
```

---

## Design decisions

Architecture Decision Records are stored in
[`docs/design-decisions/`](design-decisions/README.md).

| ADR                                                               | Title                                                | Status   |
| ----------------------------------------------------------------- | ---------------------------------------------------- | -------- |
| [0001](design-decisions/0001-reusable-workflow-version-inputs.md) | Reusable workflows must not default package versions | Accepted |

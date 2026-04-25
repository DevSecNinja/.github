# DevSecNinja/.github

Org-level GitHub configuration and shared automation for all **DevSecNinja**
repositories.

This repository provides:

-   **Reusable workflows** — consolidated CI/CD building blocks that every repo
    can call with a single `uses:` line.
-   **Workflow templates** — starter workflows surfaced in the GitHub UI's
    _"Actions → New workflow"_ picker.
-   **Config sync** — common tooling config files synced to every repository on
    a schedule, plus templates for files repos manage themselves.
-   **Renovate base configuration** — shared presets imported by each repo's
    `renovate.json5`.
-   **Org-level defaults** — default community health files, labels, and
    CODEOWNERS that apply across the organisation.

---

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
`on: workflow_call`. Pin the `uses:` ref to a release tag or commit SHA and
supply the required inputs.

> **Version inputs are always required** — the calling repo owns the tool
> version and annotates it with a `# renovate:` comment so Renovate can keep it
> current automatically (see [ADR 0001]).

### Lint (`lint.yml`)

Runs up to ten linters in a single job. Toggle individual linters on/off with
boolean inputs; all default to `true`.

| Input              | Description                                    |
| ------------------ | ---------------------------------------------- |
| `mise-version`     | **Required.** mise version to install.         |
| `lint-dprint`      | Markdown formatting (dprint). Default: `true`. |
| `lint-yamlfmt`     | YAML formatting (yamlfmt). Default: `true`.    |
| `lint-yamllint`    | YAML linting (yamllint). Default: `true`.      |
| `lint-actionlint`  | GitHub Actions linting. Default: `true`.       |
| `lint-gitleaks`    | Secret scanning (gitleaks). Default: `true`.   |
| `lint-shellcheck`  | Shell linting (shellcheck). Default: `true`.   |
| `lint-shfmt`       | Shell formatting (shfmt). Default: `true`.     |
| `lint-checkov`     | IaC security scan (checkov). Default: `true`.  |
| `lint-trivy`       | Filesystem scan (trivy). Default: `true`.      |
| `lint-zizmor`      | Actions security scan (zizmor). Default: `true`. |
| `lint-config-drift`| Config-drift check. Default: `false`.          |

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
```

### Release (`release.yml`)

Creates a GitHub Release from a version tag using `git-cliff` for release
notes.

| Input          | Description                              |
| -------------- | ---------------------------------------- |
| `mise-version` | **Required.** mise version to install.   |
| `tag`          | **Required.** Tag name, e.g. `v1.2.3`.  |

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

### Config Sync (`config-sync.yml`)

Syncs the files from `config-sync/files/` to the calling repository. Runs on a
weekly schedule and opens a PR when files drift.

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

## Workflow templates

The `workflow-templates/` directory contains starter workflows that appear in
the GitHub UI under **Actions → New workflow** for repositories in this
organisation. Each template has a matching `.properties.json` file that
provides the display name, description, and category shown in the picker.

| Template                            | Purpose                                  |
| ----------------------------------- | ---------------------------------------- |
| `lint.yml`                          | Linting pipeline                         |
| `release.yml`                       | GitHub Release on tag push               |
| `config-sync.yml`                   | Weekly config drift sync                 |
| `label-sync.yml`                    | Sync labels from `.github/labels.yaml`   |
| `labeler.yml`                       | Auto-label PRs and issues                |
| `todo-to-issue.yml`                 | Convert TODO comments to issues          |
| `assign-issue-to-codeowners.yml`    | Assign issues to CODEOWNERS             |

---

## Config sync

### Auto-synced files (`config-sync/files/`)

These files are kept identical across all repositories. The `config-sync.yml`
workflow opens a PR whenever a repo's copy drifts from the source. **Do not
edit these files in individual repos** — submit a change here instead.

| File                   | Purpose                                  |
| ---------------------- | ---------------------------------------- |
| `.editorconfig`        | Editor formatting defaults               |
| `.gitleaks.toml`       | Gitleaks allow-list                      |
| `.markdownlint.yaml`   | Markdown lint rules                      |
| `.shellcheckrc`        | ShellCheck configuration                 |
| `.yamlfmt.yaml`        | yamlfmt formatting rules                 |
| `.yamllint.yaml`       | yamllint rules                           |
| `dprint.json`          | dprint Markdown formatter config         |
| `issue-labeler.yaml`   | Issue auto-label rules                   |
| `pr-labeler.yaml`      | PR auto-label rules                      |
| `renovate.json5`       | Renovate base config reference           |

### Templates (`config-sync/templates/`)

These are **starting-point** files. Copy them into a new repository and adapt
as needed — they are not auto-synced. See
[`config-sync/templates/README.md`](config-sync/templates/README.md) for
details.

---

## Renovate configuration

The `.renovate/` directory contains shared Renovate preset fragments imported
by individual repositories via their `renovate.json5`. Presets include:

-   **`base.json5`** — core scheduling and PR settings
-   **`autoMerge.json5`** — auto-merge rules for patch/minor updates
-   **`groups.json5`** — dependency grouping
-   **`labels.json5`** — label assignment for Renovate PRs
-   **`packageRules.json5`** — per-ecosystem rules
-   **`customManagers.json5`** — custom regex managers (e.g. `mise-version`
    inputs in workflow files)
-   **`semanticCommits.json5`** — Conventional Commits for Renovate PRs

---

## Design decisions

Architecture Decision Records are stored in
[`docs/design-decisions/`](docs/design-decisions/README.md).

| ADR                                                                    | Title                                                | Status   |
| ---------------------------------------------------------------------- | ---------------------------------------------------- | -------- |
| [0001](docs/design-decisions/0001-reusable-workflow-version-inputs.md) | Reusable workflows must not default package versions | Accepted |

---

## Development

### Prerequisites

-   [mise](https://mise.jdx.dev/) — installs and manages all tooling

### Install tools

```sh
mise install
```

### Run pre-commit checks

```sh
mise exec -- lefthook run pre-commit
```

### Commit and release

Follow the [Conventional Commits](https://www.conventionalcommits.org) format.
See the [`commit-and-release`](.github/skills/commit-and-release/SKILL.md)
skill for the full step-by-step guide including how to cut a release with
`cog bump`.

---

## License

[MIT](LICENSE)

[ADR 0001]: docs/design-decisions/0001-reusable-workflow-version-inputs.md

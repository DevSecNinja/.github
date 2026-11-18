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
│   └── copilot-instructions.md   # Org-wide Copilot coding standards
├── .renovate/              # Renovate shared preset fragments
├── actions/                # Composite actions (run inside the caller's job)
├── copilot-models.json     # Reviewed model choices (data; explicit consumer opt-in)
├── config-sync/
│   ├── files/              # Files auto-synced to every repo (read-only)
│   │   ├── .github/instructions/     # Org-wide AI instructions, generated from ai-toolkit
│   │   └── .github/labels-base.yaml  # Base label set synced to all repos
│   ├── sync-ai-toolkit-instructions.sh  # Regenerates files/.github/instructions/
│   └── templates/          # Starting-point files — copy & adapt per repo
├── docs/
│   └── design-decisions/   # Architecture Decision Records (ADRs)
├── profile/
│   └── README.md           # Organisation profile shown on github.com/DevSecNinja
├── scripts/                # Scripts the reusable workflows run (one folder per workflow)
├── tests/                  # Contract and script tests (`mise run test`)
└── workflow-templates/     # Starter workflows for the GitHub Actions UI picker
```

---

## Shared Copilot model policy

[`copilot-models.json`](../copilot-models.json) centralizes reviewed, explicit
model choices for opt-in CLI consumers. Consumers fetch this JSON data from
`main`, validate it, log its revision and effective model, and fail closed rather
than use `auto` or a fallback. A personal `.github` repository does not inject
the policy into other repositories automatically. See the
[onboarding and change guide](copilot-model-policy.md) for the contract,
overrides, advance notification, account-specific availability, and rollback.

## Reusable workflows

All reusable workflows live in `.github/workflows/` and are called with
`on: workflow_call`. Pin the `uses:` ref to a full commit SHA with a version
comment and supply the required inputs.

> **Version inputs are always required.** The calling repo owns the tool
> version and annotates it with a `# renovate:` comment so Renovate opens a PR
> (which runs the caller's CI) when a new version is released.
> See [ADR 0001](design-decisions/0001-reusable-workflow-version-inputs.md).

**Workflow scripts.** A `run:` step holds one simple command (#537); longer
logic lives in `scripts/<workflow>/` (for example `scripts/pages/` and
`scripts/label-sync/`), where shellcheck, shfmt and the tests in `tests/` reach
it. A reusable workflow runs in the caller's checkout, so each job that runs a
script first checks `scripts/<workflow>/` out from the DevSecNinja/.github
commit the caller pinned (`job.workflow_sha`) and moves it to `$RUNNER_TEMP`,
where a code checkout doesn't delete it and the caller's linters don't scan it.
`tests/workflow-script-fetch.py` enforces this. Credential preflights that read
the Automation App key are the exception: they stay inline, opted out with
`# lint: allow-inline-script`, because `tests/app-key-confinement.py` pins their
`run:` by hash and allows no earlier step (see
[`automation-app.md`](automation-app.md)). In `config-sync.yml` and
`apm-sync.yml` the script fetch therefore follows the preflight.
`apm-materialize.yml` runs in this repository rather than as a reusable
workflow, so it calls `scripts/apm-materialize/` from its own checkout.

### Lint (`lint.yml`)

Runs up to sixteen linters. By default, linter failures are reported without
failing the workflow; set `lint-fail-on-error` to `true` to make lint failures
fail the workflow. Toggle individual linters on/off with boolean inputs; all
linter toggles default to `true`.

**Job layout (`lint-job-mode`).** Every job is billed at least one full minute,
so one job per linter costs about eight minutes per run even when each linter
takes seconds. `auto` (the default) therefore runs every enabled linter as a
step of a single `all linters` job on **private** repositories, and keeps one
job per linter (`lint / dprint`, `lint / zizmor`, …) on **public** ones, where
minutes are free. Force either layout with `single` or `parallel`. In single-job
mode a failing linter does not stop the others; the last step lists every
failure. Events without a repository payload (such as `schedule`) use the
parallel layout under `auto`. Before switching a repository whose ruleset
requires per-linter checks to `single`, require `all linters` instead — skipped
per-linter jobs report success. See
[ADR 0010](design-decisions/0010-batch-renovate-updates-to-save-actions-minutes.md).

**Linter scripts.** Both layouts run the same scripts from `scripts/lint/` of
this repository, where shellcheck, shfmt and `tests/lint-scripts.sh` reach them.
Because `lint.yml` runs in the caller's checkout, every job first checks those
scripts (and the inline-script checker) out from the DevSecNinja/.github commit
the caller pinned (`job.workflow_sha`), then moves them to `$RUNNER_TEMP`, where
the caller's own linters don't scan them.

**Tool installation.** Every job runs a full `mise install` of the caller's
mise config, never a per-linter subset. The `pipx:` tools (yamllint, checkov)
depend on Python, so when the caller configures one (for example through
`.python-version` and `idiomatic_version_file_enable_tools = ["python"]`), mise
installs that Python first. Callers without a configured Python get no Python
download. Releases up to v2.0.x installed only `uv pipx:<tool>` and fail for
callers that configure Python; v2.1.0+ fixes this.

**gitleaks.** gitleaks always runs with `--redact`, and what it scans depends
on the event (v4.1.0+):

- **Pull requests and merge queues** scan only their own commits: those
  reachable from the head but not from the base SHA or the base branch's
  current tip, so base-branch commits merged into the PR are skipped. A secret
  added in the PR fails it, and older history never shows up on an unrelated
  PR. Each finding is annotated on the PR (`::error` with the file, line, rule
  ID and short commit SHA), and the job summary gets a table of rule,
  file:line, commit and author date. Only those fields leave the report, never
  the secret, match or matched line. The same fields plus each finding's
  `.gitleaksignore` fingerprint are uploaded as the
  `gitleaks-findings-<check run ID>` artifact, kept for five days. Under
  `pull_request_target` the PR's commits aren't checked out, so the step fails
  with an explanation instead of scanning.
- **Other events** (push, schedule, dispatch, including dispatch on a PR
  branch) scan the full history, so new gitleaks rules re-check old commits.
  This only reports, with a warning that gives the count. Job logs and
  artifacts of public repositories are public, so there the findings go only to
  code scanning (SARIF, category `gitleaks/history`), whose alerts need write
  access. They're filed as high-severity security alerts (`security-severity
  8.0`, tags `security` and `secret`, level `error`), not quality warnings. The log shows the count only: gitleaks' own log is withheld, since its
  diagnostics can name findings, and a failed scan prints a generic error. There
  is no file, line, commit, summary or artifact. The SARIF paths are
  percent-encoded and repeated tags removed, so the upload step never logs a path
  or rejects the file, and runs with debug logging skip the upload,
  which then logs the paths it can't fingerprint. Keep `upload-sarif: true` on
  public repositories, or the findings aren't published anywhere. Private
  repositories get the full log, annotations, summary and artifact instead.
  Internal repositories, whose logs every enterprise member can read, and a
  failed visibility lookup count as public.
  Repositories whose Lint caller runs on pull requests only get the full-history
  scan from a second caller, after each merge, weekly and on dispatch (this
  repository's `secret-scan-caller.yml`). It calls the include mode,
  [`lint-include.yml`](#lint-include-mode-lint-includeyml), with only
  `lint-gitleaks: true`, so linters added to `lint.yml` later never start
  running there. A Lint caller that also runs on push already scans the history
  there, so drop `push` below.

```yaml
name: Secret scan
on:
  push:
    branches: ["main"]
  schedule:
    - cron: "23 5 * * 1"
  workflow_dispatch:

permissions:
  contents: read

jobs:
  gitleaks:
    uses: DevSecNinja/.github/.github/workflows/lint-include.yml@<sha> # v4.4.0
    permissions:
      contents: read
      security-events: write
    with:
      # renovate: datasource=github-releases depName=jdx/mise
      mise-version: "2026.10.19"
      # Findings only report; fail the run if the scan or upload fails.
      lint-fail-on-error: true
      # upload-sarif: false # private repos without GitHub Advanced Security
      lint-gitleaks: true
```

**Language linters.** Linters for a programming language run only when the
repository has files of that language: a first step lists them with
`git ls-files` (`scripts/lint/language-files.sh`), and without any it skips the
mise install and the linter, so the job costs seconds. Generated and vendored
paths don't count: the excludes of the shared `dprint.json` (Spec Kit output,
APM-deployed agent files, `node_modules`, `.venv*`).

A language linter also runs only when the repository pins its tool in its mise
config: pinning is the opt-in. Without the pin, the linter is skipped with a
warning that names the fix, and the step passes, so a `lint.yml` bump never
turns a repository's CI red before it has adopted the linter. Once the tool is
pinned, findings fail the linter like any other.

- **ruff** (`lint-ruff`, Python, after v4.5.0) runs `ruff check` and
  `ruff format --diff` on the `*.py` and `*.pyi` files once `ruff` is pinned
  in the repository's mise config. ruff reads the repository's own `ruff.toml`,
  `.ruff.toml` or `[tool.ruff]` in `pyproject.toml`; config-sync's
  [`ruff.toml` template](../config-sync/templates/ruff.toml) is a starting
  point. Findings are annotated on the PR, and with `upload-sarif` they also go
  to code scanning (category `ruff`).
- **Biome** (`lint-biome`, JavaScript, TypeScript, JSON and CSS, after v4.6.0)
  runs `biome ci`, which lints and checks formatting and import order without
  writing, on the `*.js`, `*.mjs`, `*.cjs`, `*.jsx`, `*.ts`, `*.mts`, `*.cts`,
  `*.tsx`, `*.json`, `*.jsonc` and `*.css` files once `biome` 2.4.0 or later is
  pinned in the repository's mise config (an older pin is skipped with a warning,
  like a missing one). Biome reads the repository's own `biome.json` or
  `biome.jsonc`; config-sync's
  [`biome.json` template](../config-sync/templates/biome.json) is a starting
  point. Findings are annotated on the PR, and with `upload-sarif` they also go
  to code scanning (category `biome`). `lint-biome-exclude` skips more paths,
  such as a directory with another root Biome config, which Biome rejects.
  Biome steps aside in repositories that configure ESLint (`eslint.config.*`,
  `.eslintrc*`), which lint in their own CI with their plugins; set
  `lint-biome-with-eslint` to run both. dprint formats only Markdown.
- **PSScriptAnalyzer** (`lint-psscriptanalyzer`, PowerShell, after v4.6.0)
  analyzes the `*.ps1`, `*.psm1` and `*.psd1` files with the runner's `pwsh`.
  It needs no mise: pass `psscriptanalyzer-version` instead, with a Renovate
  annotation (see the [workflow template](../workflow-templates/lint.yml)).
  Without it, a repository with PowerShell files gets a warning that names the
  fix, and the linter skips instead of failing. Once the version is set,
  findings fail as below. That version is installed from the PowerShell
  Gallery unless the runner has it already. The repository's
  `PSScriptAnalyzerSettings.psd1` configures it; config-sync's
  [template](../config-sync/templates/PSScriptAnalyzerSettings.psd1) is a
  starting point. Errors and warnings fail the linter, information findings
  are only annotated. Findings are annotated on the PR, and with `upload-sarif`
  they also go to code scanning (category `psscriptanalyzer`).

**Inline scripts.** Code in a `run:` block is out of reach of linters,
formatters and tests, so a `run:` step may hold exactly one line with one
simple command, such as `./scripts/build.sh`, `bash .github/scripts/x.sh`,
`pwsh -File scripts/x.ps1` or `mise run test`. The `inline scripts` linter
(`scripts/lint-inline-scripts.py`, #537) parses the workflows in
`.github/workflows/` and every composite action (`action.yml` /
`action.yaml`) with a YAML parser, and reports each `run:` step that has more
than one line; a pipe, `&&`, `||`, `;` or `&`; `$(…)`, backticks or `<(…)`; a
heredoc or here-string; `if`/`for`/`while`/`case`; a `${{ }}` expression (pass
it through `env:`, which also prevents template injection); or any code under a
non-bash `shell:` (python, pwsh, cmd, …, including the implicit pwsh of a
Windows `runs-on`). Move such code into a script under
`scripts/` or `.github/scripts/` (or the composite action's own directory),
where shellcheck, shfmt and tests reach it. A step that must stay inline opts
out with a comment that gives a reason, directly above the step or inside it
(a YAML comment, or a shell comment in the script; text in strings doesn't
count):

```yaml
# lint: allow-inline-script bootstraps the runner before checkout
- name: Prepare runner
  run: |
    ...
```

Findings are annotated on the file and line of the `run:` key and listed in
the job summary with the opt-outs. They are warnings by default; set
`lint-inline-scripts-blocking: true` to report errors and fail the linter
(a file that can't be parsed then fails it too). This repository's own Lint
runs it blocking. A
later major release makes blocking the default. The checker runs with the
runner's system Python, which ships PyYAML (`ubuntu-24.04`).

The `line endings` linter (`scripts/lint/line-endings.sh`) reports every text
file committed with CRLF or mixed line endings. It reads `git ls-files --eol`,
so git's own `.gitattributes` resolution decides: a path with `-text` (or
`binary`) is stored byte for byte and skipped, and an `eol=crlf` path passes
once git stores it with LF (it only checks it out with CRLF); one still stored
with CRLF is reported like any other. Those rules are
the only way to keep CRLF; the linter has no exclude input. Findings are errors
that fail the linter (and the workflow only with `lint-fail-on-error: true`);
`lint-line-endings-blocking: false` reports them as warnings. To fix them, put
`* text=auto eol=lf` in `.gitattributes` (config-sync bootstraps it, see
[Templates](#templates-config-synctemplates)), run `git add .gitattributes` and
`git add --renormalize .`, and commit both. The linter needs only git.

**zizmor config.** After v4.7.0, zizmor runs with the shared
[`scripts/lint/zizmor.yml`](../scripts/lint/zizmor.yml), which ships with
`lint.yml` at the commit the caller pinned, unless the repository has its own
`.github/zizmor.yml` or `zizmor.yml` (or `.yaml`). zizmor loads one config only,
so a repository config replaces the shared one and has to repeat its rules. The
shared config disables the `self-repository` audit (zizmor 1.30+), which asks
to rewrite every workspace-relative `uses: ./...` as `uses: $/...`. We pick the
form per workflow instead: `$/` where a reusable workflow must call a sibling at
its own commit (`lint-include.yml` calling `lint.yml`), `./` in callers.

| Input                          | Description                                                            |
| ------------------------------ | ---------------------------------------------------------------------- |
| `mise-version`                 | **Required.** mise version to install.                                 |
| `golangci-lint-version`        | **Required.** golangci-lint version to install.                        |
| `go-version-file`              | Go version file for setup-go. Default: `go.mod`.                       |
| `psscriptanalyzer-version`     | PSScriptAnalyzer version; skips with a warning if unset. After v4.6.0. |
| `lint-config-dir`              | Optional linter config directory. Default: `""`.                       |
| `lint-fail-on-error`           | Fail when a linter fails. Default: `false`.                            |
| `lint-job-mode`                | `auto`, `single`, or `parallel` (see above). Default: `auto`. v3.3.0+. |
| `upload-sarif`                 | Upload SARIF (checkov, trivy, zizmor, language linters). Default: on.  |
| `lint-dprint`                  | Markdown formatting (dprint). Default: `true`.                         |
| `lint-yamlfmt`                 | YAML formatting (yamlfmt). Default: `true`.                            |
| `lint-yamllint`                | YAML linting (yamllint). Default: `true`.                              |
| `lint-actionlint`              | GitHub Actions linting. Default: `true`.                               |
| `lint-gitleaks`                | Secret scanning (gitleaks). Default: `true`.                           |
| `lint-go`                      | Go linting (golangci-lint). Default: `true`.                           |
| `lint-shellcheck`              | Shell linting (shellcheck). Default: `true`.                           |
| `lint-shfmt`                   | Shell formatting (shfmt). Default: `true`.                             |
| `lint-checkov`                 | IaC security scan (checkov). Default: `true`.                          |
| `lint-trivy`                   | Filesystem scan (trivy). Default: `true`.                              |
| `lint-zizmor`                  | Actions security scan (zizmor). Default: `true`.                       |
| `lint-ruff`                    | Python linting (ruff, see above). Default: `true`. After v4.5.0.       |
| `lint-biome`                   | JS/TS/JSON/CSS linting (Biome). Default: `true`. After v4.6.0.         |
| `lint-biome-exclude`           | Bash pattern of paths Biome skips. Default: `""`. After v4.6.0.        |
| `lint-biome-with-eslint`       | Run Biome next to ESLint. Default: `false`. After v4.6.0.              |
| `lint-psscriptanalyzer`        | PowerShell linting (PSScriptAnalyzer). Default: `true`. After v4.6.0.  |
| `lint-config-drift`            | Config-drift check. Default: `false`.                                  |
| `lint-inline-scripts`          | Inline-script check (see above). Default: `true`. After v4.4.0.        |
| `lint-inline-scripts-blocking` | Report inline scripts as errors. Default: `false`. After v4.4.0.       |
| `lint-line-endings`            | CRLF line-endings check (see above). Default: `true`. After v4.7.0.    |
| `lint-line-endings-blocking`   | Report CRLF as errors and fail. Default: `true`. After v4.7.0.         |

**Example caller:**

```yaml
on:
  pull_request:
  # Keep push only when SARIF is uploaded (code scanning needs a
  # default-branch baseline); otherwise the PR run already covers the commit.
  push:
    branches: ["main"]

# A newer push to a PR cancels its running run. A running push/main run is
# never cancelled, but a queued one is superseded by a newer push (only the
# latest commit's result matters, and it saves minutes).
concurrency:
  group: ${{ github.workflow }}-${{ github.event.pull_request.number || github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

jobs:
  lint:
    uses: DevSecNinja/.github/.github/workflows/lint.yml@<sha> # v3.3.0
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
      # lint-job-mode: auto # single | parallel
```

### Lint, include mode (`lint-include.yml`)

`lint.yml` is the exclude mode: every linter runs unless the caller sets
`lint-<name>: false`. `lint-include.yml` (v4.4.0+) is the include mode: every
linter is off unless the caller sets `lint-<name>: true`, and linters added to
`lint.yml` later stay off until a caller enables them. Use it when a caller
wants a few specific linters, such as the secret-scan caller above, instead of
keeping a list of linters to turn off.

It takes the same inputs as `lint.yml` with the same defaults, except that
every `lint-<name>` linter defaults to `false`, and passes them all to the
`lint.yml` of the same commit (through GitHub's `$/` self-repository syntax),
so linters behave exactly as described above. Grant the calling job
`contents: read` and `security-events: write`. `tests/lint-include.py` fails CI
when `lint.yml` gains an input that `lint-include.yml` doesn't forward.

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

### Release Please (`release-please.yml`)

Opens or updates release PRs and creates version tags from Conventional
Commits. GitHub App authentication is mandatory so release PR and tag
events trigger downstream workflows; the reusable fails closed for
missing, empty or whitespace-only credentials and never uses
`GITHUB_TOKEN`. It authenticates as the shared DevSecNinja Automation
App — see [`automation-app.md`](automation-app.md).

| Input / secret               | Description                                                                         |
| ---------------------------- | ----------------------------------------------------------------------------------- |
| `AUTOMATION_APP_PRIVATE_KEY` | Secret. App private key; pass it by name (v3.4.0+). The App ID is read from `vars`. |
| `app-id`                     | Explicit App ID; overrides the `AUTOMATION_APP_ID` variable. Default: empty.        |
| `app-private-key`            | Secret. Explicit private key; overrides `AUTOMATION_APP_PRIVATE_KEY`.               |
| `app-environment`            | Environment holding the credentials. Default: `production`.                         |
| `target-branch`              | Branch to track. Default: `main`.                                                   |
| `config-file`                | Release Please configuration path.                                                  |
| `manifest-file`              | Release Please manifest path.                                                       |

The App installation needs only Contents and Pull requests write
permissions (Metadata read is automatic). The repository does not need
**Allow GitHub Actions to create and approve pull requests**.

Callers choose one publication pattern:

1. Set `skip-github-release: false` for a direct Release Please GitHub
   Release, with no competing tag publisher. This is the default for
   simple consumers.
2. Set `skip-github-release: true` with a tag-triggered `release.yml`
   that owns assets, attestations, notes, and publication. Release
   Please still creates the tag in this pattern; use it only when those
   custom publication steps are needed.

See the [onboarding guide](release-please-onboarding.md),
[ADR 0007](design-decisions/0007-mandatory-release-please-app-authentication.md)
and [ADR 0011](design-decisions/0011-single-automation-github-app.md).

### Pages (`pages.yml`)

Runs configurable site validation commands, deploys the production artifact to
GitHub Pages and/or Cloudflare Pages from the configured production branch, and
optionally deploys same-repository pull request previews to Cloudflare Pages.
Cloudflare jobs detect missing Cloudflare secrets before any deploy work. Missing
secrets fail production Cloudflare deploys and skip preview-only deploys.
An optional production custom domain can be registered after deployment. Callers
may also opt into safe DNS CNAME creation; DNS remains unmanaged by default.

| Input                              | Description                                                                                      |
| ---------------------------------- | ------------------------------------------------------------------------------------------------ |
| `node-version`                     | **Required.** Node.js version to install.                                                        |
| `node-cache`                       | Package manager cache for test and production jobs. Default: empty (disabled).                   |
| `go-version`                       | Go version to install before the build. Required for Hugo Modules. Default: empty (no Go setup). |
| `go-version-file`                  | File to read the Go version from, used only when `go-version` is empty.                          |
| `wrangler-version`                 | **Required.** Wrangler version to install for previews; inputs cannot be conditional.            |
| `production-branch`                | Branch that deploys to production. Default: `main`.                                              |
| `artifact-path`                    | Directory uploaded to Pages. Default: `.`.                                                       |
| `artifact-name`                    | Deploy a prebuilt artifact from an earlier caller job instead of building. Default: empty.       |
| `install-command`                  | Dependency install command. Default: `npm ci`.                                                   |
| `test-command`                     | Validation command block. Default: empty.                                                        |
| `test-setup-command`               | Optional command after install and before tests.                                                 |
| `build-command`                    | Optional build command before deployment.                                                        |
| `build-github-token`               | Run `build-command` in the read-only test job with `GITHUB_TOKEN`. Default: `false`.             |
| `build-artifact-name`              | Artifact name used by `build-github-token`; unique per call. Default: `pages-build`.             |
| `pre-deploy-command`               | Optional production-only pre-upload command.                                                     |
| `pre-preview-command`              | Optional preview-only pre-deploy command.                                                        |
| `update-sitemap-lastmod`           | Update sitemap `<lastmod>` dates. Default: `false`.                                              |
| `sitemap-path`                     | Sitemap file path. Default: `sitemap.xml`.                                                       |
| `github-pages`                     | Deploy production to GitHub Pages. Default: `true`.                                              |
| `cloudflare-preview`               | Enable Cloudflare pull request previews. Default: `true`.                                        |
| `cloudflare-production`            | Deploy production to Cloudflare Pages. Default: `false`.                                         |
| `cloudflare-production-on-release` | Deploy Cloudflare production only on `release` events, not every main commit. Default: `false`.  |
| `cloudflare-custom-domain`         | Register one lowercase FQDN after a production deploy. Default: empty.                           |
| `cloudflare-manage-dns`            | Create the custom-domain CNAME when absent; never replace conflicts. Default: `false`.           |
| `cloudflare-dns-zone`              | Lowercase zone apex containing the custom domain. Required when DNS management is enabled.       |
| `cloudflare-dns-proxied`           | Proxy a workflow-created CNAME through Cloudflare. Default: `true`.                              |
| `cloudflare-acceptance`            | Deploy an acceptance build to Cloudflare on main commits. Default: `false`.                      |
| `cloudflare-acceptance-branch`     | Cloudflare branch name for acceptance deploys. Default: `acceptance`.                            |
| `cloudflare-project-name`          | Cloudflare Pages project; lowercase letters, numbers, and hyphens only.                          |
| `cloudflare-production-branch`     | Cloudflare production branch. Default: `main`.                                                   |
| `preview-comment-marker`           | Marker used to update the preview PR comment.                                                    |

Build, pre-deploy, and pre-preview commands run with an `APP_COMMIT_SHA`
environment variable set to `${{ github.event.pull_request.head.sha || github.sha }}`.
On `pull_request` events `github.sha` is the ephemeral merge commit, so builds
should read `APP_COMMIT_SHA` to stamp the real PR head commit in previews.

**Runs that cost nothing.** Every job is billed at least one minute, so the
workflow skips whole runs that cannot change anything (v3.3.0+; see
[ADR 0010](design-decisions/0010-batch-renovate-updates-to-save-actions-minutes.md)):

- `pull_request: edited` events are skipped unless the base branch changed —
  title and body edits (Renovate rewrites its PR bodies on most runs) never
  change the site. New callers should not subscribe to `edited` at all.
- `closed` events are skipped when there is no preview to clean up:
  Renovate/Dependabot PRs, fork PRs, or `cloudflare-preview: false`.
- Renovate/Dependabot PRs (matched on PR author as well as actor) run the
  tests but never `detect-cloudflare` or a preview deploy, even when a human
  updates the branch.

Production deploys on push, release, and `workflow_dispatch` are never
skipped, whoever triggered them.

#### Deploying a prebuilt artifact

This workflow provides a fixed build environment: Node, Go, an install command
and a build command. A build that needs anything else — a `GITHUB_TOKEN` to
read the API, a cloud credential, a toolchain that isn't here — should not try
to smuggle it through more inputs. Build it in your own job and hand over the
result:

```yaml
jobs:
  build:
    runs-on: ubuntu-24.04
    permissions:
      contents: read
      issues: read          # whatever *your* build needs
    steps:
      - uses: actions/checkout@<sha>
      - uses: actions/setup-node@<sha>
        with:
          node-version: "24"
      - run: npm ci && npm test && npm run build
        env:
          GITHUB_TOKEN: ${{ github.token }}
      - uses: actions/upload-artifact@<sha>
        with:
          name: site
          path: dist
          # v4+ omits dotfiles; needed for .well-known, .nojekyll, …
          include-hidden-files: true

  pages:
    needs: build
    uses: DevSecNinja/.github/.github/workflows/pages.yml@<sha> # vX.Y.Z
    permissions:
      contents: read
      deployments: write
      id-token: write
      pages: write
    with:
      artifact-name: site
      artifact-path: dist
      cloudflare-project-name: my-site
```

A repository may call this workflow more than once — once per site. Cloudflare
deploy and preview concurrency is scoped per project name, so parallel calls do
not cancel or serialise each other. Give each call its own
`preview-comment-marker` so the preview comments don't overwrite one another.

`artifact-name` and `build-command` are mutually exclusive — the artifact is
deployed exactly as uploaded. With `artifact-name` set the deploy jobs skip
Node/Go setup, install and build entirely.

For builds that only need `GITHUB_TOKEN` (for example to avoid GitHub API rate
limits), set `build-github-token: true` with `build-command` instead. The
command runs once in the `contents: read` test job with the token exported, and
the deploy jobs download the result; no deploy job sees the token. See
[ADR 0012](design-decisions/0012-pages-build-github-token.md).

#### Cloudflare custom-domain migration

Set `cloudflare-custom-domain` only with `cloudflare-production: true`, an
explicit `cloudflare-project-name`, the required Wrangler version, and
`CLOUDFLARE_ACCOUNT_ID` / `CLOUDFLARE_API_TOKEN` secrets. Registration needs
Account Cloudflare Pages Write permission. The workflow validates the domain as
a lowercase FQDN, deploys production, then reads or creates that domain through
the official Pages API. Preview, acceptance, pull request cleanup, and GitHub
Pages deploys never register it.

The registration job reports three reusable-workflow outputs:
`cloudflare-custom-domain-status` and
`cloudflare-custom-domain-dns-target`, plus
`cloudflare-custom-domain-dns-action` (`unmanaged`, `created`, or `no-op`). The
DNS target comes from the Pages project API's `subdomain` field, not from the
requested project name. Cloudflare can assign a collision-safe value such as
`net-worth-calculator-xn8.pages.dev`, even when
`cloudflare-project-name` is `net-worth-calculator`.

Wrangler remains responsible for Pages project creation and deployment. It does
not provide robust generic DNS-record lifecycle management, so the optional
cutover uses Cloudflare's official REST API with the same token. To enable it,
set `cloudflare-manage-dns: true`, provide the containing zone apex through
`cloudflare-dns-zone`, and optionally set `cloudflare-dns-proxied` (default
`true`). The token then needs Account Cloudflare Pages Write, Zone Read, and DNS
Edit permissions.

The workflow resolves exactly one active zone in the configured account, reads
all exact-name records, and creates a TTL-auto CNAME only when no record exists.
An exact CNAME to the resolved target with the requested proxy state is a no-op.
Any other type, target, proxy state, duplicate, or ambiguous zone fails without
modification. It never replaces or deletes a record.

For a workflow-managed cutover:

1. Deploy and verify the generated `pages.dev` site.
2. Set `cloudflare-custom-domain`, `cloudflare-manage-dns: true`, and
   `cloudflare-dns-zone`. The custom domain must equal the zone or be its
   subdomain.
3. Review the summary for the resolved project, CNAME target, DNS action, proxy
   state, and Pages domain status. A bounded activation wait may end in
   `initializing` or `pending` while Cloudflare finishes propagation; failed or
   unexpected states fail the job.
4. Keep the previous host or DNS value available as a rollback path until the
   custom domain and certificate are stable. Disabling DNS management does not
   delete records. To roll back a newly created record, restore the prior service
   first if applicable, then explicitly remove the CNAME in Cloudflare.

Leave `cloudflare-manage-dns` at its default `false` for manual or externally
managed DNS. Registration retains the v3.1 behavior and reports the target
without calling the DNS API.

Because artifacts are scoped to the workflow run and a reusable workflow's jobs
run inside the caller's run, no extra permissions and no credential handoff are
involved. Note that the same artifact is deployed to previews and to
production; if previews must be built without credentials, branch on
`github.event_name` in your own build job. See
[ADR 0006](design-decisions/0006-prebuilt-artifact-deploys.md).

**Example caller:**

```yaml
on:
  push:
    branches: ["main"]
  pull_request:
    # No `edited`: title/body edits never change the site.
    types: [opened, synchronize, reopened, closed]
  workflow_dispatch:

# A newer push to a PR cancels its running run. A running push/main run is
# never cancelled, but a queued one is superseded by a newer push (only the
# latest commit is worth deploying, and it saves minutes).
concurrency:
  group: ${{ github.workflow }}-${{ github.event.pull_request.number || github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

jobs:
  pages:
    uses: DevSecNinja/.github/.github/workflows/pages.yml@<sha> # v3.3.0
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
      # Required when the site resolves a theme through Hugo Modules, which
      # shells out to Go. Without it the runner's preinstalled Go is used.
      # renovate: datasource=golang-version depName=go
      go-version: "1.26.5"
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
      # cloudflare-custom-domain: "www.example.com"
      # cloudflare-manage-dns: true
      # cloudflare-dns-zone: "example.com"
      # cloudflare-dns-proxied: true
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

**APM-managed paths are skipped.** When the calling repo has an
`apm.lock.yaml`, every path listed there under `deployed_files` is left
alone. So is every generated file whose provenance marker names a package
the repo installs whole through APM, even when the repo's pinned release
doesn't ship that file yet, and every file generated from the calling repo
itself. A subpath pin (`owner/repo/<path>#vX.Y.Z`) only owns the files it
deploys. A repo that installs `DevSecNinja/ai-toolkit` through APM keeps its
own pinned copy of the org-wide AI instructions instead of getting a second
one. See [Org-wide AI instructions](#org-wide-ai-instructions-ai-toolkit).

| Input / secret               | Description                                                                         |
| ---------------------------- | ----------------------------------------------------------------------------------- |
| `sync-templates`             | Also bootstrap the other `config-sync/templates/` files. Default: `false`.          |
| `central-ref`                | Git ref of `DevSecNinja/.github` to sync from. Default: `main`.                     |
| `AUTOMATION_APP_PRIVATE_KEY` | Secret. App private key; pass it by name (v3.4.0+). The App ID is read from `vars`. |
| `app-id`                     | Explicit App ID; overrides the `AUTOMATION_APP_ID` variable. Default: empty.        |
| `app-private-key`            | Secret. Explicit private key; overrides `AUTOMATION_APP_PRIVATE_KEY`.               |
| `app-environment`            | Environment holding the credentials. Default: `production`.                         |

**Authentication (v3.4.0+).** The sync PR is opened as the shared
DevSecNinja Automation GitHub App (see [`automation-app.md`](automation-app.md)),
so it runs the repository's CI and needs no _Allow GitHub Actions to create
and approve pull requests_ setting. Without App credentials the workflow
falls back to `GITHUB_TOKEN` with a warning naming what is missing; that PR
only opens when the setting is enabled, and it runs no CI.

The calling job grants `contents: write` and `pull-requests: write` (used by
the fallback). `issues: write` is no longer needed: the `config-sync` label is
created with the Pull requests permission. A caller that grants less than the
job requests fails with `startup_failure` before any step runs.

**Example caller:**

```yaml
jobs:
  sync:
    uses: DevSecNinja/.github/.github/workflows/config-sync.yml@<sha> # v3.4.0
    permissions:
      contents: write
      pull-requests: write
    secrets:
      AUTOMATION_APP_PRIVATE_KEY: ${{ secrets.AUTOMATION_APP_PRIVATE_KEY }}
    # with:
    #   sync-templates: true   # also bootstrap template files for new repos
```

### Vendored File Sync (`vendored-file-sync.yml`)

Runs a caller-provided refresher command for repo-specific vendored files,
checks the configured paths for drift, and optionally opens or updates a PR
using [`actions/open-pr/`](../actions/open-pr/README.md).
The caller controls token permissions: grant `contents: read` for validation,
or `contents: write` and `pull-requests: write` when `create-pr: true`.

Use the same refresher command in two places:

- **Scheduled/manual maintenance:** call this workflow with `create-pr: true`
  (the default) so refreshed vendored files land through a normal PR.
- **Pull-request validation:** call this workflow with `create-pr: false` so a
  PR that directly introduces vendored drift fails until the refreshed files
  are committed.

| Input             | Description                                                                 |
| ----------------- | --------------------------------------------------------------------------- |
| `refresh-command` | **Required.** Command that refreshes vendored files in the caller repo.     |
| `paths`           | **Required.** Newline-delimited pathspecs to watch and stage.               |
| `create-pr`       | Open/update a PR on drift. Set to `false` for validation-only PR lint.      |
| `branch`          | Working branch for the maintenance PR. Default: `chore/vendored-file-sync`. |
| `base`            | Base branch for the maintenance PR. Default: `main`.                        |
| `pr-title`        | PR title and default commit message. Default: `chore: sync vendored files`. |
| `pr-body`         | PR body (Markdown). Default: `""`.                                          |
| `labels`          | Newline-delimited labels to apply on PR creation.                           |
| `commit-message`  | Override the commit message.                                                |
| `draft`           | Open the PR as a draft. Default: `false`.                                   |
| `signoff`         | Add `Signed-off-by` trailer. Default: `false`.                              |

Outputs: `changed`, `pr-number`, `pr-url`.

**Example caller — scheduled/manual auto-remediation plus PR validation:**

```yaml
name: Vendored File Sync

on:
  pull_request:
    paths:
      - scripts/lib/**
      - scripts/update-log-sh.sh
  schedule:
    - cron: "0 6 * * 1"
  workflow_dispatch:

permissions:
  contents: read

jobs:
  validate:
    if: github.event_name == 'pull_request'
    uses: DevSecNinja/.github/.github/workflows/vendored-file-sync.yml@<sha> # v1.4.0
    permissions:
      contents: read
    with:
      refresh-command: bash scripts/update-log-sh.sh
      paths: scripts/lib/
      create-pr: false

  sync:
    if: github.event_name != 'pull_request'
    uses: DevSecNinja/.github/.github/workflows/vendored-file-sync.yml@<sha> # v1.4.0
    permissions:
      contents: write
      pull-requests: write
    with:
      refresh-command: bash scripts/update-log-sh.sh
      paths: scripts/lib/
      branch: chore/sync-vendored-log-sh
      pr-title: 'chore: sync vendored log.sh'
      pr-body: |
        Refreshes the vendored `scripts/lib/log.sh` files from upstream.
      labels: |
        automated
        vendored-file-sync
```

### Label Sync (`label-sync.yml`)

Syncs the repository's labels to the actual GitHub labels on the repo. By
default it merges the org-wide base label set
(`.github/labels-base.yaml`, kept current by config-sync) with the
repository's own `.github/labels.yaml`. Either file is optional —
whichever exist are merged, and with `delete-other-labels` (default
`true`) any label not present in the union is removed.

| Input                 | Description                                                       |
| --------------------- | ----------------------------------------------------------------- |
| `base-labels-file`    | Shared base labels file. Default: `.github/labels-base.yaml`.     |
| `labels-file`         | Repo-specific labels file. Default: `.github/labels.yaml`.        |
| `delete-other-labels` | Delete labels not present in the config file(s). Default: `true`. |

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
(`pr-labeler.yaml`) and keyword rules (`issue-labeler.yaml`). Issues authored
by `renovate[bot]` are skipped (v3.3.0+): Renovate rewrites its Dependency
Dashboard on nearly every run, and each `issues: edited` event would otherwise
bill a run.

`github/issue-labeler` builds a JavaScript `RegExp` from each rule and ANDs the
rules listed under a label. The synced `issue-labeler.yaml` therefore writes
case-insensitive rules as `'/pattern/i'` (inline `(?i)` flags throw and abort
the run) and keeps one alternation per label.
`tests/issue-labeler-config.py` checks both and runs sample issues through the
rules.

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

config-sync overwrites the synced `pr-labeler.yaml` in every repository, so
its path rules don't assume a layout. `area/apps` matches files under a
conventional source root (`src/`, `app/`, `apps/`, `services/`, `packages/`,
`crates/`, `lib/`, `cmd/`, `pkg/`, `internal/`, `backend/`, `frontend/`),
except docs, scripts, tests and hidden directories at any depth, Markdown and
shell scripts. Docs, config, CI and infrastructure files never get it.
`tests/pr-labeler-config.py` runs changed-file lists from the fleet's layouts
through the rules.

### TODO to Issue (`todo-to-issue.yml`)

Converts `TODO` comments in code to GitHub Issues on push to the default
branch.

**Example caller:**

```yaml
jobs:
  run:
    # Dependency bumps never add TODO comments; skip Renovate's automerge pushes.
    if: github.actor != 'renovate[bot]'
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

### AI commits badge (`actions/ai-commits-badge/`)

Generates compact badges, Shields endpoint JSON, statistics and theme-aware
README cards from complete Git history. Measures recognized AI authors and
co-author trailers, excludes merges and automation bots, and exposes the
percentage and counts as step outputs. Publishing stays with the caller.

See [`actions/ai-commits-badge/README.md`](../actions/ai-commits-badge/README.md)
for attribution caveats, inputs and docs-site or standalone Pages examples.

### Open PR (`actions/open-pr/`)

Opens (or updates) a pull request from the current working tree.
Use it whenever a job has produced changes that should land via PR
review rather than a direct push to a protected branch — signing,
formatting, generated-content updates.

Key properties:

- With `commit-method: api`, commits through the GraphQL
  `createCommitOnBranch` API, so GitHub signs the commit and the PR passes
  a "require signed commits" ruleset. The default, `commit-method: git`,
  keeps the unsigned local commit and force-push. See the action README
  for the API method's limits (no new executable bits, symlinks or very
  large changes).
- Uses only the preinstalled `git`, `jq` and `gh`; no third-party action.
- Default `GITHUB_TOKEN` does not retrigger workflows on the bot's
  commit, so it is safe inside loops like sign-on-push.
- Reuses the existing PR (replaces its branch with the new commit) when
  one already exists for the same `branch -> base` pair, so repeat runs
  do not spam duplicate PRs.
- Leases every branch update against the tip it read, so a concurrent
  push is never overwritten and an existing working branch (an open PR,
  or a branch left behind after merge) is updated instead of rejected as
  "stale info" (fixed in v3.3.0). When the branch already holds the same
  changes on the same base, nothing is written so the PR's CI does not
  re-run.
- Branch protection on the base branch stays fully enforced.

| Input            | Required | Default                     | Description                                                          |
| ---------------- | -------- | --------------------------- | -------------------------------------------------------------------- |
| `branch`         | yes      | —                           | Working branch to create or replace.                                 |
| `title`          | yes      | —                           | PR title (also default commit message). Conventional Commit subject. |
| `base`           | no       | `main`                      | Branch to merge into.                                                |
| `body`           | no       | `""`                        | PR body (Markdown).                                                  |
| `commit-message` | no       | `title`                     | Override the commit message.                                         |
| `paths`          | no       | `.`                         | Newline-delimited pathspecs to `git add`.                            |
| `labels`         | no       | `""`                        | Newline-delimited labels.                                            |
| `draft`          | no       | `false`                     | Open as draft.                                                       |
| `signoff`        | no       | `false`                     | Add `Signed-off-by` trailer.                                         |
| `commit-method`  | no       | `git`                       | `git` = unsigned local commit and push; `api` = signed API commit.   |
| `if-no-changes`  | no       | `skip`                      | `skip` = exit 0; `fail` = error when nothing to commit.              |
| `git-user-name`  | no       | `github-actions[bot]`       | Author name for `commit-method: git`, and the sign-off.              |
| `git-user-email` | no       | github-actions[bot] noreply | Author email for `commit-method: git`, and the sign-off.             |
| `github-token`   | no       | `${{ github.token }}`       | Token for the commit and `gh`. Use an App token to retrigger CI.     |

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
| `release-please.yml`             | App-authenticated release PRs and tags |
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

| File                                                           | Purpose                                               |
| -------------------------------------------------------------- | ----------------------------------------------------- |
| `.editorconfig`                                                | Editor formatting defaults                            |
| `.github/CODEOWNERS`                                           | Canonical CODEOWNERS (default `@DevSecNinja`)         |
| `.github/instructions/devsecninja-conventions.instructions.md` | Org engineering conventions for AI agents (generated) |
| `.github/instructions/untrusted-repositories.instructions.md`  | When agents may execute code (generated)              |
| `.github/instructions/writing-style.instructions.md`           | Writing style for agent-written prose (generated)     |
| `.github/labels-base.yaml`                                     | Base label set synced to all repos                    |
| `.gitleaks.toml`                                               | Gitleaks default rules plus a global allow-list       |
| `.markdownlint.yaml`                                           | Markdown lint rules                                   |
| `.shellcheckrc`                                                | ShellCheck configuration                              |
| `.yamlfmt.yaml`                                                | yamlfmt formatting rules                              |
| `.yamllint.yaml`                                               | yamllint rules                                        |
| `dprint.json`                                                  | dprint Markdown formatter config                      |
| `issue-labeler.yaml`                                           | Issue auto-label rules                                |
| `pr-labeler.yaml`                                              | PR auto-label rules                                   |

### Org-wide AI instructions (ai-toolkit)

The Copilot instructions that every repository should carry come from
[`DevSecNinja/ai-toolkit`](https://github.com/DevSecNinja/ai-toolkit), which
stays the single source of truth. Config-sync delivers them to the repos that
don't install ai-toolkit themselves:

1. This repository installs the ai-toolkit instructions through APM, each
   pinned by subpath in `apm.yml`. `apm install` materializes them into
   `.github/instructions/`.
2. [`config-sync/sync-ai-toolkit-instructions.sh`](../config-sync/sync-ai-toolkit-instructions.sh)
   copies the org-wide ones to `config-sync/files/.github/instructions/` and
   adds a provenance marker after the front matter. The
   [APM Materialize](../.github/workflows/apm-materialize.yml) workflow runs it
   after every `apm install`, so a Renovate bump of ai-toolkit produces one
   materialize PR that updates both. `mise run test` fails when the copies are
   stale.
3. Config-sync writes them to `<repo>/.github/instructions/` in every caller.

| Instruction               | Why                                                                              |
| ------------------------- | -------------------------------------------------------------------------------- |
| `devsecninja-conventions` | Org engineering rules: PR titles, an issue per PR, reviewable PRs, pre-PR checks |
| `untrusted-repositories`  | When agents may execute repository code; `devsecninja-conventions` requires it   |
| `writing-style`           | How agents write docs, commit messages and PR descriptions                       |

To change which instructions are synced, edit the list at the top of the
script and run it.

**Provenance marker.** Each synced copy carries one line that names the
ai-toolkit release it came from, so drift checks (such as
DevSecNinja/repo-steward#29) can compare a repo's copy with the current one
without parsing the body:

```markdown
<!-- config-sync: source=DevSecNinja/ai-toolkit ref=v0.9.1 commit=446c325d… path=.github/instructions/devsecninja-conventions.instructions.md; generated by DevSecNinja/.github, do not edit (change ai-toolkit instead) -->
```

**Repos that install ai-toolkit through APM** keep APM as the only writer.
A repo that installs the whole package (for example `az-vm-start-stop`) gets
none of these copies, even for instructions its pinned release doesn't ship
yet. A repo that pins primitives by subpath, as `DevSecNinja/.github` does,
keeps the instructions it pins and still receives the others from
config-sync. `DevSecNinja/ai-toolkit` itself is skipped. Two cases need a
manual step:

- A caller pinned to a config-sync release from before this skip would still
  sync the files. Add the paths to its `.github/.config-sync-ignore`, or bump
  the pin.
- A repo that already has synced copies and then pins them through APM:
  delete them before `apm install`, otherwise APM keeps them as locally-authored files
  and skips its own deploy.

### Templates (`config-sync/templates/`)

These are **starting-point** files. Config-sync copies them only when the
caller sets `sync-templates: true` and the file does not exist yet; it never
overwrites them. `renovate.json5` is always bootstrapped: it is a stub that
extends [`.renovate/default.json5`](#consuming-the-preset) and holds the
repository's own Renovate rules. `.gitattributes` is always bootstrapped too:
it makes LF the line ending of every text file, and each sync warns when an
existing `.gitattributes` has no LF default. See
[`config-sync/templates/README.md`](../config-sync/templates/README.md) for
details.

---

## Renovate configuration

The `.renovate/` directory contains shared Renovate preset fragments imported
by individual repositories via their `renovate.json5`.

| Preset                    | Purpose                                                            |
| ------------------------- | ------------------------------------------------------------------ |
| `default.json5`           | Org defaults: `config:recommended` plus every non-opt-in preset    |
| `base.json5`              | Core scheduling, rebase and PR settings                            |
| `autoMerge.json5`         | Auto-merge rules for non-major updates                             |
| `groups.json5`            | Dependency grouping, including the weekly all-non-major batch      |
| `labels.json5`            | Label assignment for Renovate PRs                                  |
| `packageRules.json5`      | Per-ecosystem rules (and opt-outs from the weekly batch)           |
| `customManagers.json5`    | Custom regex managers (e.g. `mise-version` in workflow files)      |
| `semanticCommits.json5`   | Commit types and scopes for Renovate PRs (see Commit types)        |
| `go.json5`                | **Opt-in.** `go mod tidy` after Go module updates (Go source only) |
| `typescript-eslint.json5` | **Opt-in.** Caps `typescript` to the typescript-eslint peer range  |

### Batching and schedule

To keep Actions minutes down (every Renovate push re-runs the repository's
CI), Renovate batches its work
([ADR 0010](design-decisions/0010-batch-renovate-updates-to-save-actions-minutes.md)):

- **One weekly PR for all non-major updates** — `renovate/all-non-major`
  ("all non-major dependencies"). It overrides the specific groups (go, mise, vite,
  postgres, chezmoi) for non-major updates, which therefore still land
  together; those groups keep their own PR for major updates only.
- **Not batched:** major updates (separate, manual), pins (separate, no soak), dprint plugins (separate, soaked), vulnerability fixes
  (separate, immediate), `docker-gated-` images (separate, so the
  [ADR 0005](design-decisions/0005-pr-age-cooldown-for-untrusted-timestamps.md)
  cooldown keeps working), and the dotfiles devcontainer image (branch
  automerge at any time).
- **Schedule:** one window, Saturday 00:00–07:59 (Europe/Amsterdam), for
  creating branches and PRs. With `updateNotScheduled: true` (Renovate's
  default), open PRs are still rebased and updated outside it, so a PR that
  falls behind or conflicts mid-week is fixed without waiting for Saturday.
  Automerge is not tied to the window — GitHub merges as soon as the
  required checks pass.
- **Lock file maintenance:** monthly, on the first day of the month (its
  branch automerge may complete outside the window).
- **Rebasing:** `rebaseWhen: "auto"` (Renovate's default,
  [ADR 0013](design-decisions/0013-rebase-automerge-branches-when-behind.md)).
  An automerge PR that falls behind `main` — or any PR in a repository that
  requires up-to-date branches — is rebased on Renovate's next run, also
  outside the window (`updateNotScheduled: true`). Only where branches must be up to date (the standard for public
  repositories) is every automerged update guaranteed to be tested against
  the latest `main`; elsewhere GitHub's native automerge can merge a
  behind-base PR before Renovate rebases it. No per-repository override is
  needed. `docker-gated-` PRs keep `rebaseWhen: "conflicted"`, because a
  rebase restarts their cooldown clock; repositories that require
  `pr-cooldown` therefore keep "require branches to be up to date" off for
  now.

### Auto-merge strategy

PRs that Renovate can auto-merge are tagged with the **`merge: auto`** label.
Their titles also carry a trailing **`[automerge]`** suffix (via
`commitMessageSuffix`) so auto-merge PRs are easy to spot at a glance.
Code Owners are not requested as reviewers for routine Renovate PRs. Renovate
can still assign Code Owners if an automerge PR cannot merge cleanly.

**What auto-merges (minor + patch, via GitHub platform automerge):**

| Ecosystem                         | Scope                                       | Condition                       |
| --------------------------------- | ------------------------------------------- | ------------------------------- |
| GitHub Actions                    | `actions/*`, `docker/*`, `github/*`         | All versions                    |
| Docker images                     | All                                         | Current version ≥ 1.0           |
| GitHub releases                   | All                                         | Current version ≥ 1.0           |
| Mise tools                        | All                                         | Current version ≥ 1.0           |
| npm                               | All                                         | Current version ≥ 1.0           |
| pip                               | All                                         | Current version ≥ 1.0           |
| Go modules                        | All                                         | Current version ≥ 1.0           |
| DevSecNinja devcontainer (digest) | `ghcr.io/devsecninja/*`                     | Always (no wait time)           |
| Actions pinned to a branch        | `DevSecNinja/*` with `# main`/`# master`    | Digest, weekly non-major batch  |
| Dotfiles devcontainer image       | `ghcr.io/devsecninja/dotfiles-devcontainer` | Always (branch merge, no tests) |
| Lock file maintenance             | All                                         | Monthly (branch merge, no PR)   |

**What does NOT auto-merge:**

- Major version updates (all ecosystems)
- Pre-1.0 packages (`0.x` — semver minor can introduce breaking changes)
- GitHub Actions from untrusted organisations
- Digest-only updates (disabled for supply-chain safety, except DevSecNinja devcontainer images and actions pinned to a branch)
- Third-party actions pinned to a branch (`# main`): digest updates get their own PR labelled `merge: manual`

### Safety nets

- **14-day `minimumReleaseAge`** on all dependency updates — ensures community
  vetting before adoption.
- **CI must pass** — `platformAutomerge: true` uses GitHub's native
  auto-merge, which respects required status checks.
- **Branch auto-merge exceptions** — `ghcr.io/devsecninja/dotfiles-devcontainer`
  and lock file maintenance updates use branch automerge with `ignoreTests: true`.
  The dotfiles devcontainer rule also sets `schedule: ["at any time"]` so it
  ignores the global schedule and can merge whenever a digest update lands.
- **OSV vulnerability alerts** bypass `minimumReleaseAge` (set to `0`) so
  security fixes merge immediately.
- **Schedule** — Renovate only opens and updates PRs on Saturday mornings,
  except vulnerability fixes and the dotfiles devcontainer image, which can
  land at any time.
- **Digest updates disabled** — prevents merging potentially hijacked tags (except
  DevSecNinja-owned devcontainer images on `ghcr.io/devsecninja/`, which are trusted
  internal images and auto-merge immediately with no wait time). Actions pinned to a
  branch (`uses: owner/repo@<sha> # main`) are the other exception: a branch pin can
  only move by digest, so the digest disable would freeze it. Third-party branch pins
  need owner review.
- **Pins skip the soak** — `pin` and `pinDigest` updates only record the version or
  digest a repository already uses (`v4` → `v4.4.0`, `@main` → `@<sha> # main`),
  so they get `minimumReleaseAge: "0"`, their own PR (`groupName: null`, outside
  the weekly batch) and automerge. Non-Docker-Hub image pins still wait for the
  `pr-cooldown` check (ADR 0005).
- **Abandonment exemptions** — Renovate flags packages without a release for a
  year as abandoned. Known-stable packages that trip this (for example
  `@testing-library/user-event`) are exempted by name in
  `packageRules.json5`, not per repository.
- **npm `engines` are never pinned** — `rangeStrategy: "pin"` applies to
  dependencies, but `engines` declare the supported range (`node: "^24.0.0"`)
  and use `rangeStrategy: "replace"`. The exact Node.js version for
  development and CI is pinned in `.mise.toml`.

### Version annotations

`customManagers.json5` tracks versions that no built-in manager sees, through a
`# renovate:` comment on the line above:

- **Workflows** (`.github/workflows/`, `workflow-templates/`): the next line is
  a `…version:` key. `depName=` is optional for runtime datasources, so
  `# renovate: datasource=python-version` above `python-version: [3.14]`
  tracks Python (a single-element matrix list counts as a scalar). Annotated
  `python-version` values keep their form (`3.14` becomes `3.15`) instead of
  being pinned to a patch.
- **Ansible inventory** (`ansible/inventory/`): any datasource, an optional
  `registryUrl=` and any key, e.g. Debian packages pinned per suite with
  `# renovate: datasource=deb depName=docker-ce registryUrl=https://…`.
- **Shell scripts** (`.sh`, `.bash`, `.zsh`, `.bats`, and their chezmoi
  `.tmpl` copies): the next line is a `NAME=value` assignment, optionally after
  `export`, `local`, `readonly` or `declare`. The annotation can add
  `packageName=`, `versioning=`, `extractVersion=` and `registryUrl=`, in that
  order. Without `versioning=`, the datasource's default versioning applies, so
  `datasource=docker` uses docker versioning and keeps a tag suffix such as
  `-alpine`. For an image value (`"docker.io/library/postgres:18.3-alpine@sha256:…"`)
  only the tag and digest are tracked; the image needs a registry or namespace
  path, so write `docker.io/library/redis:7.4` rather than `redis:7.4`. Other
  values keep a leading Debian epoch (`5:29.6.2-1~…`). Values that aren't plain
  literals (`"${OTHER}"`, backtick substitutions, backslash escapes) are
  skipped. Scripts without one of those extensions are not
  scanned.

All annotation managers accept CRLF line endings as well as LF.

Renovate's first-party presets, extended in `customManagers.json5`, cover three
more shapes in every repository whose `extends` chain reaches that file: the
`default.json5` stub, or a config that lists the individual presets including
`customManagers.json5`. They are:
`customManagers:githubActionsVersions` (`# renovate:` above an upper-case
`<NAME>_VERSION:` key in workflows and `action.yml`),
`customManagers:biomeVersions` (the `$schema` version in `biome.json`) and
`customManagers:makefileVersions` (`# renovate:` above `<NAME>_VERSION ?=` in
Makefiles). Each one acts only on repositories with those files.

### dprint plugins

Renovate has no dprint manager, so `customManagers.json5` tracks the plugin URLs
in `dprint.json` (also `.dprint.json` and `.jsonc`) itself, with
`depType: "dprint-plugin"`:

- `https://plugins.dprint.dev/<name>-<version>.wasm` (official plugins):
  releases of `dprint/dprint-plugin-<name>`, e.g. `markdown-0.21.1.wasm`.
- `https://plugins.dprint.dev/<owner>/<repo>-v<version>.wasm` (third-party
  plugins): releases of `<owner>/<repo>`, e.g. `g-plane/malva-v0.16.0.wasm`.

Process plugins (`….json@<checksum>`) are not tracked. Plugin updates keep the
soak and automerge of other GitHub releases but get their own PR, outside the
weekly batch: a plugin update can change formatting, which fails the repository's
`lint / dprint` check until the Markdown is reformatted with `dprint fmt`. The synced `dprint.json` in
`config-sync/files/` is bumped here, and config-sync then distributes it.

### Commit types

The commit type of a Renovate PR decides whether release-please releases:
it releases only for commits in a visible changelog section, by default
`feat`, `fix`, `perf` and `revert` (`build`, `ci` and `chore` are hidden).
`semanticCommits.json5` sets the type centrally, by dependency type, so
updates that don't change what a repository ships don't release it:

| Type    | Updates                                                                                                                                                                                                                                                         | Releases |
| ------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------- |
| `fix`   | Runtime dependencies, as `config:recommended` types them: npm `dependencies`, gomod and composer `require`, pep621/poetry project dependencies, cargo `dependencies`, maven runtime scopes                                                                       | Yes      |
| `build` | Development and build tooling: `devDependencies`, `packageManager`, pep621/uv/pdm/poetry/cargo dev and build dependency groups, mise/asdf/nvm/pyenv tools, devcontainers, pre-commit hooks, PEP 723 scripts, dprint plugins, and anything in test or tool files | No       |
| `ci`    | GitHub Actions, runners and service containers, and other versions pinned in `.github/workflows/`                                                                                                                                                               | No       |
| `chore` | Everything else (Dockerfiles, compose images, `requirements.txt`, NuGet, lock-file updates and maintenance)                                                                                                                                                     | No       |

Two exceptions, where workflows or actions are the product and consumers only
get a fix through a release, stay `fix`: the `action.yml` dependencies of
`DevSecNinja/.github` and `DevSecNinja/python-bandit-scan`, and this
repository's reusable workflows, workflow templates and `config-sync/` files.
Add a repository to the `matchRepositories` list when it starts publishing an
action. Vulnerability fixes are always `fix`, whatever the dependency.

A grouped PR takes the highest type of its updates
(`chore` < `ci` < `build` < `fix` < `feat`), so the weekly batch releases only
when it contains a runtime update. Don't extend `:semanticCommitTypeAll(…)`
in a repository. Listed before the shared presets it has almost no effect,
because `base.json5`'s `config:best-practices` re-applies the
`config:recommended` rules after it: it only types updates without a package
name, such as lock-file maintenance. Listed after them, it overrides every
dependency, including runtime updates. Keep `build` and `ci` hidden in
`release-please-config.json`, or tooling updates release.
### Consuming the preset

Repositories extend `default.json5`, which pulls in `config:recommended` and
the shared fragments. Config-sync bootstraps this `renovate.json5` stub from
[`config-sync/templates/`](../config-sync/templates/README.md#renovatejson5)
when a repository has none, and never overwrites it afterwards:

```json5
{
  $schema: "https://docs.renovatebot.com/renovate-schema.json",
  extends: ["github>DevSecNinja/.github//.renovate/default.json5"],
  // Repository-specific settings go below.
}
```

Repository-specific `packageRules`, `customManagers` and opt-in presets go
below the `extends` entry in the same file; Renovate reads only one config
file per repository. Each config-sync run warns when `renovate.json5` no longer
extends `default.json5`.

---

## Design decisions

Architecture Decision Records are stored in
[`docs/design-decisions/`](design-decisions/README.md).

| ADR                                                               | Title                                                | Status   |
| ----------------------------------------------------------------- | ---------------------------------------------------- | -------- |
| [0001](design-decisions/0001-reusable-workflow-version-inputs.md) | Reusable workflows must not default package versions | Accepted |

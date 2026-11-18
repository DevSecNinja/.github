# Config Sync — files & templates

The reusable workflow `.github/workflows/config-sync.yml` pulls config
out of this directory tree. **Source layout mirrors target layout**:
a file at `config-sync/files/<path>` is synced to `<repo>/<path>`.

## `config-sync/files/`

Files here are **always** synced (overwriting any local changes) so
that `DevSecNinja/.github` is the single source of truth. Examples:

- `dprint.json` → `<repo>/dprint.json`
- `.editorconfig` → `<repo>/.editorconfig`
- `.github/CODEOWNERS` → `<repo>/.github/CODEOWNERS`
- `.github/labels-base.yaml` → `<repo>/.github/labels-base.yaml`

To opt a single repo out of a specific path, list it in
`.github/.config-sync-ignore` at the repo root. One path per line,
relative to repo root. `#` comments and blank lines are allowed.

```text
# Example .github/.config-sync-ignore
.github/CODEOWNERS
```

The `unmanaged` repo topic remains the all-or-nothing escape hatch
(the calling workflow simply isn't installed in those repos).

Paths that the calling repo deploys through APM (listed under
`deployed_files` in its `apm.lock.yaml`) are skipped automatically, as are
generated files from a package the repo installs whole through APM.

### Generated: ai-toolkit instructions

`files/.github/instructions/*.instructions.md` are not edited by hand.
`config-sync/sync-ai-toolkit-instructions.sh` generates them from the
instructions that APM materializes from `DevSecNinja/ai-toolkit`, and
stamps each one with the ai-toolkit ref and commit. Change the text in
ai-toolkit; see
[Org-wide AI instructions](../../docs/architecture.md#org-wide-ai-instructions-ai-toolkit).

## `config-sync/templates/`

These files are **starting points** for repos that need them.
They are only copied when `sync-templates: true` is set on the caller,
and only if the target path does not already exist — local edits are
never overwritten. `renovate.json5` and `.gitattributes` are the
exceptions to the first rule: they are bootstrapped even without
`sync-templates`.

## .gitattributes

LF line endings for every text file, in the repository and in every
checkout, on every OS: `* text=auto eol=lf`, plus `binary` for common
binary types, LF for shell scripts and CRLF checkouts for `*.bat`/`*.cmd`
(cmd.exe misreads labels in LF batch files). It starts from the shared
`~/.gitattributes` in
[DevSecNinja/dotfiles](https://github.com/DevSecNinja/dotfiles/blob/main/home/dot_gitattributes).

Config-sync creates it when the repo has no `.gitattributes` and never
overwrites it, so the repo owns the file. Give a path that needs CRLF its own
rule at the end, where later lines win:

```gitattributes
# CRLF in the checkout, LF in the repository (e.g. Authenticode-signed scripts).
*.ps1 text eol=crlf
# Stored byte for byte: iCalendar (RFC 5545) requires CRLF.
*.ics -text
```

Each sync run warns when an existing `.gitattributes` has no LF default (the
last `*` line that sets `eol` must set `eol=lf`). A repo that deliberately
uses another default lists `.gitattributes` in `.github/.config-sync-ignore`,
which also skips that warning.

Adding the file doesn't convert files already committed with CRLF; run
`git add --renormalize .` and commit the result.

## renovate.json5

A stub that extends the org defaults in
[`.renovate/default.json5`](../../.renovate/default.json5)
(`config:recommended` plus the DevSecNinja presets). Config-sync creates it
when the repo has no `renovate.json5` and never overwrites it, so the repo's
own Renovate settings live in the same file, below the `extends` entry:

```json5
{
  $schema: "https://docs.renovatebot.com/renovate-schema.json",
  extends: [
    "github>DevSecNinja/.github//.renovate/default.json5",
    // Opt-in presets, e.g. for repos that use typescript-eslint:
    "github>DevSecNinja/.github//.renovate/typescript-eslint.json5",
  ],
  packageRules: [
    {
      description: "Repo-specific rule",
      matchPackageNames: ["example"],
      enabled: false,
    },
  ],
}
```

Rules in this file are applied after the presets, so they can override the
org defaults. Changes to the default extends list land in
`.renovate/default.json5` and reach every repo without a sync PR.

Each sync run warns when `renovate.json5` does not extend
`github>DevSecNinja/.github//.renovate/default.json5`. Renovate reads only
the first config file it finds, so keep all Renovate config in this one file;
a `.github/.config-sync-ignore` entry for it is no longer needed.

## .mise.toml

Repos include only the tools they need. The template has a superset of
common tools. Remove entries you don’t use.

## .lefthook.toml

Hook commands vary by repo. Include only the hooks that match your
repo’s tech stack.

## trivy.yaml

Base Trivy config. Add repo-specific `skip-files` entries as needed.

## ruff.toml

Config for ruff, which the shared Lint workflow runs when the repo has
Python files (`lint-ruff`). It sets a 120-character line length and skips the
same generated and vendored paths as the shared `dprint.json`. Config-sync
doesn't add it to a repo that configures ruff in `.ruff.toml` or in
`[tool.ruff]` of `pyproject.toml`, where `ruff.toml` would take precedence and
replace those settings.

## biome.json

Config for Biome, which the shared Lint workflow runs when the repo has
JavaScript, TypeScript, JSON or CSS files (`lint-biome`). It limits Biome to
those files, leaving Markdown and YAML to dprint and yamlfmt, indents with two
spaces, wraps at 120 columns, enables the recommended lint rules, respects
`.gitignore` and skips the same generated and vendored paths as the shared
`dprint.json`. Biome's other defaults (double quotes, semicolons) apply; change
them in the repo's copy. JSON allows no comments, so this note replaces the
usual template header. Config-sync doesn't add it to a repo that has
`biome.jsonc`. The `customManagers:biomeVersions` Renovate preset, part of the
shared Renovate config, keeps its `$schema` version in step with the pinned
Biome.

## PSScriptAnalyzerSettings.psd1

Settings for PSScriptAnalyzer, which the shared Lint workflow runs when the
repo has `*.ps1`, `*.psm1` or `*.psd1` files (`lint-psscriptanalyzer`, with the
`psscriptanalyzer-version` input). It starts from DevSecNinja/windows-iso-maker's
settings: every default rule plus approved verbs, comment-based help on
exported functions, no aliases, `ShouldProcess` for state changes and syntax
that runs on Windows PowerShell 5.1 and PowerShell 7. It skips the BOM rule
(files are UTF-8 without a BOM) and `PSUseCorrectCasing`, which crashes whole
runs until
[PowerShell/PSScriptAnalyzer#1708](https://github.com/PowerShell/PSScriptAnalyzer/issues/1708)
is fixed.

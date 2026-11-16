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
never overwritten. `renovate.json5` is the exception to the first rule:
it is bootstrapped even without `sync-templates`.

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

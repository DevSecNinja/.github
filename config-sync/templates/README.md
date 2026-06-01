# Config Sync — files & templates

The reusable workflow `.github/workflows/config-sync.yml` pulls config
out of this directory tree. **Source layout mirrors target layout**:
a file at `config-sync/files/<path>` is synced to `<repo>/<path>`.

## `config-sync/files/`

Files here are **always** synced (overwriting any local changes) so
that `DevSecNinja/.github` is the single source of truth. Examples:

- `dprint.json` → `<repo>/dprint.json`
- `renovate.json5` → `<repo>/renovate.json5`
- `.github/CODEOWNERS` → `<repo>/.github/CODEOWNERS`

To opt a single repo out of a specific path, list it in
`.github/.config-sync-ignore` at the repo root. One path per line,
relative to repo root. `#` comments and blank lines are allowed.

```text
# Example .github/.config-sync-ignore
.github/CODEOWNERS
```

The `unmanaged` repo topic remains the all-or-nothing escape hatch
(the calling workflow simply isn't installed in those repos).

## `config-sync/templates/`

These files are **starting points** for repos that need them.
They are only copied when `sync-templates: true` is set on the caller,
and only if the target path does not already exist — local edits are
never overwritten.

## .mise.toml

Repos include only the tools they need. The template has a superset of
common tools. Remove entries you don’t use.

## .lefthook.toml

Hook commands vary by repo. Include only the hooks that match your
repo’s tech stack.

## trivy.yaml

Base Trivy config. Add repo-specific `skip-files` entries as needed.

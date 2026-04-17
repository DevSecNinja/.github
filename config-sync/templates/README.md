# Config Sync Templates

These files are **starting points** for repos that need them.
They are NOT auto-synced — copy and adapt for each repository.

## .mise.toml

Repos include only the tools they need. The template has a superset of
common tools. Remove entries you don’t use.

## .lefthook.toml

Hook commands vary by repo. Include only the hooks that match your
repo’s tech stack.

## trivy.yaml

Base Trivy config. Add repo-specific `skip-files` entries as needed.

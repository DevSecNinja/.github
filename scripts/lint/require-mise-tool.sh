#!/usr/bin/env bash
#
# Fails unless the tool named $1 is pinned in the repository's mise config.
# Used by the linter scripts of .github/workflows/lint.yml.
#
# Lint tool versions are owned by the consuming repo: pinned and
# Renovate-managed in its mise config. Fail early with guidance when
# the tool a linter needs is missing, rather than a cryptic mise error.

set -eo pipefail

tool="$1"
if [ ! -f mise.toml ] && [ ! -f .mise.toml ] && [ ! -f .config/mise/config.toml ] && [ ! -f .config/mise.toml ]; then
    echo "::error::No mise config found. Add a Renovate-managed mise.toml (or .mise.toml) that pins your lint tools."
    exit 1
fi
if ! mise which "${tool}" >/dev/null 2>&1; then
    echo "::error::'${tool}' is not pinned in this repository's mise config. Add it (Renovate-managed), e.g. 'mise use ${tool}@<version>', so this lint job can run it."
    exit 1
fi

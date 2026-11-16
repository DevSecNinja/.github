#!/usr/bin/env bash
#
# Fails validation and shows the drift of the watched paths (job sync of
# .github/workflows/vendored-file-sync.yml, when create-pr is false).
# Env: PATHS.

set -euo pipefail

echo "::error::Vendored files are out of sync. Run the vendored-file refresher and commit the resulting changes."
while IFS= read -r line; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    if [ -n "${trimmed}" ]; then
        git diff -- "${trimmed}" || true
    fi
done <<<"${PATHS}"
exit 1

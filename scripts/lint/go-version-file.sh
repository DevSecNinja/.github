#!/usr/bin/env bash
#
# Checks whether the Go version file exists, so Go linting runs only for Go repositories.
# A step of .github/workflows/lint.yml, run the same way in both lint modes.
# Env: GO_VERSION_FILE; writes exists= to GITHUB_OUTPUT.

set -eo pipefail

if [ -f "${GO_VERSION_FILE}" ]; then
    echo "exists=true" >>"${GITHUB_OUTPUT}"
else
    echo "::notice::${GO_VERSION_FILE} not found; skipping Go linter"
    echo "exists=false" >>"${GITHUB_OUTPUT}"
fi

#!/usr/bin/env bash
#
# Fails a Go repository that didn't pass golangci-lint-version.
# A step of .github/workflows/lint.yml, run the same way in both lint modes.
# Env: GO_VERSION_FILE.

set -eo pipefail

echo "::error::Go linting is required (${GO_VERSION_FILE} found) but no golangci-lint-version input was provided. Pass golangci-lint-version when calling this reusable workflow for Go repositories."
exit 1

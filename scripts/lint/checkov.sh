#!/usr/bin/env bash
#
# Scans infrastructure as code with checkov.
# A step of .github/workflows/lint.yml, run the same way in both lint modes.
# Env: UPLOAD_SARIF: write SARIF for code scanning instead of gating on the exit code.

set -eo pipefail

if [ "${UPLOAD_SARIF}" = "true" ]; then
    mise exec -- checkov -d . --output sarif --output-file-path "${RUNNER_TEMP}" || true
else
    # No GitHub Advanced Security: gate on exit code with console output.
    mise exec -- checkov -d . --compact --quiet
fi

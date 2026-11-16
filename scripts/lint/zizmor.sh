#!/usr/bin/env bash
#
# Audits GitHub Actions workflows with zizmor.
# A step of .github/workflows/lint.yml, run the same way in both lint modes.
# Env: UPLOAD_SARIF: write SARIF for code scanning instead of gating on the exit code.

set -eo pipefail

if [ "${UPLOAD_SARIF}" = "true" ]; then
    mise exec -- zizmor --format sarif . >"${RUNNER_TEMP}/zizmor.sarif"
else
    # No GitHub Advanced Security: gate on exit code with console output.
    mise exec -- zizmor .
fi

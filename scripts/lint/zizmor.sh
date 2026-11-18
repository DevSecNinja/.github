#!/usr/bin/env bash
#
# Audits GitHub Actions workflows with zizmor.
# A step of .github/workflows/lint.yml, run the same way in both lint modes.
# Env: UPLOAD_SARIF: write SARIF for code scanning instead of gating on the exit code.
#
# A repo without a zizmor config of its own gets the shared zizmor.yml next to
# this script. zizmor loads one config only, so a repo config replaces it.

set -eo pipefail

zizmor_args=()
local_config=false
for path in .github/zizmor.yml .github/zizmor.yaml zizmor.yml zizmor.yaml; do
    if [ -f "${path}" ]; then
        local_config=true
        break
    fi
done
if [ "${local_config}" = false ]; then
    zizmor_args+=(--config "$(dirname "${BASH_SOURCE[0]}")/zizmor.yml")
fi

if [ "${UPLOAD_SARIF}" = "true" ]; then
    mise exec -- zizmor "${zizmor_args[@]}" --format sarif . >"${RUNNER_TEMP}/zizmor.sarif"
else
    # No GitHub Advanced Security: gate on exit code with console output.
    mise exec -- zizmor "${zizmor_args[@]}" .
fi

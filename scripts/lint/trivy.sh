#!/usr/bin/env bash
#
# Scans the file system for misconfigurations and secrets with trivy.
# A step of .github/workflows/lint.yml, run the same way in both lint modes.
# Env: CONFIG_DIR (its trivy.yaml), UPLOAD_SARIF: write SARIF for code scanning instead of gating on the exit code.

set -eo pipefail

bash "$(dirname "${BASH_SOURCE[0]}")/require-mise-tool.sh" trivy
trivy_args=()
if [ -n "${CONFIG_DIR}" ] && [ -f "${CONFIG_DIR}/trivy.yaml" ]; then
    trivy_args+=(--config "${CONFIG_DIR}/trivy.yaml")
fi

if [ "${UPLOAD_SARIF}" = "true" ]; then
    mise exec -- trivy fs "${trivy_args[@]}" \
        --scanners misconfig,secret \
        --format sarif \
        --output "${RUNNER_TEMP}/trivy.sarif" . || true
else
    # No GitHub Advanced Security: gate on exit code with console output.
    mise exec -- trivy fs "${trivy_args[@]}" \
        --scanners misconfig,secret \
        --exit-code 1 .
fi

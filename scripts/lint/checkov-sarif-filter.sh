#!/usr/bin/env bash
#
# Drops skipped checks (level none) from checkov's SARIF before the upload.
# A step of .github/workflows/lint.yml, run the same way in both lint modes.

set -eo pipefail

sarif="${RUNNER_TEMP}/results_sarif.sarif"
if [ -f "${sarif}" ]; then
    jq '
    .runs |= [
      .[] | .results |= [
        .[] | select(.level != "none")
      ]
    ]
  ' "${sarif}" >"${sarif}.filtered"
    mv "${sarif}.filtered" "${sarif}"
fi

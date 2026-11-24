#!/usr/bin/env bash
#
# Drops skipped checks from checkov's SARIF before the upload: results at
# level none, and results with a suppression in effect (SARIF `state`
# "accepted", or no state), which checkov writes for an inline
# `# checkov:skip=<id>: <reason>` comment. Code scanning ignores SARIF
# suppressions and would open an alert for a check the repository skipped.
# Suppressions under review or rejected stay, like unsuppressed results.
# A step of .github/workflows/lint.yml, run the same way in both lint modes.

set -eo pipefail

sarif="${RUNNER_TEMP}/results_sarif.sarif"
if [ -f "${sarif}" ]; then
    jq '
    .runs |= [
      .[] | .results |= [
        .[] | select(.level != "none" and
          ([.suppressions[]? | select((.state // "accepted") == "accepted")] | length) == 0)
      ]
    ]
  ' "${sarif}" >"${sarif}.filtered"
    mv "${sarif}.filtered" "${sarif}"
fi

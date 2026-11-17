#!/usr/bin/env bash
#
# Summarises the single-job mode's linter steps and fails on any failure.
# A step of .github/workflows/lint.yml, run the same way in both lint modes.
# Env: STEP_RESULTS (toJSON(steps)), JOB_STATUS (job.status).

set -euo pipefail

{
    echo "### Lint results"
    echo ""
    echo "| Step | Outcome |"
    echo "| ---- | ------- |"
    jq -r 'to_entries[] | "| `\(.key)` | \(.value.outcome) |"' <<<"${STEP_RESULTS}"
} >>"${GITHUB_STEP_SUMMARY}"

# A setup step (validation, checkout, mise install) has no id, so it
# is missing from STEP_RESULTS; when one fails, every linter after it
# is skipped and only the job status tells.
if [ "${JOB_STATUS}" = "failure" ]; then
    echo "::error::A setup step failed before the linters could run; see the job log above."
    exit 1
fi

failed="$(jq -r 'to_entries[] | select(.value.outcome == "failure") | .key' <<<"${STEP_RESULTS}")"
if [ -n "${failed}" ]; then
    while IFS= read -r step; do
        echo "::error::Lint step '${step}' failed; see its log above."
    done <<<"${failed}"
    exit 1
fi

echo "All enabled linters passed."

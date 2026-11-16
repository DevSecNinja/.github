#!/usr/bin/env bash
#
# Fails the single-job mode on an unknown lint-job-mode.
# A step of .github/workflows/lint.yml, run the same way in both lint modes.
# Env: LINT_JOB_MODE.

set -eo pipefail

case "${LINT_JOB_MODE}" in
auto | single) ;;
*)
    echo "::error::lint-job-mode must be one of: auto, single, parallel (got '${LINT_JOB_MODE}')."
    exit 1
    ;;
esac

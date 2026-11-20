#!/usr/bin/env bash
#
# Summarizes JUnit XML test results (actions/test-report, step "Summarize test
# results") by running test_report.py with the action's inputs.

set -euo pipefail

action_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python="$(command -v python3 || command -v python || true)"
if [[ -z "${python}" ]]; then
    echo "::error title=Test report::Python 3.8+ is required on the runner." >&2
    exit 1
fi
"${python}" "${action_dir}/test_report.py" \
    "--paths=${REPORT_PATHS}" \
    "--title=${REPORT_TITLE}" \
    "--max-failures=${REPORT_MAX_FAILURES}" \
    "--if-no-files=${REPORT_IF_NO_FILES}"

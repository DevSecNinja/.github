#!/usr/bin/env bash
#
# Checks the formatting of every shell script with shfmt.
# A step of .github/workflows/lint.yml, run the same way in both lint modes.
# Env: EXCLUDE_PATTERN (lint-shfmt-exclude).

set -eo pipefail

bash "$(dirname "${BASH_SOURCE[0]}")/require-mise-tool.sh" shfmt
if [ -n "${EXCLUDE_PATTERN}" ]; then
    find . -name '*.sh' -not -path "./${EXCLUDE_PATTERN}" -print0 | xargs -0 -r mise exec -- shfmt --diff
else
    find . -name '*.sh' -print0 | xargs -0 -r mise exec -- shfmt --diff
fi

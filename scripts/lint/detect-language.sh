#!/usr/bin/env bash
#
# Checks whether the repository has files of language $1, so its linter (and
# the mise install it needs) runs only for repositories that have them.
# A step of .github/workflows/lint.yml, run the same way in both lint modes.
# Env: STEP_ASIDE_FOR: another kind of language-files.sh, such as eslint; when
# the repository has those files too, the linter steps aside for that tool.
# Writes found= to GITHUB_OUTPUT.

set -eo pipefail

files_sh="$(dirname "${BASH_SOURCE[0]}")/language-files.sh"
if [ -n "${STEP_ASIDE_FOR}" ] && [ -n "$(bash "${files_sh}" "${STEP_ASIDE_FOR}" | head -c 1)" ]; then
    echo "::notice::The repository has ${STEP_ASIDE_FOR} config; skipping the $1 linter"
    echo "found=false" >>"${GITHUB_OUTPUT}"
elif [ -n "$(bash "${files_sh}" "$1" | head -c 1)" ]; then
    echo "found=true" >>"${GITHUB_OUTPUT}"
else
    echo "::notice::No $1 files found; skipping its linter"
    echo "found=false" >>"${GITHUB_OUTPUT}"
fi

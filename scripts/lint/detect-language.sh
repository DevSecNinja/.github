#!/usr/bin/env bash
#
# Checks whether the repository has files of language $1, so its linter (and
# the mise install it needs) runs only for repositories that have them.
# A step of .github/workflows/lint.yml, run the same way in both lint modes.
# Writes found= to GITHUB_OUTPUT.

set -eo pipefail

if [ -n "$(bash "$(dirname "${BASH_SOURCE[0]}")/language-files.sh" "$1" | head -c 1)" ]; then
    echo "found=true" >>"${GITHUB_OUTPUT}"
else
    echo "::notice::No $1 files found; skipping its linter"
    echo "found=false" >>"${GITHUB_OUTPUT}"
fi

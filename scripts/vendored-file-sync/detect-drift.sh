#!/usr/bin/env bash
#
# Reports whether the refresher left changes in the watched paths (job sync of
# .github/workflows/vendored-file-sync.yml).
# Env: PATHS.

set -euo pipefail

pathspecs=()
while IFS= read -r line; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    [ -n "${trimmed}" ] && pathspecs+=("${trimmed}")
done <<<"${PATHS}"

if [ "${#pathspecs[@]}" -eq 0 ]; then
    echo "::error::At least one watched path is required." >&2
    exit 1
fi

git status --short -- "${pathspecs[@]}"
# shellcheck disable=SC2312 # git status just succeeded on the same pathspecs.
if [ -n "$(git status --porcelain -- "${pathspecs[@]}")" ]; then
    echo "changed=true" >>"${GITHUB_OUTPUT}"
else
    echo "changed=false" >>"${GITHUB_OUTPUT}"
fi

#!/usr/bin/env bash
#
# Contract test: the shared presets only relax Renovate's abandonment check
# (abandonments:recommended, 1 year) for named known-stable packages. Every
# rule that sets abandonmentThreshold must be scoped to a datasource and to
# exact package names (no glob, brace, extglob, negation or regex syntax), so an
# entry can never exempt a whole ecosystem.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
    echo "error: $*" >&2
    exit 1
}

command -v pyjson5 >/dev/null 2>&1 || fail "'pyjson5' not found on PATH. Run via 'mise run test'."

found=0
for file in "${repo_root}"/.renovate/*.json5; do
    rules="$(pyjson5 --as-json "${file}" | jq -c '[(.packageRules // [])[] | select(has("abandonmentThreshold"))]')"
    found=$((found + $(jq 'length' <<<"${rules}")))
    bad="$(jq -c '.[]
        | select(
            ((.matchDatasources // []) | length) == 0
            or ((.matchPackageNames // []) | length) == 0
            or any(.matchPackageNames[]; test("[*?!\\[\\]{}()]|^/"))
            or ([keys[] | select(startswith("match"))] - ["matchDatasources", "matchPackageNames"] | length) > 0
            or (.description // "") == "")' <<<"${rules}")"
    [ -z "${bad}" ] ||
        fail "$(basename "${file}"): abandonmentThreshold rules need a description, matchDatasources and exact matchPackageNames only:
${bad}"
done
[ "${found}" -gt 0 ] || fail "no abandonmentThreshold exemptions found in .renovate/"

echo "Renovate abandonment exemptions: OK (${found} scoped rules)"

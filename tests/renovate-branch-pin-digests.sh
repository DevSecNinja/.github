#!/usr/bin/env bash
#
# Contract test: GitHub Actions pinned to a branch (`uses: owner/repo@<sha> #
# main`) can only advance by digest, so the shared presets must not freeze them
# with the global digest disable. Evaluates the preset package rules, in the
# order .renovate/default.json5 extends them, for a few representative
# updates with tests/lib/renovate-effective.jq.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
    echo "error: $*" >&2
    exit 1
}

command -v pyjson5 >/dev/null 2>&1 || fail "'pyjson5' not found on PATH. Run via 'mise run test'."

mapfile -t presets < <(
    pyjson5 --as-json "${repo_root}/.renovate/default.json5" |
        jq -r '.extends[] | select(startswith("github>DevSecNinja/.github//.renovate/")) | ltrimstr("github>DevSecNinja/.github//.renovate/")' |
        tr -d '\r'
)
[ "${#presets[@]}" -gt 0 ] || fail ".renovate/default.json5 extends no .renovate presets"

rules="$(
    for preset in "${presets[@]}"; do
        pyjson5 --as-json "${repo_root}/.renovate/${preset}" | jq '.packageRules // []'
    done | jq -s 'add'
)"

# Prints the effective settings for the update described by $1 (JSON).
effective() {
    jq -c --argjson dep "$1" --argjson base '{}' -f "${repo_root}/tests/lib/renovate-effective.jq" <<<"${rules}"
}

check() {
    local name="$1" dep="$2" expected="$3" result
    result="$(effective "${dep}")"
    jq -e "${expected}" <<<"${result}" >/dev/null || fail "${name}: unexpected effective settings ${result}"
}

action() {
    printf '{"manager":"github-actions","datasource":"github-tags","updateType":"%s","packageName":"%s","currentValue":"%s"}' "$1" "$2" "$3"
}

check "DevSecNinja action pinned to main" "$(action digest DevSecNinja/.github main)" \
    '.enabled == true and .automerge == true and .groupName == "all non-major dependencies" and .minimumReleaseAgeBehaviour == "timestamp-optional"'
check "third-party action pinned to main" "$(action digest hacs/action main)" \
    '.enabled == true and .automerge == false and has("groupName") and .groupName == null and (.labels | index("merge: manual"))'
check "action pinned to master" "$(action digest some/action master)" '.enabled == true'
check "action pinned to a tag" "$(action digest actions/checkout v6.1.0)" '.enabled == false'
check "action version update" "$(action minor actions/checkout v6.1.0)" '.enabled == true and .automerge == true'
check "docker digest" \
    '{"manager":"docker-compose","datasource":"docker","updateType":"digest","packageName":"docker.io/library/redis","currentValue":"7"}' \
    '.enabled == false'

echo "Renovate branch-pinned action digests: OK"

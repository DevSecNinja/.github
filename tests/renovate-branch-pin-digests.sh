#!/usr/bin/env bash
#
# Contract test: GitHub Actions pinned to a branch (`uses: owner/repo@<sha> #
# main`) can only advance by digest, so the shared presets must not freeze them
# with the global digest disable. Evaluates the preset package rules, in the
# order .renovate/default.json5 extends them, for a few representative
# updates. Only the matchers these rules use are modelled; a rule with any
# other matcher is treated as not matching.

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
    jq -c --argjson dep "$1" '
        def pattern_match($value):
            . as $p
            | if startswith("/") then ($value | test($p | ltrimstr("/") | rtrimstr("/")))
              elif endswith("/**") then ($value | ascii_downcase | startswith($p | rtrimstr("**") | ascii_downcase))
              else ($value | ascii_downcase) == ($p | ascii_downcase) end;
        def in_list($key; $value):
            (.[$key] // null) as $list | $list == null or ($list | index($value) != null);
        def names_match($value):
            (.matchPackageNames // null) as $patterns
            | $patterns == null
              or (([$patterns[] | select(startswith("!") | not)] as $pos
                   | ($pos | length) == 0 or any($pos[]; pattern_match($value)))
                  and ([$patterns[] | select(startswith("!")) | ltrimstr("!")] | all(.[]; pattern_match($value) | not)));
        def known: ["matchManagers", "matchUpdateTypes", "matchDatasources", "matchCurrentValue", "matchPackageNames"];
        def matches:
            ([keys[] | select(startswith("match"))] - known | length) == 0
            and in_list("matchManagers"; $dep.manager)
            and in_list("matchUpdateTypes"; $dep.updateType)
            and in_list("matchDatasources"; $dep.datasource)
            and ((.matchCurrentValue // null) as $v | $v == null or ($v | pattern_match($dep.currentValue)))
            and names_match($dep.packageName);
        reduce (.[] | select(matches)) as $r ({enabled: true, labels: []};
            . + ($r | with_entries(select(.key | IN("enabled", "automerge", "groupName", "minimumReleaseAgeBehaviour"))))
            | .labels += ($r.addLabels // []))
    ' <<<"${rules}"
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

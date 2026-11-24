#!/usr/bin/env bash
#
# Contract test: two updates the fleet can't take yet stay held in the shared
# presets. Renovate's apm manager must not pin apm.yml refs to digests (the lock
# can't be refreshed, so every pin PR fails renovate/artifacts), and the
# ubuntu-26.04 runner is held until actionlint knows the label. Other actions
# and runners keep their usual settings. Evaluates the preset package rules, in
# the order .renovate/default.json5 extends them, with
# tests/lib/renovate-effective.jq.

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

check() {
    local name="$1" dep="$2" expected="$3" result
    result="$(jq -c --argjson dep "${dep}" --argjson base '{}' \
        -f "${repo_root}/tests/lib/renovate-effective.jq" <<<"${rules}")"
    jq -e "${expected}" <<<"${result}" >/dev/null || fail "${name}: unexpected effective settings ${result}"
}

dep() {
    printf '{"manager":"%s","datasource":"%s","updateType":"%s","packageName":"%s","currentValue":"%s"}' "$@"
}

check "apm ref update" "$(dep apm github-tags minor DevSecNinja/ai-toolkit/.apm/skills/x v0.9.1)" '.pinDigests == false'
check "apm ref pin" "$(dep apm github-tags pinDigest DevSecNinja/ai-toolkit/.apm/skills/x v0.9.1)" '.pinDigests == false'
check "action keeps digest pins" "$(dep github-actions github-tags minor actions/checkout v6.1.0)" 'has("pinDigests") | not'

hold='.allowedVersions == "!/^26\\./"'
check "ubuntu runner" "$(dep github-actions github-runners major ubuntu 24.04)" "${hold}"
check "windows runner" "$(dep github-actions github-runners major windows 2022)" 'has("allowedVersions") | not'

# The hold must reject 26.x only, so a later runner release is still proposed.
pattern="$(jq -r --argjson dep "$(dep github-actions github-runners major ubuntu 24.04)" --argjson base '{}' \
    -f "${repo_root}/tests/lib/renovate-effective.jq" <<<"${rules}" | jq -r '.allowedVersions | ltrimstr("!/") | rtrimstr("/")')"
for version in 26.04 26.10; do
    jq -en --arg v "${version}" --arg p "${pattern}" '$v | test($p)' >/dev/null || fail "hold lets ${version} through"
done
for version in 24.04 28.04; do
    jq -en --arg v "${version}" --arg p "${pattern}" '$v | test($p) | not' >/dev/null || fail "hold blocks ${version}"
done

echo "Renovate version holds: OK"

#!/usr/bin/env bash
#
# Contract test: lock file maintenance has no release timestamp, so no shared
# preset rule may hold it on a release-age soak. Under Renovate's default
# timestamp-required behaviour a soak keeps the branch's renovate/stability-days
# check pending forever and the monthly lock refresh never merges
# (DevSecNinja/.github#631). Manager-wide soak rules such as the mise one
# match a lock refresh too, because Renovate applies packageRules after the
# lockFileMaintenance block. Real updates keep the soak. Evaluates the preset
# package rules, in the order .renovate/default.json5 extends them, with
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
base_json="$(pyjson5 --as-json "${repo_root}/.renovate/base.json5")"
jq -e '.minimumReleaseAge != null and .minimumReleaseAge != "0"' <<<"${base_json}" >/dev/null ||
    fail "base.json5 no longer sets a release-age soak; this test assumes one"
# A lock refresh starts from the lockFileMaintenance block; real updates from the global soak.
lock_base="$(jq -c '{minimumReleaseAge: .lockFileMaintenance.minimumReleaseAge}' <<<"${base_json}")"
update_base="$(jq -c '{minimumReleaseAge}' <<<"${base_json}")"

check() {
    local name="$1" base="$2" dep="$3" expected="$4" result
    result="$(jq -c --argjson dep "${dep}" --argjson base "${base}" \
        -f "${repo_root}/tests/lib/renovate-effective.jq" <<<"${rules}")"
    jq -e "${expected}" <<<"${result}" >/dev/null || fail "${name}: unexpected effective settings ${result}"
}

dep() {
    printf '{"manager":"%s","datasource":"%s","updateType":"%s","packageName":"%s","currentValue":"%s"}' "$@"
}

no_soak='(.minimumReleaseAge // "0") == "0"'
for manager in mise npm pep621 cargo gomod; do
    check "${manager} lock file maintenance" "${lock_base}" "$(dep "${manager}" "" lockFileMaintenance "" "")" "${no_soak}"
done

# Real updates keep a release-age soak (whatever its length).
soaked='.minimumReleaseAge != null and .minimumReleaseAge != "0"'
check "mise tool minor update" "${update_base}" "$(dep mise github-releases minor jdx/mise 2026.11.1)" "${soaked}"
check "npm patch update" "${update_base}" "$(dep npm npm patch maplibre-gl 6.12.0)" "${soaked}"

echo "Renovate lock file maintenance skips the soak: OK"

#!/usr/bin/env bash
#
# Contract test: pins (`pin`, `pinDigest`) only record the version or digest a
# repository already uses, so the shared presets must not hold them in the
# 14-day release-age soak or in the weekly non-major batch, and they must keep
# automerging (DevSecNinja/funda-scorecard#67). Real updates keep the soak and
# the batch. Evaluates the preset package rules, in the order
# .renovate/default.json5 extends them, with tests/lib/renovate-effective.jq.

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
base="$(pyjson5 --as-json "${repo_root}/.renovate/base.json5" | jq -c '{minimumReleaseAge}')"
jq -e '.minimumReleaseAge != null and .minimumReleaseAge != "0"' <<<"${base}" >/dev/null ||
    fail "base.json5 no longer sets a release-age soak; this test assumes one"

check() {
    local name="$1" dep="$2" expected="$3" result
    result="$(jq -c --argjson dep "${dep}" --argjson base "${base}" \
        -f "${repo_root}/tests/lib/renovate-effective.jq" <<<"${rules}")"
    jq -e "${expected}" <<<"${result}" >/dev/null || fail "${name}: unexpected effective settings ${result}"
}

dep() {
    printf '{"manager":"%s","datasource":"%s","updateType":"%s","packageName":"%s","currentValue":"%s"}' "$@"
}

pinned='.enabled == true and .automerge == true and .minimumReleaseAge == "0" and has("groupName") and .groupName == null
    and ((.labels | index("merge: manual")) | not)'
check "action pin (v4 -> v4.4.0)" "$(dep github-actions github-tags pin actions/checkout v4)" "${pinned}"
check "npm pin (^6.12.0 -> 6.12.0)" "$(dep npm npm pin maplibre-gl ^6.12.0)" "${pinned}"
check "action digest pin" "$(dep github-actions github-tags pinDigest actions/checkout v6.1.0)" "${pinned}"
check "third-party branch pin (@main -> @sha # main)" "$(dep github-actions github-tags pinDigest hacs/action main)" "${pinned}"
check "Docker Hub image digest pin" "$(dep docker-compose docker pinDigest docker.io/library/redis 7)" "${pinned}"
# Images without a trusted timestamp keep the pr-cooldown branch (ADR 0005).
check "ghcr.io image digest pin" "$(dep docker-compose docker pinDigest ghcr.io/home-assistant/home-assistant 2026.11.1)" \
    "${pinned} and .additionalBranchPrefix == \"docker-gated-\""

# Real updates keep the soak and the weekly batch.
check "action minor update" "$(dep github-actions github-tags minor actions/checkout v6.1.0)" \
    '.minimumReleaseAge == "14 days" and .groupName == "all non-major dependencies"'
check "npm patch update" "$(dep npm npm patch maplibre-gl 6.12.0)" \
    '.minimumReleaseAge == "14 days" and .groupName == "all non-major dependencies"'
check "docker minor update" "$(dep docker-compose docker minor docker.io/library/redis 7.4)" '.minimumReleaseAge == "14 days"'
check "third-party branch digest update" "$(dep github-actions github-tags digest hacs/action main)" \
    '.automerge == false and (.labels | index("merge: manual"))'

echo "Renovate pins skip the soak: OK"

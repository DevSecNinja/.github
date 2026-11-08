#!/usr/bin/env bash
#
# Contract test for batching Renovate updates (ADR 0010).
#
# The weekly all-non-major group is only safe because of rule ORDER across the
# preset files: it must override the specific groups (so non-major updates
# land in one PR) and be overridden by rules that need their own branch —
# above all the docker-gated rule, whose pr-cooldown soak (ADR 0005) is keyed
# on the `renovate/docker-gated-` branch prefix. A gated dependency that slips
# into the group would auto-merge with no soak at all.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
renovate_dir="${repo_root}/.renovate"

if ! command -v pyjson5 >/dev/null 2>&1; then
    echo "error: 'pyjson5' not found on PATH. Run via 'mise run test'." >&2
    exit 1
fi

fail() {
    echo "error: $*" >&2
    exit 1
}

to_json() {
    pyjson5 --as-json "$1"
}

# Preset files in the order renovate.json5 extends them; later rules win.
mapfile -t presets < <(
    to_json "${repo_root}/renovate.json5" |
        jq -r '.extends[] | select(startswith("github>DevSecNinja/.github//.renovate/")) | sub("^github>DevSecNinja/.github//.renovate/"; "")'
)
[ "${#presets[@]}" -gt 0 ] || fail "renovate.json5 extends no .renovate presets"

rules_json="$(
    for preset in "${presets[@]}"; do
        to_json "${renovate_dir}/${preset}" | jq --arg file "${preset}" '[(.packageRules // [])[] | . + {_file: $file}]'
    done | jq -s 'add | to_entries | map(.value + {_index: .key})'
)"

group="$(jq -c '[.[] | select(.groupSlug == "all-non-major")]' <<<"${rules_json}")"
[ "$(jq 'length' <<<"${group}")" -eq 1 ] || fail "expected exactly one rule with groupSlug all-non-major"
group_index="$(jq '.[0]._index' <<<"${group}")"

jq -e '.[0].matchUpdateTypes | index("major") | not' <<<"${group}" >/dev/null ||
    fail "the all-non-major group must never match major updates"
jq -e '.[0] | (.matchUpdateTypes | sort) == (["digest", "minor", "patch", "pin", "pinDigest"] | sort)' <<<"${group}" >/dev/null ||
    fail "the all-non-major group must match exactly the non-major update types that autoMerge.json5 automerges"
jq -e '.[0] | keys - ["description", "matchUpdateTypes", "groupName", "groupSlug", "_file", "_index"] | length == 0' \
    <<<"${group}" >/dev/null ||
    fail "the all-non-major group must not be scoped by other matchers or settings"

# Specific groups come first, so the batch rule overrides them for non-majors.
late_groups="$(
    jq -r --argjson g "${group_index}" \
        '.[] | select(._index > $g and has("groupName") and .groupName != null) | "\(._file): \(.description // .groupName)"' \
        <<<"${rules_json}"
)"
[ -z "${late_groups}" ] ||
    fail "rules after the all-non-major group must not set a groupName (it would split the weekly batch):
${late_groups}"

# Rules that need their own branch come after the group and opt out of it.
needs_own_branch="$(
    jq -c --argjson g "${group_index}" \
        '[.[] | select(has("additionalBranchPrefix") or has("schedule") or .automergeType == "branch")
            | {file: ._file, index: ._index, optOut: (has("groupName") and .groupName == null),
               description: (.description // "(no description)")}]' \
        <<<"${rules_json}"
)"
problems="$(
    jq -r --argjson g "${group_index}" \
        '.[] | select(.index < $g or (.optOut | not)) | "\(.file): \(.description[0:120])"' \
        <<<"${needs_own_branch}"
)"
[ -z "${problems}" ] ||
    fail "rules with their own branch prefix, schedule or branch automerge must come after the all-non-major group and set groupName: null:
${problems}"

jq -e --argjson g "${group_index}" \
    'any(.[]; ._index > $g and .additionalBranchPrefix == "docker-gated-" and .groupName == null and .rebaseWhen == "conflicted")' \
    <<<"${rules_json}" >/dev/null ||
    fail "the docker-gated rule must follow the group and keep groupName: null and rebaseWhen: conflicted"

base="$(to_json "${renovate_dir}/base.json5")"
jq -e '.rebaseWhen == "conflicted"' <<<"${base}" >/dev/null || fail "base.json5 must set rebaseWhen: conflicted"
jq -e '.schedule | length == 1' <<<"${base}" >/dev/null || fail "base.json5 must use a single weekly schedule window"
jq -e '.updateNotScheduled == false' <<<"${base}" >/dev/null ||
    fail "base.json5 must set updateNotScheduled: false so open PRs are not pushed outside the window"
jq -e '.lockFileMaintenance.updateNotScheduled == true' <<<"${base}" >/dev/null ||
    fail "lockFileMaintenance must keep updateNotScheduled: true so its branch automerge is not stranded"
jq -e '.lockFileMaintenance.schedule | length > 0' <<<"${base}" >/dev/null ||
    fail "lockFileMaintenance needs its own (monthly) schedule"
jq -e '.vulnerabilityAlerts | has("groupName") and .groupName == null and .schedule == ["at any time"]' \
    <<<"${base}" >/dev/null ||
    fail "vulnerability alerts must stay ungrouped and unscheduled"

echo "✓ Renovate batching: all-non-major group is ordered after specific groups and before every opt-out."

#!/usr/bin/env bash
#
# Tests the scripts .github/workflows/label-sync.yml runs:
# scripts/label-sync/resolve-config-files.sh, which picks the label config
# files that exist (#537), and scripts/label-sync/sync-labels.sh, which syncs
# the labels with them through a stubbed gh.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/scripts/label-sync/resolve-config-files.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

fail() {
    echo "error: $*" >&2
    exit 1
}

# Runs the script in a scratch checkout holding the files in $3...; $1 and $2
# are the base and repository label file inputs. Sets $case_dir.
resolve() {
    local base="$1"
    local labels="$2"
    shift 2
    case_dir="$(mktemp -d "${tmp_dir}/case.XXXXXX")"
    mkdir -p "${case_dir}/repo/.github"
    local file
    for file in "$@"; do
        printf -- '- name: bug\n' >"${case_dir}/repo/${file}"
    done
    (
        cd "${case_dir}/repo"
        BASE_LABELS_FILE="${base}" LABELS_FILE="${labels}" GITHUB_OUTPUT="${case_dir}/output" \
            bash "${script}" >"${case_dir}/stdout" 2>&1
    )
}

expect_output() {
    local expected="$1"
    local actual
    actual="$(cat "${case_dir}/output")"
    [ "${actual}" = "${expected}" ] ||
        fail "unexpected GITHUB_OUTPUT:"$'\n'"${actual}"$'\n'"expected:"$'\n'"${expected}"
}

resolve .github/labels-base.yaml .github/labels.yaml .github/labels-base.yaml .github/labels.yaml ||
    fail "both files present must pass"
expect_output $'config-files<<EOF\n.github/labels-base.yaml\n.github/labels.yaml\nEOF'
grep -Fq "✓ including .github/labels.yaml" "${case_dir}/stdout" || fail "included files must be listed"

resolve .github/labels-base.yaml .github/labels.yaml .github/labels.yaml ||
    fail "a missing base file must be skipped"
expect_output $'config-files<<EOF\n.github/labels.yaml\nEOF'
grep -Fq "⊘ skipping .github/labels-base.yaml (not found)" "${case_dir}/stdout" ||
    fail "skipped files must be listed"

resolve .github/labels-base.yaml "" .github/labels-base.yaml ||
    fail "an empty input must be ignored"
expect_output $'config-files<<EOF\n.github/labels-base.yaml\nEOF'

if resolve .github/labels-base.yaml .github/labels.yaml; then
    fail "no label files must fail"
fi
grep -Fq "::error::No label config files found (looked for '.github/labels-base.yaml' and '.github/labels.yaml')" \
    "${case_dir}/stdout" || fail "no label files must explain which files were looked for"
[ ! -s "${case_dir}/output" ] || fail "no label files must write no output"

echo "✓ label-sync: resolve-config-files.sh merges, skips and fails as before."

sync_script="${repo_root}/scripts/label-sync/sync-labels.sh"

# A gh stub: `label list` prints $GH_LABELS, every other call is appended to
# $GH_CALLS, one line per call with its arguments joined by "|".
stub_bin="${tmp_dir}/bin"
mkdir -p "${stub_bin}"
cat >"${stub_bin}/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1 $2" = "label list" ]; then
    printf '%s\n' "$*" >>"${GH_CALLS}.list"
    printf '%s\n' "${GH_LABELS}"
    exit 0
fi
(
    IFS='|'
    printf '%s\n' "$*"
) >>"${GH_CALLS}"
EOF
chmod +x "${stub_bin}/gh"

# Runs sync-labels.sh with existing labels $1 (JSON), DELETE_OTHER_LABELS=$2
# and the config files $3... (paths relative to $case_dir). Sets $case_dir.
sync() {
    local labels="$1"
    local delete="$2"
    shift 2
    local files
    files="$(printf '%s\n' "$@")"
    (
        cd "${case_dir}"
        PATH="${stub_bin}:${PATH}" GH_LABELS="${labels}" GH_CALLS="${case_dir}/calls" \
            CONFIG_FILES="${files}" DELETE_OTHER_LABELS="${delete}" \
            bash "${sync_script}" >"${case_dir}/stdout" 2>&1
    )
}

new_case() {
    case_dir="$(mktemp -d "${tmp_dir}/sync.XXXXXX")"
    : >"${case_dir}/calls"
}

expect_calls() {
    local expected="$1"
    local actual
    actual="$(sort "${case_dir}/calls")"
    expected="$(printf '%s\n' "${expected}" | sort)"
    [ "${actual}" = "${expected}" ] ||
        fail "unexpected gh calls:"$'\n'"${actual}"$'\n'"expected:"$'\n'"${expected}"$'\n'"$(cat "${case_dir}/stdout")"
}

new_case
cat >"${case_dir}/base.yaml" <<'EOF'
- name: bug
  color: "D73A4A"
  description: Something isn't working
- name: "merge: auto"
  color: "#0075ca"
  description: PR is eligible for automerge
  aliases:
    - automerge
- name: keep
  color: "ededed"
- name: Docs
  color: "0075ca"
- name: overridden
  color: "000000"
EOF
cat >"${case_dir}/labels.yaml" <<'EOF'
- name: overridden
  color: "ffffff"
  description: repo file wins
- name: new label
  color: "123abc"
EOF
existing='[
  {"name": "bug", "color": "d73a4a", "description": "Something is broken"},
  {"name": "automerge", "color": "0075ca", "description": ""},
  {"name": "keep", "color": "ededed", "description": ""},
  {"name": "docs", "color": "0075ca", "description": ""},
  {"name": "overridden", "color": "000000", "description": ""},
  {"name": "stale", "color": "cccccc", "description": ""}
]'
sync "${existing}" true base.yaml labels.yaml || fail "a sync must pass:"$'\n'"$(cat "${case_dir}/stdout")"
expect_calls "label|edit|bug|--name|bug|--color|d73a4a|--description|Something isn't working
label|edit|automerge|--name|merge: auto|--color|0075ca|--description|PR is eligible for automerge
label|edit|docs|--name|Docs|--color|0075ca
label|edit|overridden|--name|overridden|--color|ffffff|--description|repo file wins
label|create|new label|--color|123abc
label|delete|stale|--yes"
grep -Fq "label list --limit 1000 --json name,color,description" "${case_dir}/calls.list" ||
    fail "all labels must be listed, not gh's default page of 30"
grep -Fq "~ rename 'automerge' to 'merge: auto'" "${case_dir}/stdout" || fail "renames must be logged"
grep -Fq -- "- delete 'stale'" "${case_dir}/stdout" || fail "deletes must be logged"

# GitHub keeps colours as typed (ffeC19) and a label without a description in
# the config keeps its own: neither is a change.
new_case
printf -- '- name: bug\n  color: "ffeC19"\n' >"${case_dir}/base.yaml"
sync '[{"name": "bug", "color": "ffeC19", "description": "Kept"}, {"name": "stale", "color": "cccccc"}]' false base.yaml ||
    fail "a sync without deletes must pass"
expect_calls ""
grep -Fq "✓ Labels are in sync." "${case_dir}/stdout" || fail "an unchanged repo must say it is in sync"

new_case
printf -- '- name: merged\n  color: "000000"\n  aliases: [old, older]\n' >"${case_dir}/base.yaml"
sync '[{"name": "Older", "color": "111111"}, {"name": "old", "color": "222222"}]' true base.yaml ||
    fail "an alias sync must pass"
expect_calls "label|edit|Older|--name|merged|--color|000000"
grep -Fq "::warning::Label 'old' is an alias of 'merged', which already exists" "${case_dir}/stdout" ||
    fail "a second alias must be kept with a warning, not deleted"

new_case
printf -- '- name: merged\n  color: "000000"\n  aliases: [old]\n' >"${case_dir}/base.yaml"
sync '[{"name": "merged", "color": "000000", "description": ""}, {"name": "old", "color": "222222"}]' true base.yaml ||
    fail "a label and its alias must sync"
expect_calls ""
grep -Fq "::warning::Label 'old' is an alias of 'merged'" "${case_dir}/stdout" ||
    fail "an alias of an existing label must be kept with a warning"

new_case
printf -- '- name: bug\n  color: 000000\n- name: ok\n  color: "00ff00"\n' >"${case_dir}/base.yaml"
if sync '[{"name": "stale", "color": "cccccc"}]' true base.yaml; then
    fail "an unquoted numeric colour must fail"
fi
grep -Fq "::error::Labels need a name, a six-digit hex colour" "${case_dir}/stdout" ||
    fail "an invalid label must be explained"
expect_calls ""
[ ! -e "${case_dir}/calls.list" ] || fail "an invalid config must fail before reading labels"

new_case
printf -- '- name: merged\n  color: "000000"\n  aliases: old\n' >"${case_dir}/base.yaml"
if sync '[{"name": "old", "color": "cccccc"}]' true base.yaml; then
    fail "aliases that aren't a list must fail"
fi
expect_calls ""

# An empty or non-list file must not read as "no labels" and delete them all.
for content in '' 'null' 'name: bug'; do
    new_case
    printf '%s\n' "${content}" >"${case_dir}/base.yaml"
    if sync '[{"name": "bug", "color": "d73a4a"}]' true base.yaml; then
        fail "a config file holding '${content}' must fail"
    fi
    grep -Fq "::error file=base.yaml::A label config file must be a YAML list of labels" "${case_dir}/stdout" ||
        fail "a non-list config file must be explained"
    expect_calls ""
done

new_case
printf -- '- name: bug\n  color: "000000"\n' >"${case_dir}/base.yaml"
printf -- '[]\n' >"${case_dir}/labels.yaml"
sync '[{"name": "bug", "color": "000000"}]' true base.yaml labels.yaml || fail "an explicit empty list must pass"
expect_calls ""

# Names match case-insensitively beyond ASCII, as GitHub does.
new_case
printf -- '- name: équipe\n  color: "000000"\n' >"${case_dir}/base.yaml"
sync '[{"name": "Équipe", "color": "000000", "description": ""}]' true base.yaml ||
    fail "a non-ASCII case-only rename must pass"
expect_calls "label|edit|Équipe|--name|équipe|--color|000000"

# A label that is configured itself is never taken as another label's alias.
new_case
printf -- '- name: new\n  color: "000000"\n  aliases: [old]\n- name: old\n  color: "111111"\n' >"${case_dir}/base.yaml"
sync '[{"name": "old", "color": "111111", "description": ""}]' true base.yaml ||
    fail "an alias that is configured itself must sync"
expect_calls "label|create|new|--color|000000"

echo "✓ label-sync: sync-labels.sh creates, edits, renames aliases and deletes labels."

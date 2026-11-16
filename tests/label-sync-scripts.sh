#!/usr/bin/env bash
#
# Tests scripts/label-sync/resolve-config-files.sh, which
# .github/workflows/label-sync.yml runs to pick the label config files that
# exist (#537).

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

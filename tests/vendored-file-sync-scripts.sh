#!/usr/bin/env bash
#
# Tests the drift scripts that .github/workflows/vendored-file-sync.yml runs
# (#537). scripts/vendored-file-sync/fetch-working-branch.sh is covered by
# tests/open-pr-push.sh.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scripts="${repo_root}/scripts/vendored-file-sync"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

fail() {
    echo "error: $*" >&2
    exit 1
}

repo="${tmp_dir}/repo"
git init --quiet "${repo}"
mkdir -p "${repo}/vendor" "${repo}/other"
echo "v1" >"${repo}/vendor/lib.txt"
echo "v1" >"${repo}/other/file.txt"
git -C "${repo}" add .
git -C "${repo}" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit --quiet -m init

# Runs scripts/vendored-file-sync/$1 in the scratch repository with PATHS=$2.
run() {
    rm -f "${tmp_dir}/output"
    touch "${tmp_dir}/output"
    (cd "${repo}" && PATHS="$2" GITHUB_OUTPUT="${tmp_dir}/output" bash "${scripts}/$1" >"${tmp_dir}/log" 2>&1)
}

# detect-drift.sh
run detect-drift.sh $'vendor/\n' || fail "a clean tree must not fail: $(cat "${tmp_dir}/log")"
[ "$(cat "${tmp_dir}/output")" = "changed=false" ] || fail "a clean tree must report changed=false"

echo "v2" >"${repo}/other/file.txt"
run detect-drift.sh "vendor/" || fail "drift outside the watched paths must not fail"
[ "$(cat "${tmp_dir}/output")" = "changed=false" ] || fail "drift outside the watched paths must not count"

echo "v2" >"${repo}/vendor/lib.txt"
run detect-drift.sh $'  \n  vendor/  \n' ||
    fail "drift in a watched path must not fail: $(cat "${tmp_dir}/log")"
[ "$(cat "${tmp_dir}/output")" = "changed=true" ] || fail "drift in a trimmed watched path must report changed=true"
grep -Fq "vendor/lib.txt" "${tmp_dir}/log" || fail "the drifted files must be listed"

if run detect-drift.sh $' \n\t\n'; then
    fail "no watched paths must fail"
fi
grep -Fq "::error::At least one watched path is required." "${tmp_dir}/log" || fail "no watched paths must explain why"
[ ! -s "${tmp_dir}/output" ] || fail "no watched paths must write no output"

# report-drift.sh always fails and shows the diff of every watched path.
if run report-drift.sh $'vendor/\n  missing/  \n'; then
    fail "report-drift.sh must fail validation"
fi
grep -Fq "::error::Vendored files are out of sync." "${tmp_dir}/log" || fail "the drift error is missing"
grep -Fq "+v2" "${tmp_dir}/log" || fail "the drift diff is missing"
grep -Fq "other/file.txt" "${tmp_dir}/log" && fail "paths that are not watched must not be shown"

echo "✓ vendored-file-sync: detect-drift.sh and report-drift.sh behave as before."

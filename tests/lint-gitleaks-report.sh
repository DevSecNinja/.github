#!/usr/bin/env bash
#
# Tests the gitleaks steps of .github/workflows/lint.yml (#501, #520).
#
# "Run gitleaks" scans only a pull request's own commits on PRs, and the full
# history on other events, reporting only. "Report gitleaks findings" turns PR
# findings (and full-history findings of private repositories) into one
# annotation per finding plus a step-summary table. Full-history findings of
# public repositories go only to a SARIF file for code scanning: the public
# log shows a count.
#
# Both scripts are extracted from the parallel `gitleaks` job (the contract test
# keeps the single-job copies identical) and run against scratch repositories
# holding obviously fake GitHub tokens. The tokens are generated at test time
# so no committed fixture trips the repository's own secret scan.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="${repo_root}/.github/workflows/lint.yml"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

fail() {
    echo "error: $*" >&2
    exit 1
}

command -v gitleaks >/dev/null 2>&1 || fail "gitleaks is not installed; run 'mise install'"
command -v jq >/dev/null 2>&1 || fail "jq is not installed"

# Body of the `run: |-` block of step $1 in the `gitleaks` job, dedented.
extract_run() {
    awk -v step="$1" '
        /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { in_job = ($0 == "  gitleaks:"); next }
        in_job && /^      - / { if (in_run) exit; in_step = ($0 == "      - name: " step); next }
        in_job && in_step && /^        run: \|-$/ { in_run = 1; next }
        in_run {
            if ($0 !~ /^          / && $0 !~ /^[[:space:]]*$/) exit
            sub(/^          /, "")
            print
        }
    ' "${workflow}"
}

run_script="$(extract_run "Run gitleaks")"
report_script="$(extract_run "Report gitleaks findings")"
grep -Fq -- '--redact' <<<"${run_script}" || fail "'Run gitleaks' must keep --redact"
[ -n "${report_script}" ] || fail "the gitleaks job has no 'Report gitleaks findings' step"

# Stand-ins for mise (`mise which`, `mise exec --`) and for the visibility
# lookup `gh api repos/<repo> --jq .visibility`, answered from $FAKE_VISIBILITY.
mkdir -p "${tmp_dir}/bin"
cat >"${tmp_dir}/bin/mise" <<'EOF'
#!/usr/bin/env bash
case "$1" in
which) command -v "$2" ;;
exec) shift 2 && exec "$@" ;;
*) exit 2 ;;
esac
EOF
cat >"${tmp_dir}/bin/gh" <<'EOF'
#!/usr/bin/env bash
[ "$1" = api ] && [[ " $* " == *" .visibility "* ]] && [ "${FAKE_VISIBILITY}" != error ] || exit 1
echo "${FAKE_VISIBILITY}"
EOF
chmod +x "${tmp_dir}/bin/mise" "${tmp_dir}/bin/gh"

chars="$(head -c 4096 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9')"
[ "${#chars}" -ge 108 ] || fail "could not generate random fixture data"
old_token="ghp_${chars:0:36}"
new_token="ghp_${chars:36:36}"
odd_token="ghp_${chars:72:36}"

# Creates repository $1 with an "old" commit holding old.txt and a "new" commit
# holding "fake,token.txt", each with a fake token unless $2 is "clean".
make_repo() {
    local repo="${tmp_dir}/$1"
    mkdir -p "${repo}"
    (
        cd "${repo}"
        git init -q
        git config user.name test
        git config user.email test@example.invalid
        git config commit.gpgsign false
        touch mise.toml
        [ "${2:-}" = clean ] || printf 'token = "%s"\n' "${old_token}" >old.txt
        git add -A
        git commit -qm old
        [ "${2:-}" = clean ] || printf 'token = "%s"\n' "${new_token}" >"fake,token.txt"
        echo change >notes.txt
        git add -A
        git commit -qm new
    )
}

# Runs both steps in repository $1. BASE_SHA/HEAD_SHA/BASE_REF (PR mode), FAKE_VISIBILITY,
# UPLOAD_SARIF and CONFIG_DIR are taken from the environment. Sets status (the
# gitleaks step's exit code), out (both steps' output), summary and outputs.
scan() {
    local repo="${tmp_dir}/$1" temp="${tmp_dir}/$1-runner-temp" mode
    mkdir -p "${temp}"
    : >"${tmp_dir}/$1-summary.md"
    : >"${tmp_dir}/$1-output"
    status=0
    (cd "${repo}" && PATH="${tmp_dir}/bin:${PATH}" RUNNER_TEMP="${temp}" GITHUB_OUTPUT="${tmp_dir}/$1-output" \
        GITHUB_REPOSITORY=owner/repo bash -eo pipefail -c "${run_script}") >"${tmp_dir}/$1.out" 2>&1 || status=$?
    mode="$(sed -n 's/^mode=//p' "${tmp_dir}/$1-output")"
    (cd "${repo}" && RUNNER_TEMP="${temp}" GITHUB_STEP_SUMMARY="${tmp_dir}/$1-summary.md" SCAN_MODE="${mode}" \
        FINDINGS_ARTIFACT=gitleaks-findings-42 bash -eo pipefail -c "${report_script}") >>"${tmp_dir}/$1.out" 2>&1 ||
        fail "'Report gitleaks findings' failed on $1: $(cat "${tmp_dir}/$1.out")"
    out="$(cat "${tmp_dir}/$1.out")"
    summary="$(cat "${tmp_dir}/$1-summary.md")"
    outputs="$(cat "${tmp_dir}/$1-output")"
}

# No output, summary or report of scan $1 may contain a raw token.
assert_redacted() {
    local file
    while IFS= read -r -d '' file; do
        if grep -Fq -e "${chars:0:36}" -e "${chars:36:36}" -e "${chars:72:36}" "${file}"; then
            fail "a raw secret leaked into ${file##*/}"
        fi
    done < <(find "${tmp_dir}" -maxdepth 2 \( -path "${tmp_dir}/$1.out" -o -path "${tmp_dir}/$1-*" \) -type f -print0)
}

export UPLOAD_SARIF=true CONFIG_DIR="" FAKE_VISIBILITY=public BASE_SHA="" HEAD_SHA="" BASE_REF=main RUNNER_DEBUG=""

# PR mode: only the PR's own commit is scanned and annotated.
make_repo pr
BASE_SHA="$(git -C "${tmp_dir}/pr" rev-parse HEAD~1)" HEAD_SHA="$(git -C "${tmp_dir}/pr" rev-parse HEAD)" scan pr
[ "${status}" -eq 1 ] || fail "a secret added in the PR must fail it (got ${status}): ${out}"
grep -Fqx mode=pr <<<"${outputs}" || fail "expected mode=pr; got: ${outputs}"
commit="$(git -C "${tmp_dir}/pr" rev-parse --short=7 HEAD)"
annotation="::error file=fake%2Ctoken.txt,line=1,title=gitleaks github-pat::github-pat in commit ${commit} (secret redacted)"
grep -Fqx -- "${annotation}" <<<"${out}" || fail "expected annotation '${annotation}'; got: ${out}"
[ "$(grep -c '^::error file=' <<<"${out}")" -eq 1 ] || fail "only the PR's commit may be annotated; got: ${out}"
if grep -Fq old.txt <<<"${out}${summary}"; then
    fail "a PR run must not report findings from older history; got: ${out}${summary}"
fi
grep -Eq "^\| github-pat \| fake,token\.txt:1 \| ${commit} \| [0-9]{4}-[0-9]{2}-[0-9]{2}T" <<<"${summary}" ||
    fail "the step summary must list rule, file:line, commit and date; got: ${summary}"
# shellcheck disable=SC2016 # literal backticks
grep -Fq '`gitleaks-findings-42` artifact' <<<"${summary}" ||
    fail "the step summary must name the job's findings artifact; got: ${summary}"
assert_redacted pr

# PR mode without new secrets passes, even though the history has one.
BASE_SHA="$(git -C "${tmp_dir}/pr" rev-parse HEAD)" HEAD_SHA="$(git -C "${tmp_dir}/pr" rev-parse HEAD)" scan pr
[ "${status}" -eq 0 ] || fail "a PR without new secrets must pass (got ${status}): ${out}"
if grep -q '^::error' <<<"${out}" || [ -n "${summary}" ]; then
    fail "a PR without new secrets must not annotate; got: ${out}${summary}"
fi

# A PR that merged newer base-branch commits: the event's base SHA is older,
# so only the base branch's current tip keeps those commits out of the scan.
make_repo stale
(
    cd "${tmp_dir}/stale"
    git branch -q pr-old HEAD~1
    git update-ref refs/remotes/origin/main HEAD
    git checkout -q pr-old
    echo pr-change >pr.txt
    git add -A
    git commit -qm pr
    git merge -q --no-edit origin/main
)
BASE_SHA="$(git -C "${tmp_dir}/stale" rev-parse HEAD~1~1)" HEAD_SHA="$(git -C "${tmp_dir}/stale" rev-parse HEAD)" scan stale
[ "${status}" -eq 0 ] || fail "base-branch commits merged into a PR must not fail it (got ${status}): ${out}"
if grep -q '^::error' <<<"${out}" || [ -n "${summary}" ]; then
    fail "base-branch commits merged into a PR must not be annotated; got: ${out}${summary}"
fi

# A PR whose commits aren't checked out (pull_request_target) fails loudly.
BASE_SHA="$(git -C "${tmp_dir}/pr" rev-parse HEAD)" HEAD_SHA=0123456789abcdef0123456789abcdef01234567 scan pr
[ "${status}" -eq 1 ] || fail "a missing PR head commit must fail (got ${status}): ${out}"
grep -Fq "isn't checked out" <<<"${out}" || fail "a missing PR head commit must be explained; got: ${out}"
# Private history: report only, every finding annotated as a warning.
make_repo private
FAKE_VISIBILITY=private scan private
[ "${status}" -eq 0 ] || fail "a history scan must only report (got ${status}): ${out}"
grep -Fqx mode=history-private <<<"${outputs}" || fail "expected mode=history-private; got: ${outputs}"
[ "$(grep -c '^::warning file=' <<<"${out}")" -eq 2 ] || fail "expected two warning annotations; got: ${out}"
grep -Fq '::warning::gitleaks found 2 finding(s) in the git history. See the job summary.' <<<"${out}" ||
    fail "expected a count warning; got: ${out}"
grep -Fq 'finding(s) in the git history' <<<"${summary}" || fail "expected a history summary; got: ${summary}"
[ -s "${tmp_dir}/private-runner-temp/gitleaks-findings.json" ] || fail "private history findings must be uploadable"
assert_redacted private

# Public history (also internal repositories and a failed visibility lookup):
# SARIF and a count only. The
# extra commit holds a path that isn't a valid URI and a path-only finding
# (line 0, a custom rule), which code scanning's upload would log or reject.
make_repo public
(
    cd "${tmp_dir}/public"
    mkdir -p "my dir"
    printf 'token = "%s"\n' "${odd_token}" >"my dir/café [1].txt"
    echo not-a-key >id.fakekey
    git add -A
    git commit -qm odd
)
CONFIG_DIR="${tmp_dir}/public-config"
mkdir -p "${CONFIG_DIR}"
cat >"${CONFIG_DIR}/.gitleaks.toml" <<'EOF'
[extend]
useDefault = true

[[rules]]
id = "fake-key-file"
description = "Fake key file"
path = '''\.fakekey$'''
EOF
for visibility in public internal error; do
    FAKE_VISIBILITY="${visibility}" scan public
    [ "${status}" -eq 0 ] || fail "a history scan must only report (got ${status}): ${out}"
    grep -Fqx mode=history-public <<<"${outputs}" || fail "expected mode=history-public; got: ${outputs}"
    grep -Fqx sarif=true <<<"${outputs}" || fail "expected sarif=true; got: ${outputs}"
    grep -Fqx '::warning::gitleaks found 4 finding(s) in the git history. They are in code scanning (category gitleaks/history), visible only with write access.' <<<"${out}" ||
        fail "expected a count-only warning; got: ${out}"
    unexpected="$(grep -vE '(commits scanned|scanned ~|leaks found)|^::warning::gitleaks found 4 finding' <<<"${out}" || true)"
    [ -z "${unexpected}" ] || fail "the public log may hold only gitleaks totals and the count; got: ${unexpected}"
    for detail in old.txt fake,token github-pat gitleaks-history 'my dir' café id.fakekey "$(git -C "${tmp_dir}/public" rev-parse --short=7 HEAD)" '::error' 'file='; do
        if grep -Fq -- "${detail}" <<<"${out}"; then
            fail "the public log must show a count only, but it contains '${detail}': ${out}"
        fi
    done
    [ -z "${summary}" ] || fail "a public history scan must not write a summary; got: ${summary}"
    [ ! -e "${tmp_dir}/public-runner-temp/gitleaks-findings.json" ] || fail "a public history scan must not upload findings"
    sarif="${tmp_dir}/public-runner-temp/gitleaks-history.sarif"
    [ "$(jq '[.runs[].results[]] | length' "${sarif}")" -eq 4 ] || fail "the SARIF report must hold all four findings"
    # Valid URI references and 1-based regions, so the upload neither logs
    # a path nor rejects the file.
    jq -e '[.runs[].results[].locations[].physicalLocation]
        | all(.artifactLocation.uri | test("^[A-Za-z0-9._~%!$&'"'"'()*+,;=:@/-]+$"))
        and all(.region // {} | [.[] | numbers] | all(. >= 1))' "${sarif}" >/dev/null ||
        fail "the SARIF report must hold valid URIs and regions: $(jq -c '[.runs[].results[].locations]' "${sarif}")"
    assert_redacted public
done
UPLOAD_SARIF=false scan public
grep -Fq 'upload-sarif is off, so they are not published' <<<"${out}" ||
    fail "without SARIF uploads the warning must say the findings are not published; got: ${out}"# Debug logging makes the code scanning upload log paths: skip it.
RUNNER_DEBUG=1 scan public
grep -Fqx sarif=true <<<"${outputs}" && fail "a debug run must skip the code scanning upload"
grep -Fq 'Debug logging is on, so the code scanning upload is skipped' <<<"${out}" ||
    fail "a debug run must say the upload is skipped; got: ${out}"
CONFIG_DIR=""

# A path-only rule reports StartLine 0; annotate the file without a line.
CONFIG_DIR="${tmp_dir}/path-rule-config"
mkdir -p "${CONFIG_DIR}"
cat >"${CONFIG_DIR}/.gitleaks.toml" <<'EOF'
[[rules]]
id = "fake-key-file"
description = "Fake key file"
path = '''notes\.txt$'''
EOF
BASE_SHA="$(git -C "${tmp_dir}/pr" rev-parse HEAD~1)" HEAD_SHA="$(git -C "${tmp_dir}/pr" rev-parse HEAD)" scan pr
commit="$(git -C "${tmp_dir}/pr" rev-parse --short=7 HEAD)"
annotation="::error file=notes.txt,title=gitleaks fake-key-file::fake-key-file in commit ${commit} (secret redacted)"
grep -Fqx -- "${annotation}" <<<"${out}" || fail "expected file-level annotation '${annotation}'; got: ${out}"
grep -Eq "^\| fake-key-file \| notes\.txt \| ${commit} \| " <<<"${summary}" ||
    fail "a path-only finding must list the file without a line; got: ${summary}"
CONFIG_DIR=""

# A clean history passes without any output.
make_repo clean clean
scan clean
[ "${status}" -eq 0 ] || fail "gitleaks must pass a clean repository (got ${status}): ${out}"
if grep -q '^::' <<<"${out}" || [ -n "${summary}" ]; then
    fail "a clean scan must not annotate or write a summary; got: ${out}${summary}"
fi

# A caller may run lint.yml twice in one run (lint-caller.yml runs both modes),
# so each upload needs a job-unique artifact name. Public history goes to code
# scanning under its own category.
artifact_names="$(grep -E '^          name: gitleaks-findings' "${workflow}" | sort -u)"
# shellcheck disable=SC2016 # literal workflow expression
[ "${artifact_names}" = '          name: gitleaks-findings-${{ job.check_run_id }}' ] ||
    fail "the gitleaks-findings artifact name must be unique per job; got: ${artifact_names}"
[ "$(grep -c '^          category: gitleaks/history$' "${workflow}")" -eq 2 ] ||
    fail "both lint modes must upload the history SARIF under category gitleaks/history"

echo "gitleaks report: OK"

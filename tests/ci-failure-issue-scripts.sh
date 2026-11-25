#!/usr/bin/env bash
#
# Tests scripts/ci-failure-issue/sync.sh, which .github/workflows/ci-failure-issue.yml
# runs, through a stubbed gh: a failure opens the issue (and its label) or
# comments on it, a success closes it, and only the issue carrying the
# workflow's marker counts.

# Backticks in the expected issue text are Markdown code spans.
# shellcheck disable=SC2016

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/scripts/ci-failure-issue/sync.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

fail() {
    echo "error: $*" >&2
    exit 1
}

# A gh stub. Reads print $GH_ISSUES (the open issues) and $GH_JOBS (the run's
# jobs); the label lookup succeeds when $GH_LABEL_EXISTS is 1. Every write is
# appended to $GH_CALLS (arguments joined by "|"), followed by the --body-file
# content.
stub_bin="${tmp_dir}/bin"
mkdir -p "${stub_bin}"
cat >"${stub_bin}/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
"api --paginate repos/"*"/issues?"*) printf '%s\n' "${GH_ISSUES}"; exit 0 ;;
"api --paginate repos/"*"/jobs?"*) printf '%s\n' "${GH_JOBS}"; exit 0 ;;
"api repos/"*"/actions/workflows/"*"/runs?"*) printf '%s\n' "${GH_RUNS}"; exit 0 ;;
"api repos/"*"/labels/"*) [ "${GH_LABEL_EXISTS}" = 1 ] || [ -e "${GH_CALLS}.label" ]; exit ;;
"label create"*)
    if [ "${GH_LABEL_RACE:-0}" = 1 ]; then
        : >"${GH_CALLS}.label" # another handler created it first
        exit 1
    fi
    ;;
esac
(
    IFS='|'
    printf '%s\n' "$*"
) >>"${GH_CALLS}"
prev=""
for arg in "$@"; do
    [ "${prev}" = "--body-file" ] && cat "${arg}" >>"${GH_CALLS}"
    prev="${arg}"
done
[ "$1 $2" = "issue create" ] && echo "https://github.com/o/r/issues/9"
exit 0
EOF
chmod +x "${stub_bin}/gh"

JOBS='{"jobs":[{"name":"test","conclusion":"failure","steps":[{"name":"Setup","conclusion":"success"},{"name":"Run tests","conclusion":"failure"}]},{"name":"lint","conclusion":"success","steps":[]}]}'
MARKED='[{"number":4,"body":"<!-- ci-failure workflow=.github/workflows/ci.yml -->\nx"}]'
OTHER='[{"number":5,"body":"<!-- ci-failure workflow=.github/workflows/docs.yml -->"},{"number":6,"pull_request":{},"body":"<!-- ci-failure workflow=.github/workflows/ci.yml -->"}]'
# This run (42) is the workflow's newest decisive run; a cancelled newer one doesn't count.
LATEST='{"workflow_runs":[{"id":44,"conclusion":"cancelled","event":"push"},{"id":42,"conclusion":"failure","event":"push"}]}'
NEWER='{"workflow_runs":[{"id":43,"conclusion":"success","event":"push"},{"id":42,"conclusion":"failure","event":"push"}]}'

# Runs sync.sh with conclusion $1, open issues $2 (JSON), label existence $3
# and the workflow's runs $4 (default: this run is the newest). Sets $case_dir.
run() {
    case_dir="$(mktemp -d "${tmp_dir}/case.XXXXXX")"
    : >"${case_dir}/calls"
    PATH="${stub_bin}:${PATH}" GH_CALLS="${case_dir}/calls" GH_ISSUES="$2" GH_JOBS="${JOBS}" \
        GH_LABEL_EXISTS="$3" GH_RUNS="${4:-${LATEST}}" GH_REPO=o/r LABEL=ci-failure RUN_ID=42 \
        RUN_URL=https://github.com/o/r/actions/runs/42 WORKFLOW_ID=7 \
        CONCLUSION="$1" WORKFLOW_NAME=CI WORKFLOW_PATH=.github/workflows/ci.yml RUN_EVENT=push \
        HEAD_BRANCH=main HEAD_SHA=0123456789abcdef \
        bash "${script}" >"${case_dir}/stdout" 2>&1 || fail "sync.sh failed:"$'\n'"$(cat "${case_dir}/stdout")"
}

has() {
    grep -Fq -- "$1" "${case_dir}/calls" || fail "expected '$1' in gh calls:"$'\n'"$(cat "${case_dir}/calls")"
}

hasnt() {
    ! grep -Fq -- "$1" "${case_dir}/calls" || fail "unexpected '$1' in gh calls:"$'\n'"$(cat "${case_dir}/calls")"
}

run failure '[]' 0
has "label|create|ci-failure"
has "issue|create|--title|CI failure: CI|--label|ci-failure"
has "<!-- ci-failure workflow=.github/workflows/ci.yml -->"
has '- test: step "Run tests"'
has '(push, commit `0123456`) ended with **failure**.'
hasnt "- lint"

run failure "${OTHER}" 1
hasnt "label|create"
has "issue|create"

run timed_out "${MARKED}" 1
has "issue|comment|4|--body-file"
has "ended with **timed_out**"
hasnt "issue|create"

run startup_failure '[]' 1
has "The run failed to start, so no job ran."
hasnt "Failed jobs:"

run success "${MARKED}" 1
has "issue|close|4|--reason|completed|--comment|Recovered: [run 42]"

run success "${OTHER}" 1
[ ! -s "${case_dir}/calls" ] || fail "a success without its issue must write nothing:"$'\n'"$(cat "${case_dir}/calls")"

# A handler that runs after a newer run of the workflow decided does nothing.
run success "${MARKED}" 1 "${NEWER}"
[ ! -s "${case_dir}/calls" ] || fail "a superseded success must not close:"$'\n'"$(cat "${case_dir}/calls")"
grep -Fq "superseded by run 43" "${case_dir}/stdout" || fail "a superseded run must say so"
run failure '[]' 1 "${NEWER}"
[ ! -s "${case_dir}/calls" ] || fail "a superseded failure must not open:"$'\n'"$(cat "${case_dir}/calls")"

# Another handler creating the label first is fine.
GH_LABEL_RACE=1 run failure '[]' 0
has "issue|create"

if PATH="${stub_bin}:${PATH}" GH_REPO=o/r LABEL='Bad Label' RUN_ID=1 RUN_URL=u CONCLUSION=failure \
    WORKFLOW_PATH=x bash "${script}" >/dev/null 2>&1; then
    fail "an invalid label must fail"
fi

echo "✓ ci-failure-issue: sync.sh opens, comments on and closes the workflow's issue."

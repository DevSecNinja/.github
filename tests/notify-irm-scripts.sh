#!/usr/bin/env bash
#
# Tests .github/actions/notify-irm/notify.sh (#537): skips, the alerting and ok
# payloads, and a failed POST. A stand-in for curl records the request.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
action_dir="${repo_root}/.github/actions/notify-irm"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

fail() {
    echo "error: $*" >&2
    exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq is not installed"

# shellcheck disable=SC2016 # Literal text in action.yml.
grep -Fxq '      run: bash "${GITHUB_ACTION_PATH}/notify.sh"' "${action_dir}/action.yml" ||
    fail "${action_dir}/action.yml no longer runs notify.sh; update this test"

# Fake curl: the payload goes to ${case_dir}/payload, the URL to ${case_dir}/url.
mkdir -p "${tmp_dir}/bin"
cat >"${tmp_dir}/bin/curl" <<'EOF'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
    case "$1" in
    --data) printf '%s' "$2" >"${CASE_DIR}/payload" && shift ;;
    --max-time | --request | --header) shift ;;
    -*) ;;
    *) echo "$1" >"${CASE_DIR}/url" ;;
    esac
    shift
done
[ -z "${CURL_FAILS:-}" ] || { echo "curl: (22) 500" >&2; exit 22; }
EOF
chmod +x "${tmp_dir}/bin/curl"

# notify NAME=value...: runs notify.sh in a fresh case directory ($case_dir).
notify() {
    case_dir="$(mktemp -d "${tmp_dir}/case.XXXXXX")"
    env PATH="${tmp_dir}/bin:${PATH}" \
        CASE_DIR="${case_dir}" \
        WEBHOOK_URL="https://irm.example/hook" \
        JOB_FAILED="false" \
        SERVICE="ci" \
        RESOLVE_ON_SUCCESS="true" \
        WORKFLOW_NAME="Lint" \
        RUN_ID="42" \
        REPOSITORY="owner/repo" \
        REF_NAME="main" \
        SHA="0123456789abcdef" \
        ACTOR="octocat" \
        SERVER_URL="https://github.com" \
        "$@" \
        bash "${action_dir}/notify.sh" >"${case_dir}/log" 2>&1
}

# field FILTER: a jq field of the last payload.
field() {
    jq -r "$1" "${case_dir}/payload"
}

notify WEBHOOK_URL= JOB_FAILED=true || fail "an empty webhook URL must be skipped, not fail"
grep -Fq "::warning::GRAFANA_IRM_WEBHOOK_URL is empty" "${case_dir}/log" || fail "an empty webhook URL must warn"
[ -e "${case_dir}/payload" ] && fail "an empty webhook URL must not POST"

notify RESOLVE_ON_SUCCESS=false || fail "a green run without resolve-on-success must be skipped, not fail"
grep -Fq "::notice::All jobs green and resolve-on-success=false" "${case_dir}/log" || fail "the skip must be explained"
[ -e "${case_dir}/payload" ] && fail "a green run without resolve-on-success must not POST"

notify JOB_FAILED=true RESOLVE_ON_SUCCESS=false || fail "the alerting POST failed: $(cat "${case_dir}/log")"
[ "$(cat "${case_dir}/url")" = "https://irm.example/hook" ] || fail "the webhook URL was not called"
[ "$(field .alert_uid)" = "gha-owner/repo-Lint-main" ] || fail "alert_uid must be keyed on repo, workflow and branch only"
[ "$(field '[.state, .severity, .labels.severity] | join(" ")')" = "alerting critical critical" ] ||
    fail "a failed run must alert as critical"
[ "$(field .title)" = "CI failure on main: Lint" ] || fail "unexpected alerting title: $(field .title)"
[ "$(field .message)" = "Workflow 'Lint' failed on main @ 0123456789abcdef (actor: octocat)." ] ||
    fail "unexpected alerting message: $(field .message)"
[ "$(field .link_to_upstream_details)" = "https://github.com/owner/repo/actions/runs/42" ] || fail "the run link is wrong"
[ "$(field '.labels | [.service, .service_name, .source, .repo, .workflow, .branch, .sha, .actor] | join(" ")')" = \
    "ci ci github-actions owner/repo Lint main 0123456 octocat" ] || fail "unexpected labels: $(field .labels)"
grep -Fq "::notice::Posting state=alerting for Lint on main @ 0123456" "${case_dir}/log" || fail "the POST must be announced"

notify SERVICE=web || fail "the ok POST failed: $(cat "${case_dir}/log")"
[ "$(field '[.state, .severity] | join(" ")')" = "ok info" ] || fail "a green run must post state=ok"
[ "$(field .alert_uid)" = "gha-owner/repo-Lint-main" ] || fail "state=ok must reuse the alerting alert_uid"
[ "$(field .title)" = "CI back to green on main: Lint" ] || fail "unexpected ok title: $(field .title)"
[ "$(field '[.labels.service, .labels.service_name] | join(" ")')" = "web web" ] || fail "the service input was not used"

notify JOB_FAILED=true CURL_FAILS=1 && fail "a failed POST must fail the step"

echo "✓ notify-irm: skips, alerting and ok payloads, and a failed POST."

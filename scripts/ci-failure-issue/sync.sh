#!/usr/bin/env bash
#
# Opens, updates or closes the CI failure issue of one workflow, for
# .github/workflows/ci-failure-issue.yml. Inputs (env, all data from the
# workflow_run event): GH_REPO, LABEL, RUN_ID, RUN_URL, CONCLUSION,
# WORKFLOW_NAME, WORKFLOW_PATH, RUN_EVENT, HEAD_BRANCH, HEAD_SHA; GH_TOKEN for
# gh.
#
# The issue is the open issue with label $LABEL whose body holds the marker
# `<!-- ci-failure workflow=$WORKFLOW_PATH -->`; repo-steward finds it the
# same way. A failure opens it (or comments on it), a success closes it.

# Backticks in the issue text are Markdown code spans, not command substitution.
# shellcheck disable=SC2016

set -euo pipefail

: "${GH_REPO:?}" "${RUN_ID:?}" "${RUN_URL:?}" "${CONCLUSION:?}" "${WORKFLOW_PATH:?}"
LABEL="${LABEL:-ci-failure}"
WORKFLOW_NAME="${WORKFLOW_NAME:-${WORKFLOW_PATH}}"

if [[ ! "${LABEL}" =~ ^[a-z0-9-]+$ ]]; then
    echo "::error::label must be lowercase letters, digits and hyphens, got '${LABEL}'"
    exit 1
fi

marker="<!-- ci-failure workflow=${WORKFLOW_PATH} -->"
body_file="$(mktemp)"
trap 'rm -f "${body_file}"' EXIT

# The number of the open issue for this workflow, or nothing. The REST list
# (not search) sees an issue the moment it exists; a missing label lists none.
find_issue() {
    gh api --paginate "repos/${GH_REPO}/issues?labels=${LABEL}&state=open&per_page=100" |
        jq -rs --arg marker "${marker}" \
            '[.[][] | select(.pull_request == null) | select((.body // "") | contains($marker))][0].number // empty'
}

# One bullet per failed job: its name and first failed step.
failed_jobs() {
    gh api --paginate "repos/${GH_REPO}/actions/runs/${RUN_ID}/jobs?filter=latest&per_page=100" |
        jq -rs 'def failed: .conclusion == "failure" or .conclusion == "timed_out";
            .[].jobs[] | select(failed)
            | ([.steps[]? | select(failed) | .name][0]) as $step
            | "- \(.name)" + (if $step then ": step \"\($step)\"" else "" end)'
}

describe_failure() {
    local short_sha="${HEAD_SHA:0:7}"
    printf '[Run %s](%s) on `%s` (%s' "${RUN_ID}" "${RUN_URL}" "${HEAD_BRANCH:-?}" "${RUN_EVENT:-?}"
    if [[ -n "${short_sha}" ]]; then
        printf ', commit `%s`' "${short_sha}"
    fi
    printf ') ended with **%s**.\n\n' "${CONCLUSION}"
    if [[ "${CONCLUSION}" == "startup_failure" ]]; then
        echo "The run failed to start, so no job ran. Open the run for the reason (often an action that isn't allowed or SHA-pinned, or a permission the caller doesn't grant)."
        return
    fi
    local jobs
    jobs="$(failed_jobs)"
    if [[ -n "${jobs}" ]]; then
        echo "Failed jobs:"
        echo
        echo "${jobs}"
    else
        echo "No failed job was found; open the run for details."
    fi
}

ensure_label() {
    if ! gh api "repos/${GH_REPO}/labels/${LABEL}" >/dev/null 2>&1; then
        gh label create "${LABEL}" --color d73a4a \
            --description "A workflow on the default branch is failing" >/dev/null
        echo "Created label ${LABEL}."
    fi
}

issue="$(find_issue)"

case "${CONCLUSION}" in
success)
    if [[ -z "${issue}" ]]; then
        echo "${WORKFLOW_PATH} passed; no open ${LABEL} issue."
        exit 0
    fi
    comment="Recovered: [run ${RUN_ID}](${RUN_URL}) on \`${HEAD_BRANCH:-?}\` passed."
    gh issue close "${issue}" --reason completed --comment "${comment}" >/dev/null
    echo "Closed #${issue}: ${WORKFLOW_PATH} passed."
    ;;
failure | timed_out | startup_failure)
    if [[ -n "${issue}" ]]; then
        {
            echo "Failed again."
            echo
            describe_failure
        } >"${body_file}"
        gh issue comment "${issue}" --body-file "${body_file}" >/dev/null
        echo "Commented on #${issue}: ${WORKFLOW_PATH} failed again."
        exit 0
    fi
    {
        echo "${marker}"
        printf 'The workflow **%s** (`%s`) is failing.\n\n' "${WORKFLOW_NAME}" "${WORKFLOW_PATH}"
        describe_failure
        echo
        echo "This issue gets a comment on every further failure and closes when the workflow passes again."
        echo "Opened by [ci-failure-issue](https://github.com/DevSecNinja/.github/blob/main/.github/workflows/ci-failure-issue.yml)."
    } >"${body_file}"
    ensure_label
    url="$(gh issue create --title "CI failure: ${WORKFLOW_NAME}" --label "${LABEL}" --body-file "${body_file}")"
    echo "Opened ${url}: ${WORKFLOW_PATH} failed."
    ;;
*)
    echo "Nothing to do for conclusion '${CONCLUSION}'."
    ;;
esac

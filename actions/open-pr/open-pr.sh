#!/usr/bin/env bash
#
# Opens a pull request for BRANCH -> BASE, or reuses the open one
# (actions/open-pr, step "Open or reuse pull request"). Missing labels are
# created first; one that can't be created is skipped with a warning. Writes
# created, pr-url and pr-number to GITHUB_OUTPUT.

set -euo pipefail

# Collect labels from newline-delimited input.
labels=()
# shellcheck disable=SC2153 # LABELS comes from the step env.
while IFS= read -r line; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    [ -n "${trimmed}" ] && labels+=("${trimmed}")
done <<<"${LABELS}"

# `gh pr create --label` fails outright on a label the repo doesn't
# have. Create missing labels first (the Pull requests permission is
# enough); drop one that can't be created with a warning rather than
# failing the whole PR. Check each label directly: a listing is paged
# and can miss labels. Re-check after a failed create, which also
# covers another run creating the label first.
label_exists() {
    gh api "repos/{owner}/{repo}/labels/$(jq -rn --arg l "$1" '$l | @uri')" --silent >/dev/null 2>&1
}
label_args=()
add_label_args=()
for label in ${labels[@]+"${labels[@]}"}; do
    if ! label_exists "${label}" &&
        ! gh label create "${label}" >/dev/null 2>&1 &&
        ! label_exists "${label}"; then
        echo "::warning::Label '${label}' does not exist and could not be created; continuing without it."
        continue
    fi
    label_args+=(--label "${label}")
    add_label_args+=(--add-label "${label}")
done

draft_args=()
if [ "${DRAFT}" = "true" ]; then
    draft_args+=(--draft)
fi

# Try to create. If a PR already exists for `head:branch -> base`,
# `gh pr create` exits non-zero — fall back to looking it up.
if gh pr create \
    --base "${BASE}" \
    --head "${BRANCH}" \
    --title "${TITLE}" \
    --body "${BODY}" \
    "${label_args[@]}" \
    "${draft_args[@]}" \
    >/tmp/gh-pr-create.out 2>&1; then
    url=$(tail -n1 /tmp/gh-pr-create.out)
    number=$(gh pr view "${BRANCH}" --json number --jq '.number')
    {
        echo "created=true"
        echo "pr-url=${url}"
        echo "pr-number=${number}"
    } >>"${GITHUB_OUTPUT}"
    echo "Opened PR #${number}: ${url}"
else
    # Surface the original error for debuggability, then try reuse.
    cat /tmp/gh-pr-create.out
    existing=$(gh pr list \
        --base "${BASE}" \
        --head "${BRANCH}" \
        --state open \
        --json number,url \
        --jq '.[0]')
    if [ -z "${existing}" ] || [ "${existing}" = "null" ]; then
        echo "::error::gh pr create failed and no existing open PR found for ${BRANCH} -> ${BASE}." >&2
        exit 1
    fi
    number=$(printf '%s' "${existing}" | jq -r '.number')
    url=$(printf '%s' "${existing}" | jq -r '.url')
    if [ "${#add_label_args[@]}" -gt 0 ] &&
        ! gh pr edit "${number}" "${add_label_args[@]}" >/dev/null; then
        echo "::warning::Could not add labels to existing PR #${number}."
    fi
    {
        echo "created=false"
        echo "pr-url=${url}"
        echo "pr-number=${number}"
    } >>"${GITHUB_OUTPUT}"
    echo "Reused existing PR #${number}: ${url} (its branch holds the new commit)."
fi

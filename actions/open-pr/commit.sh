#!/usr/bin/env bash
#
# Stage the caller's changes and commit them to ${BRANCH} for actions/open-pr.
#
# COMMIT_METHOD=api creates the commit with the GraphQL
# `createCommitOnBranch` mutation. GitHub signs those commits, so the PR passes
# a "require signed commits" rule. The mutation can only append to an existing
# branch, and resetting an open PR's branch to its base could close the PR,
# so the commit is built on a throwaway branch at the base commit and then moved
# to ${BRANCH} with one atomic `updateRefs` call that also deletes the
# throwaway branch. That call is leased on the tip read before the commit, so a
# concurrent push to ${BRANCH} is never overwritten.
#
# COMMIT_METHOD=git (default) keeps the original behaviour: a local commit
# authored as ${GIT_USER_NAME} and a leased force-push. Those commits are
# unsigned.
#
# Inputs (environment): BRANCH, BASE, TITLE, COMMIT_MESSAGE, PATHS, SIGNOFF,
# IF_NO_CHANGES, COMMIT_METHOD, GIT_USER_NAME, GIT_USER_EMAIL, GH_TOKEN and
# GITHUB_OUTPUT. Writes changed=true|false to GITHUB_OUTPUT.

set -euo pipefail

method="${COMMIT_METHOD:-git}"
case "${method}" in
api | git) ;;
*)
    echo "::error::commit-method must be 'api' or 'git', got '${method}'." >&2
    exit 1
    ;;
esac

# GitHub rejects files over 100 MiB, whatever the transport.
max_file_bytes="${OPEN_PR_MAX_FILE_BYTES:-104857600}"
zero_oid="0000000000000000000000000000000000000000"

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    printf '%s' "${value%"${value##*[![:space:]]}"}"
}

# jq on Windows runners ends its output lines with CRLF; a stray CR breaks
# every comparison below. JSON output escapes CRs inside strings, so only line
# endings are dropped.
jq() {
    command jq "$@" | tr -d '\r'
}

if [ "${method}" = "git" ]; then
    git config user.name "${GIT_USER_NAME}"
    git config user.email "${GIT_USER_EMAIL}"
    # Rebuild the working branch from the current commit so each run produces
    # a clean, single-commit PR rather than piling onto a stale branch.
    git checkout -B "${BRANCH}"
fi

# Forward `paths` to `git add` as separate arguments; blank lines are dropped.
add_args=()
while IFS= read -r line; do
    trimmed="$(trim "${line}")"
    [ -n "${trimmed}" ] && add_args+=("${trimmed}")
done <<<"${PATHS:-.}"
if [ "${#add_args[@]}" -eq 0 ]; then
    add_args=(".")
fi
git add -- "${add_args[@]}"

if git diff --cached --quiet; then
    echo "No staged changes for ${BRANCH}."
    echo "changed=false" >>"${GITHUB_OUTPUT}"
    if [ "${IF_NO_CHANGES:-skip}" = "fail" ]; then
        echo "::error::if-no-changes=fail and there is nothing to commit." >&2
        exit 1
    fi
    exit 0
fi

msg="${COMMIT_MESSAGE:-${TITLE}}"

commit_with_git() {
    echo "::warning title=open-pr commit is unsigned::commit-method=git pushes an unsigned commit as ${GIT_USER_NAME}, so a base branch that requires signed commits blocks this PR. Use commit-method: api to get a commit GitHub signs."

    local commit_args=(-m "${msg}")
    if [ "${SIGNOFF:-false}" = "true" ]; then
        commit_args+=(--signoff)
    fi
    git commit "${commit_args[@]}"

    # Lease the push against the branch tip as it is on the remote right now.
    # A bare --force-with-lease compares against the local remote-tracking
    # ref, which a fresh (usually shallow) checkout does not have for this
    # branch, so every push to an existing branch was rejected as "stale
    # info". An empty lease value means "the branch must not exist yet".
    local remote_ref="refs/heads/${BRANCH}" remote_sha
    remote_sha="$(git ls-remote origin "${remote_ref}" | awk -v ref="${remote_ref}" '$2 == ref { print $1 }')" || {
        echo "::error::Could not read ${remote_ref} from origin; refusing to push without a lease." >&2
        exit 1
    }

    # Leave an identical branch alone: same parent and same tree means the open
    # PR already carries exactly these changes, and a no-op force-push would
    # only re-run its CI. Only deepen history when the checkout is already
    # shallow, so a full clone stays complete.
    local fetch_args=(--quiet --no-tags)
    if [ "$(git rev-parse --is-shallow-repository)" = "true" ]; then
        fetch_args+=(--depth=2)
    fi
    if [ -n "${remote_sha}" ] &&
        git fetch "${fetch_args[@]}" origin "${remote_sha}" 2>/dev/null &&
        [ "$(git rev-parse "${remote_sha}^{tree}")" = "$(git rev-parse 'HEAD^{tree}')" ] &&
        [ "$(git rev-parse --verify --quiet "${remote_sha}^")" = "$(git rev-parse 'HEAD^')" ]; then
        echo "${BRANCH} already has these changes on the same base; skipping push."
    else
        git push --force-with-lease="${remote_ref}:${remote_sha}" origin "HEAD:${remote_ref}"
    fi
}

work=""
tmp_ref=""
repo=""

cleanup() {
    if [ -n "${tmp_ref}" ]; then
        gh api -X DELETE "repos/${repo}/git/${tmp_ref}" >/dev/null 2>&1 ||
            echo "::warning::Could not delete the temporary branch ${tmp_ref#refs/heads/}; delete it by hand."
    fi
    if [ -n "${work}" ]; then
        rm -rf "${work}"
    fi
}

# Apply a JSON array of RefUpdate objects atomically.
update_refs() {
    jq -n --arg id "${repo_id}" --argjson updates "$1" '{
        query: "mutation($input: UpdateRefsInput!) { updateRefs(input: $input) { clientMutationId } }",
        variables: { input: { repositoryId: $id, refUpdates: $updates } }
    }' >"${work}/update-refs.json"
    gh api graphql --input "${work}/update-refs.json" >/dev/null
}

# True when the remote tree holds the same blobs at the same paths as the local
# tree. Covers trees that differ only in file modes, which the API can't set.
same_blobs() {
    gh api "repos/${repo}/git/trees/$1?recursive=1" >"${work}/remote-tree.json" 2>/dev/null || return 1
    [ "$(jq -r '.truncated' "${work}/remote-tree.json")" = "false" ] || return 1
    jq -r '.tree[] | select(.type == "blob") | "\(.sha)\t\(.path)"' "${work}/remote-tree.json" |
        LC_ALL=C sort >"${work}/remote-blobs"
    git ls-tree -r -z "${tree}" | tr '\0' '\n' |
        awk -F '\t' '{ split($1, meta, " "); if (meta[2] == "blob") { sub(/^[^\t]*\t/, ""); print meta[3] "\t" $0 } }' |
        LC_ALL=C sort >"${work}/local-blobs"
    cmp -s "${work}/remote-blobs" "${work}/local-blobs"
}

commit_with_api() {
    work="$(mktemp -d)"
    trap cleanup EXIT

    local parent tree
    parent="$(git rev-parse HEAD)"
    tree="$(git write-tree)"

    # Describe the staged changes as createCommitOnBranch file changes. The
    # contents come from the index, which is exactly what `git commit` would
    # record, base64-encoded so binary files survive.
    : >"${work}/additions.jsonl"
    : >"${work}/deletions.jsonl"
    git diff --cached --raw -z --no-renames --no-abbrev HEAD -- >"${work}/diff"
    local meta path old_mode new_mode new_sha status size
    while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
        read -r old_mode new_mode _ new_sha status <<<"${meta#:}"
        case "${status}" in
        D)
            jq -cn --arg path "${path}" '{path: $path}' >>"${work}/deletions.jsonl"
            continue
            ;;
        A | M | T) ;;
        *)
            echo "::error::Unexpected change '${status}' for ${path}." >&2
            exit 1
            ;;
        esac
        case "${new_mode}" in
        100644) ;;
        100755)
            if [ "${old_mode}" != "100755" ]; then
                echo "::warning::${path} is executable, but createCommitOnBranch can't set the executable bit; it is committed as a regular file. Use commit-method: git if the bit matters."
            fi
            ;;
        *)
            echo "::error::${path} has mode ${new_mode} (a symlink or submodule), which createCommitOnBranch can't commit. Use commit-method: git for this change." >&2
            exit 1
            ;;
        esac
        size="$(git cat-file -s "${new_sha}")"
        if [ "${size}" -gt "${max_file_bytes}" ]; then
            echo "::error::${path} is ${size} bytes, over GitHub's ${max_file_bytes}-byte file limit." >&2
            exit 1
        fi
        git cat-file blob "${new_sha}" | base64 | tr -d '\n' >"${work}/contents"
        jq -cn --arg path "${path}" --rawfile contents "${work}/contents" \
            '{path: $path, contents: $contents}' >>"${work}/additions.jsonl"
    done <"${work}/diff"

    local headline="${msg%%$'\n'*}" body=""
    if [[ "${msg}" == *$'\n'* ]]; then
        body="${msg#*$'\n'}"
        body="${body#"${body%%[!$'\n']*}"}"
    fi
    if [ "${SIGNOFF:-false}" = "true" ]; then
        local trailer="Signed-off-by: ${GIT_USER_NAME} <${GIT_USER_EMAIL}>"
        if [ -n "${body}" ]; then
            body="${body}"$'\n\n'"${trailer}"
        else
            body="${trailer}"
        fi
    fi

    # One query for the repository, the working branch tip, and whether the
    # base commit exists on GitHub.
    local state
    # shellcheck disable=SC2016 # GraphQL variables, not shell expansions.
    state="$(gh api graphql \
        -F owner='{owner}' -F name='{repo}' \
        -f ref="refs/heads/${BRANCH}" -f parent="${parent}" \
        -f query='query($owner: String!, $name: String!, $ref: String!, $parent: GitObjectID!) {
          repository(owner: $owner, name: $name) {
            id
            nameWithOwner
            base: object(oid: $parent) { oid }
            ref(qualifiedName: $ref) {
              target { oid ... on Commit { tree { oid } parents(first: 2) { nodes { oid } } } }
            }
          }
        }')"
    repo_id="$(jq -r '.data.repository.id' <<<"${state}")"
    repo="$(jq -r '.data.repository.nameWithOwner' <<<"${state}")"
    if [ "$(jq -r '.data.repository.base.oid // empty' <<<"${state}")" != "${parent}" ]; then
        echo "::error::The checked-out commit ${parent} is not on GitHub (the job made local commits?). commit-method: api can only commit on top of a pushed commit; use commit-method: git." >&2
        exit 1
    fi

    local tip tip_tree tip_parents
    tip="$(jq -r '.data.repository.ref.target.oid // empty' <<<"${state}")"
    if [ -n "${tip}" ]; then
        tip_tree="$(jq -r '.data.repository.ref.target.tree.oid' <<<"${state}")"
        tip_parents="$(jq -r '[.data.repository.ref.target.parents.nodes[].oid] | join(" ")' <<<"${state}")"
        # Leave an identical branch alone, so the PR's CI does not re-run.
        if [ "${tip_parents}" = "${parent}" ] && { [ "${tip_tree}" = "${tree}" ] || same_blobs "${tip_tree}"; }; then
            echo "${BRANCH} already has these changes on the same base; skipping commit."
            return
        fi
    fi

    tmp_ref="refs/heads/open-pr-tmp/${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}-${RANDOM}${RANDOM}"
    update_refs "$(jq -cn --arg name "${tmp_ref}" --arg before "${zero_oid}" --arg after "${parent}" \
        '[{name: $name, beforeOid: $before, afterOid: $after}]')" || {
        tmp_ref=""
        echo "::error::Could not create a temporary branch for the commit." >&2
        exit 1
    }

    # shellcheck disable=SC2016 # GraphQL variables, not shell expansions.
    jq -n \
        --arg repo "${repo}" --arg branch "${tmp_ref#refs/heads/}" --arg expected "${parent}" \
        --arg headline "${headline}" --arg body "${body}" \
        --slurpfile additions "${work}/additions.jsonl" \
        --slurpfile deletions "${work}/deletions.jsonl" '{
            query: "mutation($input: CreateCommitOnBranchInput!) { createCommitOnBranch(input: $input) { commit { oid } } }",
            variables: { input: {
                branch: { repositoryNameWithOwner: $repo, branchName: $branch },
                expectedHeadOid: $expected,
                message: ({ headline: $headline } + (if $body == "" then {} else { body: $body } end)),
                fileChanges: { additions: $additions, deletions: $deletions }
            } }
        }' >"${work}/commit.json"
    local commit
    commit="$(gh api graphql --input "${work}/commit.json" --jq '.data.createCommitOnBranch.commit.oid')" || {
        echo "::error::createCommitOnBranch failed (request body $(wc -c <"${work}/commit.json") bytes). For changes too large for one API request, use commit-method: git." >&2
        exit 1
    }
    [ -n "${commit}" ] || {
        echo "::error::createCommitOnBranch returned no commit." >&2
        exit 1
    }

    # Move the working branch to the new commit and drop the temporary branch
    # in one atomic update, leased on the tip read above (or on the branch not
    # existing yet).
    if ! update_refs "$(jq -cn \
        --arg branch "refs/heads/${BRANCH}" --arg tip "${tip:-${zero_oid}}" --arg commit "${commit}" \
        --arg tmp "${tmp_ref}" --arg zero "${zero_oid}" \
        '[{name: $branch, beforeOid: $tip, afterOid: $commit, force: true},
          {name: $tmp, beforeOid: $commit, afterOid: $zero}]')"; then
        echo "::error::${BRANCH} changed on GitHub while this run was committing; not overwriting it. Re-run the job." >&2
        exit 1
    fi
    tmp_ref=""
    echo "Committed ${commit} to ${BRANCH} through the GitHub API (signed by GitHub)."
}

if [ "${method}" = "git" ]; then
    commit_with_git
else
    commit_with_api
fi

echo "changed=true" >>"${GITHUB_OUTPUT}"

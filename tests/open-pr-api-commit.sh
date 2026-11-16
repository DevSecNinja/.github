#!/usr/bin/env bash
#
# Functional test for actions/open-pr with commit-method: api.
#
# Runs the action's commit script with a fake `gh` that serves the GraphQL and
# REST calls it makes from a local bare repository, mimicking GitHub:
# createCommitOnBranch needs an existing branch and a matching expectedHeadOid,
# keeps the mode of modified files and commits new files as 100644, and
# updateRefs applies leased updates atomically. Behaviour against real GitHub
# (signed commits, ref deletion in updateRefs) was checked by hand; see
# actions/open-pr/README.md.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
action="${repo_root}/actions/open-pr/action.yml"
script="${repo_root}/actions/open-pr/commit.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT
cd "${tmp_dir}"

branch="chore/config-sync"

fail() {
    echo "error: $*" >&2
    exit 1
}

# shellcheck disable=SC2016 # Literal text in action.yml.
grep -Fq 'run: bash "${GITHUB_ACTION_PATH}/commit.sh"' "${action}" ||
    fail "${action} no longer runs commit.sh; update this test"
# shellcheck disable=SC2016 # Literal text in action.yml.
grep -Fq 'COMMIT_METHOD: ${{ inputs.commit-method }}' "${action}" ||
    fail "${action} does not pass commit-method to commit.sh"
awk '/^  commit-method:/ { found = 1 } found && /^    default:/ { print $2; exit }' "${action}" | grep -Fxq git ||
    fail "commit-method must keep defaulting to git; changing it is a breaking change"

export GIT_CONFIG_GLOBAL="${tmp_dir}/gitconfig"
export GIT_CONFIG_NOSYSTEM=1
git config --global init.defaultBranch main
git config --global user.name "test"
git config --global user.email "test@example.com"
git config --global commit.gpgsign false
git config --global protocol.file.allow always

origin="${tmp_dir}/origin.git"
git init --quiet --bare "${origin}"
git -C "${origin}" config core.logAllRefUpdates always
export FAKE_REMOTE="${origin}"
export FAKE_LOG="${tmp_dir}/gh.log"
FAKE_JQ="$(command -v jq)"
export FAKE_JQ

mkdir -p "${tmp_dir}/bin"
cat >"${tmp_dir}/bin/gh" <<'FAKE_GH'
#!/usr/bin/env bash
# Fake gh: serves the calls actions/open-pr/commit.sh makes from ${FAKE_REMOTE}.
set -euo pipefail
printf '%s\n' "$*" >>"${FAKE_LOG}"
zero=0000000000000000000000000000000000000000
g() { git -C "${FAKE_REMOTE}" "$@"; }
jq() { "${FAKE_JQ}" "$@"; }
err() {
    echo "gh: $*" >&2
    exit 1
}
oid_of() { g rev-parse --verify --quiet "$1^{commit}" || true; }

create_commit() {
    local input="$1" ref expected tip index empty tree commit message body i n path mode blob
    [ "$(jq -r '.variables.input.branch.repositoryNameWithOwner' "${input}")" = "owner/repo" ] || err "wrong repository"
    ref="refs/heads/$(jq -r '.variables.input.branch.branchName' "${input}")"
    expected="$(jq -r '.variables.input.expectedHeadOid' "${input}")"
    tip="$(oid_of "${ref}")"
    [ -n "${tip}" ] || err "A ref named \"${ref}\" does not exist."
    [ "${tip}" = "${expected}" ] || err "Expected branch to point to \"${expected}\" but it did not."
    index="$(mktemp -u)"
    empty="$(mktemp -d)"
    export GIT_INDEX_FILE="${index}" GIT_WORK_TREE="${empty}"
    g read-tree "${tip}"
    n="$(jq '.variables.input.fileChanges.additions | length' "${input}")"
    for ((i = 0; i < n; i++)); do
        path="$(jq -r --argjson i "${i}" '.variables.input.fileChanges.additions[$i].path' "${input}")"
        blob="$(jq -r --argjson i "${i}" '.variables.input.fileChanges.additions[$i].contents' "${input}" |
            base64 -d | g hash-object -w --stdin)"
        # Like GitHub: a modified file keeps its mode, a new file is 100644.
        mode="$(g ls-tree "${tip}" -- "${path}" | awk '{ print $1 }')"
        g update-index --add --cacheinfo "${mode:-100644},${blob},${path}"
    done
    n="$(jq '.variables.input.fileChanges.deletions | length' "${input}")"
    for ((i = 0; i < n; i++)); do
        path="$(jq -r --argjson i "${i}" '.variables.input.fileChanges.deletions[$i].path' "${input}")"
        [ -n "$(g ls-tree "${tip}" -- "${path}")" ] || err "deleting missing file ${path}"
        g update-index --force-remove -- "${path}"
    done
    tree="$(g write-tree)"
    message="$(jq -r '.variables.input.message.headline' "${input}")"
    body="$(jq -r '.variables.input.message.body // empty' "${input}")"
    [ -z "${body}" ] || message="${message}"$'\n\n'"${body}"
    commit="$(printf '%s' "${message}" | GIT_AUTHOR_NAME=app GIT_AUTHOR_EMAIL=app@example.com \
        GIT_COMMITTER_NAME=GitHub GIT_COMMITTER_EMAIL=noreply@github.com g commit-tree "${tree}" -p "${tip}")"
    g update-ref "${ref}" "${commit}" "${tip}"
    rm -rf "${index}" "${empty}"
    unset GIT_INDEX_FILE GIT_WORK_TREE
    # Someone pushes to the working branch while the run is committing.
    if [ -n "${FAKE_RACE_REF:-}" ]; then
        g update-ref "${FAKE_RACE_REF}" "${FAKE_RACE_OID}"
    fi
    jq -n --arg oid "${commit}" '{data: {createCommitOnBranch: {commit: {oid: $oid}}}}'
}

update_refs() {
    local input="$1" n i name before after force current
    [ "$(jq -r '.variables.input.repositoryId' "${input}")" = "R_fake" ] || err "wrong repository id"
    n="$(jq '.variables.input.refUpdates | length' "${input}")"
    for ((i = 0; i < n; i++)); do
        IFS=$'\t' read -r name before after force < <(jq -r --argjson i "${i}" \
            '.variables.input.refUpdates[$i] | [.name, (.beforeOid // "-"), .afterOid, (.force // false)] | @tsv' "${input}")
        current="$(oid_of "${name}")"
        current="${current:-${zero}}"
        if [ "${before}" != "-" ] && [ "${before}" != "${current}" ]; then
            err "Something went wrong while executing your query."
        fi
        if [ "${after}" != "${zero}" ] && [ "${current}" != "${zero}" ] && [ "${force}" != "true" ] &&
            ! g merge-base --is-ancestor "${current}" "${after}"; then
            err "non-fast-forward update of ${name}"
        fi
    done
    for ((i = 0; i < n; i++)); do
        IFS=$'\t' read -r name after < <(jq -r --argjson i "${i}" \
            '.variables.input.refUpdates[$i] | [.name, .afterOid] | @tsv' "${input}")
        if [ "${after}" = "${zero}" ]; then
            g update-ref -d "${name}"
        else
            g update-ref "${name}" "${after}"
        fi
    done
    echo '{"data":{"updateRefs":{"clientMutationId":null}}}'
}

state_query() {
    local ref="$1" parent="$2" base=null ref_json=null tip parents
    if g cat-file -e "${parent}^{commit}" 2>/dev/null; then
        base="$(jq -cn --arg oid "${parent}" '{oid: $oid}')"
    fi
    tip="$(oid_of "${ref}")"
    if [ -n "${tip}" ]; then
        parents="$(g rev-list --parents -n 1 "${tip}" | cut -s -d ' ' -f 2- | jq -cR 'split(" ") | map({oid: .})')"
        ref_json="$(jq -cn --arg oid "${tip}" --arg tree "$(g rev-parse "${tip}^{tree}")" --argjson parents "${parents:-[]}" \
            '{target: {oid: $oid, tree: {oid: $tree}, parents: {nodes: $parents}}}')"
    fi
    jq -n --argjson base "${base}" --argjson ref "${ref_json}" \
        '{data: {repository: {id: "R_fake", nameWithOwner: "owner/repo", base: $base, ref: $ref}}}'
}

method=GET
args=()
while [ $# -gt 0 ]; do
    case "$1" in
        -X)
            method="$2"
            shift 2
            ;;
        *)
            args+=("$1")
            shift
            ;;
    esac
done
set -- "${args[@]}"
[ "$1" = "api" ] || err "unexpected command: $*"
shift

if [ "$1" = "graphql" ]; then
    shift
    input="" jq_expr="" owner="" name="" ref="" parent=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --input) input="$2" ;;
            --jq) jq_expr="$2" ;;
            -f | -F)
                case "$2" in
                    owner=*) owner="${2#owner=}" ;;
                    name=*) name="${2#name=}" ;;
                    ref=*) ref="${2#ref=}" ;;
                    parent=*) parent="${2#parent=}" ;;
                esac
                ;;
        esac
        shift 2
    done
    if [ -z "${input}" ]; then
        [ "${owner}" = "{owner}" ] && [ "${name}" = "{repo}" ] || err "repository not taken from the checkout"
        out="$(state_query "${ref}" "${parent}")"
    elif grep -q 'createCommitOnBranch' "${input}"; then
        out="$(create_commit "${input}")"
    elif grep -q 'updateRefs' "${input}"; then
        out="$(update_refs "${input}")"
    else
        err "unexpected mutation"
    fi
    if [ -n "${jq_expr}" ]; then
        jq -r "${jq_expr}" <<<"${out}"
    else
        printf '%s\n' "${out}"
    fi
    exit 0
fi

case "${method} $1" in
    "GET repos/owner/repo/git/trees/"*"?recursive=1")
        sha="${1#repos/owner/repo/git/trees/}"
        sha="${sha%%\?*}"
        g ls-tree -r "${sha}" | jq -R 'capture("^(?<mode>\\S+) (?<type>\\S+) (?<sha>\\S+)\t(?<path>.*)$")' |
            jq -s --arg sha "${sha}" '{sha: $sha, truncated: false, tree: .}'
        ;;
    "DELETE repos/owner/repo/git/refs/heads/"*)
        ref="refs/${1#repos/owner/repo/git/refs/}"
        [ -n "$(oid_of "${ref}")" ] || err "Reference does not exist (HTTP 422)"
        g update-ref -d "${ref}"
        ;;
    *) err "unexpected call: ${method} $*" ;;
esac
FAKE_GH
chmod +x "${tmp_dir}/bin/gh"
export PATH="${tmp_dir}/bin:${PATH}"

seed="${tmp_dir}/seed"
git clone --quiet "file://${origin}" "${seed}" 2>/dev/null
echo "base" >"${seed}/config.txt"
echo "old" >"${seed}/obsolete.txt"
printf '#!/bin/sh\necho old\n' >"${seed}/tool.sh"
chmod +x "${seed}/tool.sh"
git -C "${seed}" add .
git -C "${seed}" update-index --chmod=+x tool.sh
git -C "${seed}" commit --quiet -m "initial"
git -C "${seed}" push --quiet origin HEAD:refs/heads/main

# A fresh shallow checkout of main, as actions/checkout leaves it, plus the
# changes a sync job makes: a modified, an added binary, a new executable, a
# path with a space, a modified executable, and a deleted file.
new_checkout() {
    local dir="$1"
    git init --quiet "${dir}"
    git -C "${dir}" remote add origin "file://${origin}"
    git -C "${dir}" fetch --quiet --no-tags --depth=1 origin "+refs/heads/main:refs/remotes/origin/main"
    git -C "${dir}" checkout --quiet -B main refs/remotes/origin/main
    echo "synced" >"${dir}/config.txt"
    printf 'bin\000ary\377\n' >"${dir}/data.bin"
    mkdir -p "${dir}/dir with space"
    echo "nested" >"${dir}/dir with space/file.txt"
    printf '#!/bin/sh\necho new\n' >"${dir}/new-tool.sh"
    chmod +x "${dir}/new-tool.sh"
    printf '#!/bin/sh\necho updated\n' >"${dir}/tool.sh"
    rm "${dir}/obsolete.txt"
    git -C "${dir}" update-index --add --chmod=+x new-tool.sh
}

run_action() {
    local dir="$1" output="$2"
    shift 2
    (
        cd "${dir}"
        env GITHUB_OUTPUT="${output}" \
            GIT_USER_NAME="github-actions[bot]" \
            GIT_USER_EMAIL="41898282+github-actions[bot]@users.noreply.github.com" \
            BRANCH="${branch}" \
            BASE="main" \
            COMMIT_MESSAGE=$'chore: sync config files\n\nFrom the central repo.' \
            TITLE="chore: sync config files" \
            PATHS="." \
            SIGNOFF="true" \
            IF_NO_CHANGES="skip" \
            COMMIT_METHOD="api" \
            GH_TOKEN="fake" \
            "$@" bash "${script}"
    )
}

remote_tip() {
    git -C "${origin}" rev-parse --verify --quiet "refs/heads/$1" || true
}

no_tmp_refs() {
    [ -z "$(git -C "${origin}" for-each-ref 'refs/heads/open-pr-tmp/')" ] || fail "temporary branch left behind: $1"
}

calls() {
    grep -c -- "$1" "${FAKE_LOG}" || true
}

# 1. A new branch gets one commit on top of main with every change.
work="${tmp_dir}/work"
new_checkout "${work}"
run_action "${work}" "${tmp_dir}/output-1" >"${tmp_dir}/run-1.log" 2>&1 || {
    cat "${tmp_dir}/run-1.log" >&2
    fail "API commit to a new branch failed"
}
grep -Fxq "changed=true" "${tmp_dir}/output-1" || fail "changed=true missing after the first commit"
tip="$(remote_tip "${branch}")"
[ -n "${tip}" ] || fail "branch was not created"
[ "$(git -C "${origin}" rev-parse "${tip}^")" = "$(remote_tip main)" ] || fail "commit must sit directly on main"
[ "$(git -C "${origin}" show "${tip}:config.txt")" = "synced" ] || fail "modified file has the wrong content"
cmp -s <(git -C "${origin}" cat-file blob "${tip}:data.bin") "${work}/data.bin" || fail "binary file was corrupted"
[ "$(git -C "${origin}" show "${tip}:dir with space/file.txt")" = "nested" ] || fail "path with a space was lost"
git -C "${origin}" cat-file -e "${tip}:obsolete.txt" 2>/dev/null && fail "deleted file is still in the commit"
[ "$(git -C "${origin}" ls-tree "${tip}" tool.sh | awk '{ print $1 }')" = "100755" ] ||
    fail "modified executable lost its mode"
grep -Fq "new-tool.sh is executable" "${tmp_dir}/run-1.log" || fail "no warning for the executable bit on a new file"
[ "$(git -C "${origin}" log -1 --format=%B "${tip}")" = "$(printf '%s\n\n%s\n\n%s' "chore: sync config files" \
    "From the central repo." "Signed-off-by: github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>")" ] ||
    fail "commit message, body or sign-off is wrong: $(git -C "${origin}" log -1 --format=%B "${tip}")"
[ "$(git -C "${work}" rev-parse --abbrev-ref HEAD)" = "main" ] || fail "the API method must not move the local checkout"
no_tmp_refs "first commit"

# 2. An identical re-run leaves the branch alone, even though the new file's
# executable bit makes the trees differ. jq output with CRLF line endings, as
# on Windows runners, must not break the comparison.
mkdir -p "${tmp_dir}/crlf-bin"
cat >"${tmp_dir}/crlf-bin/jq" <<EOF
#!/usr/bin/env bash
set -o pipefail
"${FAKE_JQ}" "\$@" | sed 's/\$/\r/'
EOF
chmod +x "${tmp_dir}/crlf-bin/jq"
rerun="${tmp_dir}/rerun"
new_checkout "${rerun}"
before="$(calls '--input')"
run_action "${rerun}" "${tmp_dir}/output-2" PATH="${tmp_dir}/crlf-bin:${PATH}" >"${tmp_dir}/run-2.log" 2>&1 || {
    cat "${tmp_dir}/run-2.log" >&2
    fail "identical re-run failed"
}
grep -Fq "skipping commit" "${tmp_dir}/run-2.log" || fail "identical re-run should skip the commit"
[ "$(remote_tip "${branch}")" = "${tip}" ] || fail "identical re-run must not rewrite the branch"
[ "$(calls '--input')" = "${before}" ] || fail "identical re-run must not call a mutation"
grep -Fxq "changed=true" "${tmp_dir}/output-2" || fail "identical re-run must still report changed=true so the PR is reused"

# 3. New content replaces the commit in one leased step; the branch (and an
# open PR on it) never points at main in between.
update="${tmp_dir}/update"
new_checkout "${update}"
echo "synced again" >"${update}/config.txt"
run_action "${update}" "${tmp_dir}/output-3" >/dev/null 2>&1 || fail "updating an existing branch failed"
new_tip="$(remote_tip "${branch}")"
[ "${new_tip}" != "${tip}" ] || fail "branch was not updated"
[ "$(git -C "${origin}" rev-parse "${new_tip}^")" = "$(remote_tip main)" ] || fail "updated branch must be one commit on main"
[ "$(git -C "${origin}" show "${new_tip}:config.txt")" = "synced again" ] || fail "updated branch has the wrong content"
git -C "${origin}" reflog show --format=%H "refs/heads/${branch}" | grep -Fxq "$(remote_tip main)" &&
    fail "the working branch was reset to main, which would close its PR"
no_tmp_refs "update"

# 4. When main moves, the commit is rebuilt on the new main.
echo "other" >"${seed}/other.txt"
git -C "${seed}" add other.txt
git -C "${seed}" commit --quiet -m "main moved"
git -C "${seed}" push --quiet origin HEAD:refs/heads/main
moved="${tmp_dir}/moved"
new_checkout "${moved}"
run_action "${moved}" "${tmp_dir}/output-4" >/dev/null 2>&1 || fail "commit after main moved failed"
[ "$(git -C "${origin}" rev-parse "$(remote_tip "${branch}")^")" = "$(remote_tip main)" ] ||
    fail "branch was not rebuilt on the new main"

# 5. A push to the working branch during the run is never overwritten.
race="${tmp_dir}/race"
new_checkout "${race}"
echo "raced" >"${race}/config.txt"
if run_action "${race}" "${tmp_dir}/output-5" FAKE_RACE_REF="refs/heads/${branch}" FAKE_RACE_OID="${tip}" \
    >"${tmp_dir}/run-5.log" 2>&1; then
    fail "a concurrent push to the branch must fail the run"
fi
grep -Fq "changed on GitHub while this run was committing" "${tmp_dir}/run-5.log" || fail "no clear error for the race"
[ "$(remote_tip "${branch}")" = "${tip}" ] || fail "the concurrent push was overwritten"
no_tmp_refs "race"

# 6. A brand-new branch after the old one was deleted (merged PR).
git -C "${origin}" update-ref -d "refs/heads/${branch}"
fresh="${tmp_dir}/fresh"
new_checkout "${fresh}"
run_action "${fresh}" "${tmp_dir}/output-6" >/dev/null 2>&1 || fail "re-creating the branch failed"
[ -n "$(remote_tip "${branch}")" ] || fail "branch was not re-created"

# 7. Changes the API can't express fail before anything is written.
symlink="${tmp_dir}/symlink"
new_checkout "${symlink}"
ln -s config.txt "${symlink}/link"
before="$(remote_tip "${branch}")"
if run_action "${symlink}" "${tmp_dir}/output-7" >"${tmp_dir}/run-7.log" 2>&1; then
    fail "a symlink must fail with commit-method: api"
fi
grep -Fq "which createCommitOnBranch can't commit. Use commit-method: git" "${tmp_dir}/run-7.log" || fail "symlink error does not point to commit-method: git"
[ "$(remote_tip "${branch}")" = "${before}" ] || fail "a failed run must not touch the branch"
no_tmp_refs "symlink"

# 8. A local commit that was never pushed can't be the parent.
local_commit="${tmp_dir}/local-commit"
new_checkout "${local_commit}"
git -C "${local_commit}" commit --quiet --allow-empty -m "local only"
if run_action "${local_commit}" "${tmp_dir}/output-8" >"${tmp_dir}/run-8.log" 2>&1; then
    fail "a local-only base commit must fail with commit-method: api"
fi
grep -Fq "is not on GitHub" "${tmp_dir}/run-8.log" || fail "no clear error for a local-only base commit"

# 9. Nothing to commit: no API calls, changed=false.
clean="${tmp_dir}/clean"
new_checkout "${clean}"
git -C "${clean}" reset --quiet --hard
git -C "${clean}" clean --quiet -fdx
before="$(wc -l <"${FAKE_LOG}")"
run_action "${clean}" "${tmp_dir}/output-9" >/dev/null 2>&1 || fail "no-change run failed"
grep -Fxq "changed=false" "${tmp_dir}/output-9" || fail "changed=false missing when there is nothing to commit"
[ "$(wc -l <"${FAKE_LOG}")" = "${before}" ] || fail "no-change run must not call the API"

echo "✓ open-pr (api): new, identical, updated, rebased, raced, re-created, unsupported, local-only and no-change runs all handled."

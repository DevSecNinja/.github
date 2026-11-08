#!/usr/bin/env bash
#
# Functional test for the push logic of actions/open-pr.
#
# Runs the action's "Stage and commit changes" script against a local bare
# remote that mimics a GitHub checkout: a shallow clone with no
# remote-tracking ref for the working branch. Before the fix, a bare
# `git push --force-with-lease` then failed with "stale info" whenever the
# working branch already existed on the remote (an open PR, or a branch left
# behind after merge), which broke the weekly config-sync in every repo.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
action="${repo_root}/actions/open-pr/action.yml"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT
# Never touch the repository the test lives in.
cd "${tmp_dir}"

branch="chore/config-sync"

fail() {
    echo "error: $*" >&2
    exit 1
}

# Isolate from the developer's git config (signing, hooks, templates).
export GIT_CONFIG_GLOBAL="${tmp_dir}/gitconfig"
export GIT_CONFIG_NOSYSTEM=1
git config --global init.defaultBranch main
git config --global user.name "test"
git config --global user.email "test@example.com"
git config --global commit.gpgsign false
git config --global protocol.file.allow always

script="${tmp_dir}/commit.sh"
awk '
    $0 == "    - name: Stage and commit changes" { in_step = 1; next }
    in_step && $0 ~ /^      run: [|]/ { in_run = 1; next }
    in_run {
        if ($0 ~ /^    - name:/ || $0 ~ /^      [a-z-]+:/) exit
        sub(/^        /, "")
        print
    }
' "${action}" >"${script}"
[ -s "${script}" ] || fail "could not extract the commit script from ${action}"

origin="${tmp_dir}/origin.git"
git init --quiet --bare "${origin}"
# GitHub serves any reachable commit by SHA; the bare remote must too.
git -C "${origin}" config uploadpack.allowReachableSHA1InWant true

seed="${tmp_dir}/seed"
git clone --quiet "file://${origin}" "${seed}" 2>/dev/null
echo "base" >"${seed}/config.txt"
git -C "${seed}" add config.txt
git -C "${seed}" commit --quiet -m "initial"
git -C "${seed}" push --quiet origin HEAD:refs/heads/main

# A leftover working branch on the remote, as after an earlier sync run.
git -C "${seed}" checkout --quiet -b "${branch}"
echo "stale" >"${seed}/config.txt"
git -C "${seed}" commit --quiet -am "stale sync"
git -C "${seed}" push --quiet origin "HEAD:refs/heads/${branch}"

# Fresh shallow checkout of main with a pending change, set up the way
# actions/checkout does it: `git remote add` (default refs/heads/* refspec),
# then a depth-1 fetch of only the checked-out branch, so there is no
# remote-tracking ref for the working branch.
new_checkout() {
    local dir="$1"
    git init --quiet "${dir}"
    git -C "${dir}" remote add origin "file://${origin}"
    git -C "${dir}" fetch --quiet --no-tags --depth=1 origin "+refs/heads/main:refs/remotes/origin/main"
    git -C "${dir}" checkout --quiet -B main refs/remotes/origin/main
    echo "synced" >"${dir}/config.txt"
}

run_action() {
    local dir="$1"
    local output="$2"
    (
        cd "${dir}"
        GITHUB_OUTPUT="${output}" \
            GIT_USER_NAME="github-actions[bot]" \
            GIT_USER_EMAIL="41898282+github-actions[bot]@users.noreply.github.com" \
            BRANCH="${branch}" \
            BASE="main" \
            COMMIT_MESSAGE="" \
            TITLE="chore: sync config files" \
            PATHS="." \
            SIGNOFF="false" \
            IF_NO_CHANGES="skip" \
            bash "${script}"
    )
}

remote_tip() {
    git -C "${origin}" rev-parse "refs/heads/$1" 2>/dev/null || true
}

# Sanity check: the scenario reproduces the original failure.
legacy="${tmp_dir}/legacy"
new_checkout "${legacy}"
git -C "${legacy}" checkout --quiet -B "${branch}"
git -C "${legacy}" commit --quiet -am "legacy push"
if git -C "${legacy}" push --quiet --force-with-lease origin "${branch}" 2>"${tmp_dir}/legacy.err"; then
    fail "scenario does not reproduce the stale-info rejection; the test no longer covers the bug"
fi
grep -Fq "stale info" "${tmp_dir}/legacy.err" ||
    fail "expected a stale-info rejection, got: $(cat "${tmp_dir}/legacy.err")"

# The pre-fetch step that vendored-file-sync.yml runs before its pinned
# (pre-fix) open-pr makes that legacy push succeed.
prefetch="${tmp_dir}/prefetch.sh"
awk '
    $0 == "      - name: Fetch working branch" { in_step = 1; next }
    in_step && $0 ~ /^        run: [|]/ { in_run = 1; next }
    in_run {
        if ($0 ~ /^      - name:/ || $0 ~ /^        [a-z-]+:/) exit
        sub(/^          /, "")
        print
    }
' "${repo_root}/.github/workflows/vendored-file-sync.yml" >"${prefetch}"
[ -s "${prefetch}" ] || fail "could not extract the pre-fetch step from vendored-file-sync.yml"
workaround="${tmp_dir}/workaround"
new_checkout "${workaround}"
(cd "${workaround}" && BRANCH="${branch}" bash "${prefetch}") >/dev/null 2>&1
git -C "${workaround}" checkout --quiet -B "${branch}"
echo "workaround" >"${workaround}/config.txt"
git -C "${workaround}" commit --quiet -am "workaround push"
git -C "${workaround}" push --quiet --force-with-lease origin "${branch}" 2>/dev/null ||
    fail "vendored-file-sync's pre-fetch step does not unblock the pinned open-pr push"
[ "$(remote_tip "${branch}")" = "$(git -C "${workaround}" rev-parse HEAD)" ] ||
    fail "workaround push did not update the remote branch"

# 1. An existing remote branch is updated instead of rejected.
work="${tmp_dir}/work"
new_checkout "${work}"
output="${tmp_dir}/output-1"
run_action "${work}" "${output}" >/dev/null 2>&1 || fail "push to an existing branch failed"
grep -Fxq "changed=true" "${output}" || fail "changed=true missing after updating an existing branch"
tip="$(remote_tip "${branch}")"
[ "${tip}" = "$(git -C "${work}" rev-parse HEAD)" ] || fail "remote branch was not updated to the new commit"
[ "$(git -C "${origin}" rev-parse "${tip}^")" = "$(remote_tip main)" ] ||
    fail "updated branch must be a single commit on top of main"
[ "$(git -C "${origin}" show "${tip}:config.txt")" = "synced" ] || fail "updated branch has the wrong content"

# 2. Re-running with identical changes leaves the branch (and its PR CI) alone.
rerun="${tmp_dir}/rerun"
new_checkout "${rerun}"
output="${tmp_dir}/output-2"
run_action "${rerun}" "${output}" >"${tmp_dir}/rerun.log" 2>&1 || fail "identical re-run failed"
grep -Fq "skipping push" "${tmp_dir}/rerun.log" || fail "identical re-run should skip the push"
[ "$(remote_tip "${branch}")" = "${tip}" ] || fail "identical re-run must not rewrite the branch"
grep -Fxq "changed=true" "${output}" || fail "identical re-run must still report changed=true so the PR is reused"

# 3. New content on a moved base is pushed again.
git -C "${seed}" checkout --quiet main
echo "other" >"${seed}/other.txt"
git -C "${seed}" add other.txt
git -C "${seed}" commit --quiet -m "main moved"
git -C "${seed}" push --quiet origin HEAD:refs/heads/main
moved="${tmp_dir}/moved"
new_checkout "${moved}"
run_action "${moved}" "${tmp_dir}/output-3" >/dev/null 2>&1 || fail "push after base moved failed"
[ "$(git -C "${origin}" rev-parse "$(remote_tip "${branch}")^")" = "$(remote_tip main)" ] ||
    fail "branch was not rebuilt on the new main"

# 4. A branch that does not exist yet is created.
git -C "${origin}" update-ref -d "refs/heads/${branch}"
fresh="${tmp_dir}/fresh"
new_checkout "${fresh}"
run_action "${fresh}" "${tmp_dir}/output-4" >/dev/null 2>&1 || fail "creating a new branch failed"
[ "$(remote_tip "${branch}")" = "$(git -C "${fresh}" rev-parse HEAD)" ] || fail "new branch was not created"

# 5. Nothing to commit: no push, changed=false.
clean="${tmp_dir}/clean"
new_checkout "${clean}"
git -C "${clean}" checkout --quiet -- config.txt
before="$(remote_tip "${branch}")"
run_action "${clean}" "${tmp_dir}/output-5" >/dev/null 2>&1 || fail "no-change run failed"
grep -Fxq "changed=false" "${tmp_dir}/output-5" || fail "changed=false missing when there is nothing to commit"
[ "$(remote_tip "${branch}")" = "${before}" ] || fail "no-change run must not push"

echo "✓ open-pr: existing, identical, rebased, new, and no-change branches all handled."

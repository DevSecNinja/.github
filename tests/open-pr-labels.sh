#!/usr/bin/env bash
#
# Functional test for the label handling of actions/open-pr.
#
# Runs the action's "Open or reuse pull request" script against a fake `gh`
# that, like the real one, rejects `gh pr create --label` for a label the repo
# doesn't have. Before the fix, one missing label (e.g. `apm-sync` in a repo
# that never synced it) made the whole step fail, and a reused PR never got
# its labels.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
action="${repo_root}/actions/open-pr/action.yml"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT
cd "${tmp_dir}"

fail() {
    echo "error: $*" >&2
    exit 1
}

script="${tmp_dir}/open-pr.sh"
awk '
    $0 == "    - name: Open or reuse pull request" { in_step = 1; next }
    in_step && $0 ~ /^      run: [|]/ { in_run = 1; next }
    in_run {
        if ($0 ~ /^    - name:/ || $0 ~ /^      [a-z-]+:/) exit
        sub(/^        /, "")
        print
    }
' "${action}" >"${script}"
[ -s "${script}" ] || fail "could not extract the PR script from ${action}"

# Fake gh: repo labels live in $STATE/labels, every call is logged.
mkdir -p "${tmp_dir}/bin"
cat >"${tmp_dir}/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >>"${STATE}/calls"
has_label() { grep -Fxiq -- "$1" "${STATE}/labels"; }
encode() { jq -rn --arg l "$1" '$l | @uri | ascii_downcase'; }
if [ "$1" = "api" ]; then
    # GET repos/{owner}/{repo}/labels/<name>; a `flaky` label fails once.
    name="$(tr '[:upper:]' '[:lower:]' <<<"${2##*/}")"
    while IFS= read -r label; do
        [ "$(encode "${label}")" = "${name}" ] || continue
        if grep -Fxq -- "${label}" "${STATE}/flaky"; then
            grep -Fxv -- "${label}" "${STATE}/flaky" >"${STATE}/flaky.new" || true
            mv "${STATE}/flaky.new" "${STATE}/flaky"
            exit 1
        fi
        exit 0
    done <"${STATE}/labels"
    exit 1
fi
case "$1 $2" in
    "label create")
        if grep -Fxq -- "$3" "${STATE}/uncreatable" || has_label "$3"; then exit 1; fi
        echo "$3" >>"${STATE}/labels"
        ;;
    "pr create")
        shift 2
        while [ "$#" -gt 0 ]; do
            if [ "$1" = "--label" ] && ! has_label "$2"; then
                echo "could not add label: '$2' not found" >&2
                exit 1
            fi
            shift
        done
        [ -f "${STATE}/pr-exists" ] && { echo "a pull request already exists" >&2; exit 1; }
        echo "https://github.com/o/r/pull/7"
        ;;
    "pr view") echo 7 ;;
    "pr list") if [ -f "${STATE}/pr-exists" ]; then echo '{"number":7,"url":"https://github.com/o/r/pull/7"}'; fi ;;
    "pr edit") ;;
    *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "${tmp_dir}/bin/gh"

# run_case NAME LABELS [pr-exists] [UNCREATABLE] [FLAKY]: fresh state seeded
# with `apm-sync` missing.
run_case() {
    export STATE="${tmp_dir}/$1"
    mkdir -p "${STATE}"
    printf 'bug\nMerge: Manual\n' >"${STATE}/labels"
    : >"${STATE}/uncreatable"
    : >"${STATE}/calls"
    echo "${5:-}" >"${STATE}/flaky"
    [ "${3:-}" = "pr-exists" ] && touch "${STATE}/pr-exists"
    [ -n "${4:-}" ] && echo "$4" >"${STATE}/uncreatable"
    PATH="${tmp_dir}/bin:${PATH}" \
        GITHUB_OUTPUT="${STATE}/output" \
        GH_TOKEN="fake" \
        BRANCH="chore/apm-materialize" \
        BASE="main" \
        TITLE="chore: materialize" \
        BODY="" \
        LABELS="$2" \
        DRAFT="false" \
        bash "${script}" >"${STATE}/log" 2>&1
}

# 1. A missing label is created, an existing one (any case) is not.
run_case create $'apm-sync\n  merge: manual\n' || fail "PR creation failed with a missing label: $(cat "${STATE}/log")"
grep -Fxq "created=true" "${STATE}/output" || fail "expected a new PR"
grep -Fxq "label create apm-sync" "${STATE}/calls" || fail "missing label was not created"
grep -Fq "label create merge" "${STATE}/calls" && fail "existing label must not be re-created"
grep -Fq -- "--label apm-sync --label merge: manual" "${STATE}/calls" || fail "PR was not opened with both labels"

# 2. A label that can't be created is dropped with a warning; the PR still opens.
run_case uncreatable $'apm-sync\nbug' "" apm-sync || fail "PR creation failed when a label could not be created"
grep -Fxq "created=true" "${STATE}/output" || fail "expected a new PR without the uncreatable label"
grep -Fq "::warning::Label 'apm-sync'" "${STATE}/log" || fail "expected a warning for the dropped label"
grep -F "pr create" "${STATE}/calls" | grep -Fq -- "--label apm-sync" && fail "uncreatable label must not be passed to gh"

# 3. A reused PR gets the labels added.
run_case reuse $'apm-sync\nbug' pr-exists || fail "reusing the existing PR failed: $(cat "${STATE}/log")"
grep -Fxq "created=false" "${STATE}/output" || fail "expected the existing PR to be reused"
grep -Fxq "pr edit 7 --add-label apm-sync --add-label bug" "${STATE}/calls" || fail "labels were not added to the reused PR"

# 4. No labels: no label API calls.
run_case none "" || fail "PR creation without labels failed"
grep -Eq "^(api|label) " "${STATE}/calls" && fail "no label calls expected without labels"
grep -Fq "pr edit" "${STATE}/calls" && fail "no pr edit expected without labels"

# 5. An existing label whose first lookup fails (create then reports it exists)
#    is kept, not dropped.
run_case recheck $'bug' "" "" bug || fail "PR creation failed when a label lookup failed once"
grep -Fq "::warning::" "${STATE}/log" && fail "an existing label must not be dropped after a failed lookup"
grep -F "pr create" "${STATE}/calls" | grep -Fq -- "--label bug" || fail "existing label was dropped after a failed lookup"

echo "✓ open-pr: missing, uncreatable, reused, absent and re-checked labels all handled."

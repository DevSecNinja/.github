#!/usr/bin/env bash
#
# Tests the scripts that .github/workflows/autofix.yml runs (#537), with a
# stand-in for mise that logs the formatter calls.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scripts="${repo_root}/scripts/autofix"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

fail() {
    echo "error: $*" >&2
    exit 1
}

bin="${tmp_dir}/bin"
mkdir -p "${bin}"
cat >"${bin}/mise" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${CALLS}"
EOF
chmod +x "${bin}/mise"

repo="${tmp_dir}/repo"
mkdir -p "${repo}/config" "${repo}/sub"
touch "${repo}/a.yml" "${repo}/sub/b.yaml" "${repo}/sub/c.sh" "${repo}/notes.md"

# Runs scripts/autofix/$1 in the scratch repository with CONFIG_DIR=$2.
run() {
    rm -f "${tmp_dir}/calls"
    touch "${tmp_dir}/calls"
    (cd "${repo}" && PATH="${bin}:${PATH}" CALLS="${tmp_dir}/calls" CONFIG_DIR="$2" bash "${scripts}/$1")
}

calls() { cat "${tmp_dir}/calls"; }
# The files a single logged call got after the prefix $1, sorted, so find
# order doesn't matter. Fails when the call doesn't start with $1.
files_after() {
    local call
    call="$(calls)"
    [[ "${call}" == "$1 "* ]] || return 1
    tr ' ' '\n' <<<"${call#"$1 "}" | LC_ALL=C sort | tr '\n' ' '
}

# dprint.sh uses CONFIG_DIR/dprint.json only when it exists.
run dprint.sh ""
[ "$(calls)" = "exec -- dprint fmt" ] || fail "dprint without a config dir: $(calls)"
run dprint.sh config
[ "$(calls)" = "exec -- dprint fmt" ] || fail "dprint without config/dprint.json: $(calls)"
echo "{}" >"${repo}/config/dprint.json"
run dprint.sh config
[ "$(calls)" = "exec -- dprint fmt --config config/dprint.json --config-discovery=false" ] ||
    fail "dprint with config/dprint.json: $(calls)"

# yamlfmt.sh formats every YAML file, with CONFIG_DIR/.yamlfmt.yaml if present.
run yamlfmt.sh config
[ "$(files_after "exec -- yamlfmt")" = "./a.yml ./sub/b.yaml " ] || fail "yamlfmt without a config: $(calls)"
echo "formatter: {}" >"${repo}/config/.yamlfmt.yaml"
run yamlfmt.sh config
[ "$(files_after "exec -- yamlfmt -conf config/.yamlfmt.yaml")" = "./a.yml ./config/.yamlfmt.yaml ./sub/b.yaml " ] ||
    fail "yamlfmt with config/.yamlfmt.yaml: $(calls)"

# shfmt.sh formats every shell script in place.
run shfmt.sh ""
[ "$(calls)" = "exec -- shfmt --write ./sub/c.sh" ] || fail "shfmt: $(calls)"

# commit-and-push.sh commits and pushes only when something changed.
origin="${tmp_dir}/origin.git"
git init --quiet --bare "${origin}"
git -C "${repo}" init --quiet
git -C "${repo}" add .
git -C "${repo}" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit --quiet -m init
git -C "${repo}" remote add origin "${origin}"
branch="$(git -C "${repo}" symbolic-ref --short HEAD)"
git -C "${repo}" push --quiet -u origin "${branch}"

commit() {
    (cd "${repo}" && GIT_CONFIG_GLOBAL=/dev/null COMMIT_MESSAGE="style: auto-fix formatting" \
        bash "${scripts}/commit-and-push.sh") >"${tmp_dir}/log" 2>&1
}

before="$(git -C "${origin}" rev-parse "${branch}")"
commit || fail "a clean tree must not fail: $(cat "${tmp_dir}/log")"
grep -Fxq "No formatting changes to commit." "${tmp_dir}/log" || fail "a clean tree must say so"
[ "$(git -C "${origin}" rev-parse "${branch}")" = "${before}" ] || fail "a clean tree must not push"

echo "key: value" >"${repo}/a.yml"
commit || fail "committing the formatting changes failed: $(cat "${tmp_dir}/log")"
[ "$(git -C "${origin}" log -1 --format='%s|%an|%ae' "${branch}")" = \
    "style: auto-fix formatting|github-actions[bot]|github-actions[bot]@users.noreply.github.com" ] ||
    fail "the formatting commit was not pushed as github-actions[bot]"

echo "✓ autofix: the formatter and commit scripts behave as before."

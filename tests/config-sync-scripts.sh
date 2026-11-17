#!/usr/bin/env bash
#
# Tests scripts/config-sync/ensure-label.sh, which
# .github/workflows/config-sync.yml runs before it opens the sync PR (#537),
# and the templates that scripts/config-sync/sync-files.sh skips. The rest of
# sync-files.sh is covered by
# tests/config-sync-renovate-stub.sh and tests/config-sync-ai-toolkit-instructions.sh.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/scripts/config-sync/ensure-label.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

fail() {
    echo "error: $*" >&2
    exit 1
}

bin="${tmp_dir}/bin"
mkdir -p "${bin}"
cat >"${bin}/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${CALLS}"
[ -z "${GH_FAIL:-}" ]
EOF
chmod +x "${bin}/gh"

run() {
    rm -f "${tmp_dir}/calls"
    env PATH="${bin}:${PATH}" CALLS="${tmp_dir}/calls" "$@" bash "${script}" >"${tmp_dir}/log" 2>&1
}

run || fail "creating the label failed: $(cat "${tmp_dir}/log")"
[ "$(cat "${tmp_dir}/calls")" = 'label create config-sync --color 0075ca --description Automated config sync PR --force' ] ||
    fail "unexpected gh call: $(cat "${tmp_dir}/calls")"
[ ! -s "${tmp_dir}/log" ] || fail "a created label must not warn: $(cat "${tmp_dir}/log")"

run GH_FAIL=1 || fail "a label that cannot be created must not fail the sync"
grep -Fq "::warning::Could not create/update config-sync label" "${tmp_dir}/log" ||
    fail "a label that cannot be created must warn"

echo "✓ config-sync: ensure-label.sh creates the label and only warns when it can't."

# sync-files.sh doesn't bootstrap the ruff.toml template when the repository
# configures ruff elsewhere: ruff.toml would take precedence and replace it.
sync_script="${repo_root}/scripts/config-sync/sync-files.sh"
consumer="${tmp_dir}/consumer"

# Runs the sync with sync-templates in a fresh consumer checkout; $1 is a
# file to create there, $2 its content.
sync_templates() {
    rm -rf "${consumer}"
    mkdir -p "${consumer}/.config-sync-source/config-sync"
    cp -R "${repo_root}/config-sync/templates" "${consumer}/.config-sync-source/config-sync/templates"
    git -C "${consumer}/.config-sync-source" init --quiet
    git -C "${consumer}/.config-sync-source" -c user.name=t -c user.email=t@t \
        -c commit.gpgsign=false commit --quiet --allow-empty -m init
    [ -z "$1" ] || printf '%s\n' "$2" >"${consumer}/$1"
    (
        cd "${consumer}"
        GITHUB_REPOSITORY=DevSecNinja/example GITHUB_OUTPUT="${tmp_dir}/output" SYNC_TEMPLATES=true \
            IGNORE_FILE=.github/.config-sync-ignore SOURCE_DIR=.config-sync-source/config-sync \
            bash "${sync_script}" >"${tmp_dir}/log" 2>&1
    ) || fail "sync step failed: $(cat "${tmp_dir}/log")"
}

sync_templates "" ""
cmp -s "${repo_root}/config-sync/templates/ruff.toml" "${consumer}/ruff.toml" ||
    fail "a repository without ruff config must get the ruff.toml template"
sync_templates pyproject.toml $'[project]\nname = "x"\n\n[tool.ruffle]\nx = 1'
[ -e "${consumer}/ruff.toml" ] || fail "[tool.ruffle] in pyproject.toml is not ruff config"
for config in "[tool.ruff]" "[tool.ruff.lint]" "  [tool.ruff.format]"; do
    sync_templates pyproject.toml $'[project]\nname = "x"\n\n'"${config}"$'\nline-length = 100'
    [ ! -e "${consumer}/ruff.toml" ] || fail "ruff.toml must not be added next to ${config} in pyproject.toml"
    grep -Fq "ruff.toml skipped: configured in [tool.ruff] in pyproject.toml" "${tmp_dir}/log" ||
        fail "the skipped ruff.toml must be logged: $(cat "${tmp_dir}/log")"
done
sync_templates .ruff.toml "line-length = 100"
[ ! -e "${consumer}/ruff.toml" ] || fail "ruff.toml must not be added next to .ruff.toml"

echo "✓ config-sync: sync-files.sh keeps the ruff.toml template out of repositories that configure ruff elsewhere."

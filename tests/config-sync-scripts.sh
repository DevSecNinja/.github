#!/usr/bin/env bash
#
# Tests scripts/config-sync/ensure-label.sh, which
# .github/workflows/config-sync.yml runs before it opens the sync PR (#537),
# the templates that scripts/config-sync/sync-files.sh skips, and its
# .gitattributes bootstrap and LF check. The rest of sync-files.sh is covered by
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

[ -e "${consumer}/biome.json" ] || fail "a repository without Biome config must get the biome.json template"
sync_templates biome.jsonc "{}"
[ ! -e "${consumer}/biome.json" ] || fail "biome.json must not be added next to biome.jsonc"
grep -Fq "biome.json skipped: configured in biome.jsonc" "${tmp_dir}/log" ||
    fail "the skipped biome.json must be logged: $(cat "${tmp_dir}/log")"

echo "✓ config-sync: sync-files.sh keeps the ruff.toml and biome.json templates out of repositories that configure them elsewhere."

# sync-files.sh bootstraps .gitattributes even without sync-templates, never
# overwrites it, and warns when an existing one has no LF default.
gitattributes_template="${repo_root}/config-sync/templates/.gitattributes"

# Runs the sync without sync-templates in a fresh consumer checkout. $1 is the
# content of its .gitattributes (empty: no file, printed with %b), $2 of its
# .config-sync-ignore.
sync_bootstrap() {
    rm -rf "${consumer}" "${tmp_dir}/output"
    mkdir -p "${consumer}/.config-sync-source/config-sync" "${consumer}/.github"
    cp -R "${repo_root}/config-sync/templates" "${consumer}/.config-sync-source/config-sync/templates"
    git -C "${consumer}/.config-sync-source" init --quiet
    git -C "${consumer}/.config-sync-source" -c user.name=t -c user.email=t@t \
        -c commit.gpgsign=false commit --quiet --allow-empty -m init
    # Already present, so .gitattributes is the only file that can change.
    printf '{ extends: ["github>DevSecNinja/.github//.renovate/default.json5"] }\n' >"${consumer}/renovate.json5"
    [ -z "$1" ] || printf '%b' "$1" >"${consumer}/.gitattributes"
    [ -z "$2" ] || printf '%s\n' "$2" >"${consumer}/.github/.config-sync-ignore"
    (
        cd "${consumer}"
        GITHUB_REPOSITORY=DevSecNinja/example GITHUB_OUTPUT="${tmp_dir}/output" SYNC_TEMPLATES=false \
            IGNORE_FILE=.github/.config-sync-ignore SOURCE_DIR=.config-sync-source/config-sync \
            bash "${sync_script}" >"${tmp_dir}/log" 2>&1
    ) || fail "sync step failed: $(cat "${tmp_dir}/log")"
}

lf_warned() { grep -Fq '::warning file=.gitattributes,' "${tmp_dir}/log"; }

sync_bootstrap "" ""
cmp -s "${gitattributes_template}" "${consumer}/.gitattributes" ||
    fail "a repository without .gitattributes must get the template, even without sync-templates"
grep -Fxq updated=1 "${tmp_dir}/output" || fail "bootstrapping .gitattributes must open a sync PR"
! lf_warned || fail "the .gitattributes template must not trigger the LF warning: $(cat "${tmp_dir}/log")"
[ ! -e "${consumer}/.mise.toml" ] || fail "other templates still require sync-templates"

own='* text=auto eol=lf\n*.ics -text\n'
sync_bootstrap "${own}" ""
[ "$(cat "${consumer}/.gitattributes")" = "$(printf '%b' "${own}")" ] || fail "an existing .gitattributes must never be overwritten"
grep -Fxq updated=0 "${tmp_dir}/output" || fail "an existing .gitattributes must not open a sync PR"
! lf_warned || fail "a .gitattributes with an LF default must not warn"

lf_cases=(
    '* text=auto eol=lf\r\n*.ps1 text eol=crlf\r\n'
    '# Defaults\n*   text=auto   eol=lf\n*.bat text eol=crlf\n'
    '* text=auto eol=crlf\n* eol=lf\n'
    '* text=auto eol=lf\n* !eol\n* eol=lf\n'
)
no_lf_cases=(
    '* text=auto\n*.ps1 text eol=crlf\n'
    '* text=auto eol=crlf\n*.yml text eol=lf\n'
    '* text=auto eol=lf\n* eol=crlf\n'
    '* text=auto eol=lf\n* !eol\n'
    '* text=auto eol=lf\n* -eol\n'
    '# * text=auto eol=lf\n*.sh text eol=lf\n'
)
for attributes in "${lf_cases[@]}"; do
    sync_bootstrap "${attributes}" ""
    ! lf_warned || fail "LF as the last * eol must not warn: ${attributes}"
done
for attributes in "${no_lf_cases[@]}"; do
    sync_bootstrap "${attributes}" ""
    lf_warned || fail "a .gitattributes without an LF default must warn: ${attributes}"
done

sync_bootstrap "" ".gitattributes"
[ ! -e "${consumer}/.gitattributes" ] || fail "an ignored .gitattributes must not be bootstrapped"
sync_bootstrap '* text=auto eol=crlf\n' ".gitattributes"
! lf_warned || fail "an ignored .gitattributes must not warn"

echo "✓ config-sync: sync-files.sh bootstraps .gitattributes without overwriting it and warns when it has no LF default."

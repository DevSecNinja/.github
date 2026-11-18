#!/usr/bin/env bash
#
# Tests the renovate.json5 stub that config-sync bootstraps:
#
# 1. The stub template extends the central .renovate/default.json5 preset, and
#    that preset extends every shared .renovate preset (except opt-in ones) in
#    the same order as this repository's own renovate.json5.
# 2. The config-sync sync script creates renovate.json5 only when it is missing,
#    even without sync-templates, never overwrites it, and warns when it does
#    not extend the central preset.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The sync step of .github/workflows/config-sync.yml (#537).
script="${repo_root}/scripts/config-sync/sync-files.sh"
template="${repo_root}/config-sync/templates/renovate.json5"
preset_prefix="github>DevSecNinja/.github//.renovate/"
default_preset="${preset_prefix}default.json5"
# Presets a repository adds to its own renovate.json5 when it needs them.
opt_in=(go.json5 typescript-eslint.json5)
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

fail() {
    echo "error: $*" >&2
    exit 1
}

command -v pyjson5 >/dev/null 2>&1 || fail "'pyjson5' not found on PATH. Run via 'mise run test'."

to_json() {
    pyjson5 --as-json "$1"
}

shared_presets() {
    to_json "$1" | jq -r --arg prefix "${preset_prefix}" \
        '.extends[] | select(startswith($prefix)) | ltrimstr($prefix)' | tr -d '\r'
}

# 1. The stub and the central preset.
[ ! -e "${repo_root}/config-sync/files/renovate.json5" ] ||
    fail "renovate.json5 must be a template only; config-sync/files/ would overwrite local rules"
to_json "${template}" | jq -e --arg preset "${default_preset}" '.extends[0] == $preset' >/dev/null ||
    fail "the renovate.json5 template must extend ${default_preset} first"

mapfile -t default_presets < <(shared_presets "${repo_root}/.renovate/default.json5")
for preset in "${default_presets[@]}"; do
    [ -f "${repo_root}/.renovate/${preset}" ] || fail ".renovate/default.json5 extends missing preset ${preset}"
done
for file in "${repo_root}"/.renovate/*.json5; do
    preset="$(basename "${file}")"
    [ "${preset}" = default.json5 ] && continue
    for optional in "${opt_in[@]}"; do
        [ "${preset}" = "${optional}" ] && continue 2
    done
    printf '%s\n' "${default_presets[@]}" | grep -Fxq -- "${preset}" ||
        fail ".renovate/default.json5 does not extend ${preset}; extend it or list it as opt-in in this test"
done
for optional in "${opt_in[@]}"; do
    [ -f "${repo_root}/.renovate/${optional}" ] || fail "opt-in preset ${optional} does not exist"
    ! printf '%s\n' "${default_presets[@]}" | grep -Fxq -- "${optional}" ||
        fail ".renovate/default.json5 must not extend the opt-in preset ${optional}"
done
[ "$(printf '%s\n' "${default_presets[@]}")" = "$(shared_presets "${repo_root}/renovate.json5")" ] ||
    fail ".renovate/default.json5 must extend the shared presets in the same order as renovate.json5"

# 2. The sync step bootstraps the stub and checks it.

consumer="${tmp_dir}/consumer"
log="${tmp_dir}/log"

# Runs the sync step in a fresh consumer checkout. $1 is the content of its
# renovate.json5 (empty: no file), $2 of its .config-sync-ignore, $3 the
# sync-templates input.
run_sync() {
    local source="${consumer}/.config-sync-source"
    rm -rf "${consumer}" "${tmp_dir}/output"
    mkdir -p "${source}/config-sync/files" "${consumer}/.github"
    cp -R "${repo_root}/config-sync/templates" "${source}/config-sync/templates"
    echo "central" >"${source}/config-sync/files/.editorconfig"
    # Already in sync, so renovate.json5 is the only file that can change.
    echo "central" >"${consumer}/.editorconfig"
    cp "${repo_root}/config-sync/templates/.gitattributes" "${consumer}/.gitattributes"
    git -C "${source}" init --quiet
    git -C "${source}" -c user.name=t -c user.email=t@t \
        -c commit.gpgsign=false commit --quiet --allow-empty -m init
    [ -z "$1" ] || printf '%s\n' "$1" >"${consumer}/renovate.json5"
    [ -z "$2" ] || printf '%s\n' "$2" >"${consumer}/.github/.config-sync-ignore"
    (
        cd "${consumer}"
        GITHUB_REPOSITORY=DevSecNinja/example GITHUB_OUTPUT="${tmp_dir}/output" SYNC_TEMPLATES="$3" \
            IGNORE_FILE=.github/.config-sync-ignore \
            SOURCE_DIR=.config-sync-source/config-sync \
            bash "${script}" >"${log}"
    ) || fail "sync step failed: $(cat "${log}")"
}

warned() { grep -Fq '::warning file=renovate.json5,' "${log}"; }

run_sync "" "" false
cmp -s "${template}" "${consumer}/renovate.json5" ||
    fail "a repo without renovate.json5 must get the stub, even without sync-templates"
[ ! -e "${consumer}/.mise.toml" ] || fail "other templates still require sync-templates"
grep -Fxq updated=1 "${tmp_dir}/output" || fail "bootstrapping the stub must open a sync PR"
! warned || fail "the fresh stub must not trigger the drift warning"

run_sync "" "" true
cmp -s "${template}" "${consumer}/renovate.json5" || fail "sync-templates must bootstrap the stub too"
[ -e "${consumer}/.mise.toml" ] || fail "sync-templates must bootstrap the other templates"

local_config="{
  extends: [\"${default_preset}\"],
  packageRules: [{ matchPackageNames: [\"example\"], enabled: false }],
}"
run_sync "${local_config}" "" false
[ "$(cat "${consumer}/renovate.json5")" = "${local_config}" ] || fail "an existing renovate.json5 must never be overwritten"
! warned || fail "a renovate.json5 that extends ${default_preset} must not warn"
grep -Fxq updated=0 "${tmp_dir}/output" || fail "an existing renovate.json5 must not open a sync PR"

legacy="{ extends: [\"config:recommended\", \"${preset_prefix}base.json5\"] }"
run_sync "${legacy}" "" false
[ "$(cat "${consumer}/renovate.json5")" = "${legacy}" ] || fail "a legacy renovate.json5 must not be overwritten"
warned || fail "a renovate.json5 without ${default_preset} must warn"

# Only the top-level extends array counts; comments and other keys do not.
extends_cases=(
    "{ extends: ['${default_preset}'] }"
    "{
  \"extends\": [
    // org defaults
    \"${default_preset}\", /* local */ \"config:recommended\",
  ],
  description: \"not \\\"extends\\\": [x]\",
}"
)
missing_cases=(
    "{
  // extends: [\"${default_preset}\"],
  extends: [\"config:recommended\"],
}"
    "{
  extends: [
    \"config:recommended\", // \"${default_preset}\"
    /* \"${default_preset}\", */
  ],
}"
    "{ extends: [\"config:recommended\"], ignorePresets: [\"${default_preset}\"] }"
    "{ extends: [\"config:recommended\"], description: \"${default_preset}\" }"
    "{ packageRules: [{ extends: [\"${default_preset}\"] }] }"
)
for config in "${extends_cases[@]}"; do
    run_sync "${config}" "" false
    ! warned || fail "a top-level extends entry for ${default_preset} must not warn: ${config}"
done
for config in "${missing_cases[@]}"; do
    run_sync "${config}" "" false
    warned || fail "a renovate.json5 that does not extend ${default_preset} at the top level must warn: ${config}"
done

run_sync "" "renovate.json5" false
[ ! -e "${consumer}/renovate.json5" ] || fail "an ignored renovate.json5 must not be bootstrapped"

echo "config-sync renovate.json5 stub tests passed"

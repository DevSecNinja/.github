#!/usr/bin/env bash
#
# Tests the config-sync distribution of the ai-toolkit instructions:
#
# 1. The copies under config-sync/files/.github/instructions/ match what
#    config-sync/sync-ai-toolkit-instructions.sh generates from the
#    APM-materialized files, provenance marker included.
# 2. The config-sync workflow skips paths that the calling repo deploys through
#    APM (listed in its apm.lock.yaml), so it never writes a second copy.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="${repo_root}/.github/workflows/config-sync.yml"
instruction=".github/instructions/devsecninja-conventions.instructions.md"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

fail() {
    echo "error: $*" >&2
    exit 1
}

# 1. Generated copies are current.
bash "${repo_root}/config-sync/sync-ai-toolkit-instructions.sh" --check ||
    fail "run config-sync/sync-ai-toolkit-instructions.sh and commit the result"
grep -Eq '^<!-- config-sync: source=DevSecNinja/ai-toolkit ref=v[0-9][^ ]* commit=[0-9a-f]{40} ' \
    "${repo_root}/config-sync/files/${instruction}" ||
    fail "config-sync/files/${instruction} has no provenance marker"

# 2. The sync step skips APM-managed paths.
script="${tmp_dir}/sync.sh"
awk '
    $0 == "      - name: Sync config files from central repo" { in_step = 1; next }
    in_step && $0 ~ /^        run: [|]/ { in_run = 1; next }
    in_run {
        if ($0 ~ /^      - name:/) exit
        sub(/^          /, "")
        print
    }
' "${workflow}" >"${script}"
[ -s "${script}" ] || fail "could not extract the sync script from ${workflow}"

# Runs the sync step in a fresh consumer checkout; $1 is its apm.lock.yaml
# (empty for a repo without APM).
run_sync() {
    local consumer="${tmp_dir}/consumer"
    rm -rf "${consumer}"
    mkdir -p "${consumer}/.config-sync-source/config-sync/files/.github/instructions"
    git -C "${consumer}/.config-sync-source" init --quiet
    git -C "${consumer}/.config-sync-source" -c user.name=t -c user.email=t@t \
        -c commit.gpgsign=false commit --quiet --allow-empty -m init
    echo "central" >"${consumer}/.config-sync-source/config-sync/files/${instruction}"
    echo "central" >"${consumer}/.config-sync-source/config-sync/files/.editorconfig"
    if [ -n "$1" ]; then
        printf '%s\n' "$1" >"${consumer}/apm.lock.yaml"
        mkdir -p "${consumer}/.github/instructions"
        echo "apm" >"${consumer}/${instruction}"
    fi
    (
        cd "${consumer}"
        GITHUB_OUTPUT="${tmp_dir}/output" SYNC_TEMPLATES=false \
            IGNORE_FILE=.github/.config-sync-ignore \
            SOURCE_DIR=.config-sync-source/config-sync \
            bash "${script}" >"${tmp_dir}/log"
    ) || fail "sync step failed: $(cat "${tmp_dir}/log")"
}

run_sync ""
[ "$(cat "${tmp_dir}/consumer/${instruction}")" = "central" ] ||
    fail "a repo without APM must receive ${instruction}"

run_sync "dependencies:
- repo_url: DevSecNinja/ai-toolkit
  name: ai-toolkit
  deployed_files:
  - ${instruction}
mcp_servers:
- microsoft-learn"
[ "$(cat "${tmp_dir}/consumer/${instruction}")" = "apm" ] ||
    fail "config-sync overwrote the APM-managed ${instruction}"
[ "$(cat "${tmp_dir}/consumer/.editorconfig")" = "central" ] ||
    fail "config-sync must still sync paths APM does not manage"
grep -Fq "${instruction} (deployed by APM" "${tmp_dir}/log" ||
    fail "the skip must be logged"

echo "config-sync ai-toolkit instructions: OK"

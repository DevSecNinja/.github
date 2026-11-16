#!/usr/bin/env bash
#
# Tests that the dprint and yamlfmt configs that config-sync distributes skip
# Spec Kit output (.specify/, .github/skills/) and Python virtual environments,
# the way the shared lint workflow runs them, while still checking other files.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
config_dir="${repo_root}/config-sync/files"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

fail() {
    echo "error: $*" >&2
    exit 1
}

for tool in dprint yamlfmt; do
    command -v "${tool}" >/dev/null 2>&1 || fail "${tool} is not installed; run 'mise install'"
done

consumer="${tmp_dir}/consumer"
skipped_yaml=(.specify/workflows/speckit/workflow.yml .venv/lib/x.yml .venv-minimum/x.yaml)
skipped_md=(.specify/templates/spec-template.md .github/skills/speckit-plan/SKILL.md)
for path in "${skipped_yaml[@]}" checked.yml; do
    mkdir -p "$(dirname "${consumer}/${path}")"
    printf 'key:   [a,b]\n' >"${consumer}/${path}"
done
for path in "${skipped_md[@]}" checked.md; do
    mkdir -p "$(dirname "${consumer}/${path}")"
    printf '#  Unformatted\n' >"${consumer}/${path}"
done
cd "${consumer}"

# yamlfmt, as lint.yml runs it: files from find, config from lint-config-dir.
yamlfmt_out="$(
    find . \( -name '*.yaml' -o -name '*.yml' \) -print0 |
        xargs -0 yamlfmt -conf "${config_dir}/.yamlfmt.yaml" -lint 2>&1 | tr '\134' '/' || true
)"
grep -Fq 'checked.yml' <<<"${yamlfmt_out}" || fail "yamlfmt must still lint other files: ${yamlfmt_out}"
for path in "${skipped_yaml[@]}"; do
    ! grep -Fq "${path}" <<<"${yamlfmt_out}" || fail "yamlfmt must skip ${path}"
done

# dprint resolves its globs relative to the config file, which config-sync
# writes to the repository root.
cp "${config_dir}/dprint.json" dprint.json
dprint_files="$(dprint output-file-paths 2>&1 | tr '\134' '/')" || fail "dprint failed: ${dprint_files}"
grep -Fq 'checked.md' <<<"${dprint_files}" || fail "dprint must still check other files: ${dprint_files}"
for path in "${skipped_md[@]}"; do
    ! grep -Fq "${path}" <<<"${dprint_files}" || fail "dprint must skip ${path}"
done

echo "config-sync lint excludes: OK"

#!/usr/bin/env bash
#
# Contract test for the npm 12 EALLOWREMOTE workaround (npm/cli#9800) in the
# shared presets. The `npmrc` override must stay as narrow as possible:
#
# - only in the npm manager block, never at the top level or in packageRules,
#   so no other manager is affected. Renovate's npm manager also writes it for
#   pnpm and Yarn lockfile updates; neither has an allow-remote setting, so for
#   them the line is inert;
# - only `allow-remote=all`: no allow-git, registry, script or auth settings;
# - with npmrcMerge, so a repository's own .npmrc is kept and can override it.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
    echo "error: $*" >&2
    exit 1
}

command -v pyjson5 >/dev/null 2>&1 || fail "'pyjson5' not found on PATH. Run via 'mise run test'."

found=0
for file in "${repo_root}"/.renovate/*.json5; do
    name="$(basename "${file}")"
    config="$(pyjson5 --as-json "${file}" | tr -d '\r')"
    misplaced="$(jq -r '[paths(objects) as $p | select(getpath($p) | has("npmrc")) | $p | map(tostring) | join(".")]
        | map(select(. != "npm")) | join(", ")' <<<"${config}")"
    [ -z "${misplaced}" ] || fail "${name}: npmrc is only allowed in the npm manager block, found at: ${misplaced}"
    if jq -e 'has("npmrc")' <<<"${config}" >/dev/null; then
        fail "${name}: a top-level npmrc would reach every manager and, without npmrcMerge, replace repository .npmrc files"
    fi
    jq -e '.npm.npmrc' <<<"${config}" >/dev/null || continue
    found=$((found + 1))
    settings="$(jq -r '.npm.npmrc | split("\n") | map(select(test("^\\s*([#;].*)?$") | not)) | join(" ")' <<<"${config}")"
    [ "${settings}" = "allow-remote=all" ] ||
        fail "${name}: npm.npmrc may only set allow-remote=all (npm/cli#9800 workaround), found: ${settings}"
    jq -e '.npm.npmrcMerge == true' <<<"${config}" >/dev/null ||
        fail "${name}: npm.npmrc needs npmrcMerge: true, otherwise it replaces the repository's own .npmrc"
done
[ "${found}" -le 1 ] || fail "npm.npmrc is set in ${found} presets; keep the workaround in one place"

echo "Renovate npm allow-remote workaround: OK"

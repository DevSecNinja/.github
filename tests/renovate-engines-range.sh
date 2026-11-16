#!/usr/bin/env bash
#
# Contract test: npm `engines` declare a supported range and are never pinned.
# base.json5 sets `rangeStrategy: "pin"`, so a package rule must switch npm
# engines to "replace", and no later rule may set another range strategy for
# them. The exact Node.js version is pinned in .mise.toml instead.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
    echo "error: $*" >&2
    exit 1
}

command -v pyjson5 >/dev/null 2>&1 || fail "'pyjson5' not found on PATH. Run via 'mise run test'."

# Preset files in the order renovate.json5 extends them; later rules win.
mapfile -t presets < <(
    pyjson5 --as-json "${repo_root}/renovate.json5" |
        jq -r '.extends[] | select(startswith("github>DevSecNinja/.github//.renovate/")) | ltrimstr("github>DevSecNinja/.github//.renovate/")' |
        tr -d '\r'
)
[ "${#presets[@]}" -gt 0 ] || fail "renovate.json5 extends no .renovate presets"

# The last rule that sets a range strategy and can match npm engines decides.
strategy="$(
    for preset in "${presets[@]}"; do
        pyjson5 --as-json "${repo_root}/.renovate/${preset}" | jq '.packageRules // []'
    done | jq -rs '
        [add[]
            | select(has("rangeStrategy"))
            | select((.matchManagers // ["npm"]) | index("npm"))
            | select((.matchDepTypes // ["engines"]) | index("engines"))]
        | last | .rangeStrategy // "none"' | tr -d '\r'
)"
[ "${strategy}" = replace ] ||
    fail "npm engines must use rangeStrategy \"replace\" (effective: ${strategy}); .mise.toml owns the exact version"

echo "Renovate npm engines range strategy: OK"

#!/usr/bin/env bash
#
# Tests scripts/config-sync/ensure-label.sh, which
# .github/workflows/config-sync.yml runs before it opens the sync PR (#537).
# scripts/config-sync/sync-files.sh is covered by
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

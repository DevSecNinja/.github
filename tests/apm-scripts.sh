#!/usr/bin/env bash
#
# Tests the scripts that .github/workflows/apm-sync.yml (scripts/apm-sync/) and
# .github/workflows/apm-materialize.yml (scripts/apm-materialize/) run (#537),
# with stand-ins for curl, python3 and apm.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

fail() {
    echo "error: $*" >&2
    exit 1
}

# Stand-ins that log their arguments to ${calls}.
bin="${tmp_dir}/bin"
calls="${tmp_dir}/calls"
mkdir -p "${bin}"
cat >"${bin}/apm" <<'EOF'
#!/usr/bin/env bash
echo "apm $*" >>"${CALLS}"
[ "${APM_FAIL:-}" != "$1" ]
EOF
cat >"${bin}/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >>"${CALLS}"
[ -z "${CURL_FAIL:-}" ] || exit 22
echo 'echo "installer VERSION=${VERSION} APM_INSTALL_DIR=${APM_INSTALL_DIR} APM_LIB_DIR=${APM_LIB_DIR}" >>"${CALLS}"'
EOF
cat >"${bin}/python3" <<'EOF'
#!/usr/bin/env bash
echo "python3 $*" >>"${CALLS}"
EOF
chmod +x "${bin}"/*

# Runs scripts/$1 in a fresh scratch directory (with apm.yml when $2 is "yes"),
# with the stand-ins first on PATH and env from the remaining arguments.
run() {
    local script="${repo_root}/scripts/$1"
    local manifest="$2"
    shift 2
    rm -rf "${tmp_dir}/repo" "${calls}" "${tmp_dir}/output" "${tmp_dir}/path"
    mkdir -p "${tmp_dir}/repo"
    touch "${calls}" "${tmp_dir}/output" "${tmp_dir}/path"
    [ "${manifest}" != yes ] || echo "dependencies: {}" >"${tmp_dir}/repo/apm.yml"
    (
        cd "${tmp_dir}/repo"
        env PATH="${bin}:${PATH}" CALLS="${calls}" HOME="${tmp_dir}/home" \
            GITHUB_OUTPUT="${tmp_dir}/output" GITHUB_PATH="${tmp_dir}/path" "$@" \
            bash "${script}" >"${tmp_dir}/log" 2>&1
    )
}

expect_calls() {
    [ "$(cat "${calls}")" = "$1" ] || fail "unexpected calls:"$'\n'"$(cat "${calls}")"$'\n'"expected:"$'\n'"$1"
}

# check-manifest.sh: skip without apm.yml, in both workflows.
for kind in sync materialize; do
    run "apm-${kind}/check-manifest.sh" no || fail "apm-${kind}: a repo without apm.yml must not fail"
    grep -Fxq "skip=true" "${tmp_dir}/output" || fail "apm-${kind}: no apm.yml must set skip=true"
    grep -Fxq "::notice::No apm.yml in this repo; nothing to ${kind}." "${tmp_dir}/log" ||
        fail "apm-${kind}: no apm.yml must explain the skip"
    run "apm-${kind}/check-manifest.sh" yes || fail "apm-${kind}: a repo with apm.yml must not fail"
    [ "$(cat "${tmp_dir}/output")" = "skip=false" ] || fail "apm-${kind}: apm.yml must set skip=false"
done

# apm-sync/install-apm.sh: pipes the official installer to sh with the step env.
run apm-sync/install-apm.sh yes VERSION=1.2.3 APM_INSTALL_DIR=/opt/apm/bin APM_LIB_DIR=/opt/apm/lib ||
    fail "apm-sync: install-apm.sh failed: $(cat "${tmp_dir}/log")"
expect_calls "curl -sSL https://aka.ms/apm-unix
installer VERSION=1.2.3 APM_INSTALL_DIR=/opt/apm/bin APM_LIB_DIR=/opt/apm/lib"
[ "$(cat "${tmp_dir}/path")" = /opt/apm/bin ] || fail "apm-sync: the install dir must be added to GITHUB_PATH"
if run apm-sync/install-apm.sh yes CURL_FAIL=1 APM_INSTALL_DIR=/opt/apm/bin; then
    fail "apm-sync: a failed installer download must fail the step"
fi
[ ! -s "${tmp_dir}/path" ] || fail "apm-sync: a failed install must not touch GITHUB_PATH"

# apm-sync/update.sh: PACKAGES is split into arguments; empty updates all.
run apm-sync/update.sh yes PACKAGES="owner/a  owner/b" || fail "apm-sync: update.sh failed: $(cat "${tmp_dir}/log")"
expect_calls $'apm --version\napm update --yes owner/a owner/b'
run apm-sync/update.sh yes PACKAGES="" || fail "apm-sync: update.sh without packages failed"
expect_calls $'apm --version\napm update --yes'
if run apm-sync/update.sh yes PACKAGES="" APM_FAIL=update; then
    fail "apm-sync: a failed apm update must fail the step"
fi

# apm-materialize/install-apm.sh: pins apm-cli and adds the user bin dir.
run apm-materialize/install-apm.sh yes apm_cli_version=0.35.0 ||
    fail "apm-materialize: install-apm.sh failed: $(cat "${tmp_dir}/log")"
expect_calls "python3 -m pip install --user apm-cli==0.35.0"
[ "$(cat "${tmp_dir}/path")" = "${tmp_dir}/home/.local/bin" ] ||
    fail "apm-materialize: ~/.local/bin must be added to GITHUB_PATH"

# apm-materialize/install.sh: logs the version, then installs.
run apm-materialize/install.sh yes || fail "apm-materialize: install.sh failed: $(cat "${tmp_dir}/log")"
expect_calls $'apm --version\napm install'
if run apm-materialize/install.sh yes APM_FAIL=install; then
    fail "apm-materialize: a failed apm install must fail the step"
fi

echo "✓ apm-sync and apm-materialize scripts behave as before."

#!/usr/bin/env bash
#
# Tests the gitleaks config that config-sync distributes to every repository:
#
# 1. It extends the gitleaks default rules, so a fake GitHub token is detected.
#    A config without `[extend] useDefault = true` replaces the defaults and
#    detects nothing.
# 2. The global allowlist still suppresses the `\d+/api/verify` pattern, while
#    the same secret without it is detected.
#
# The fake secrets are generated at test time so no committed fixture trips the
# repository's own secret scan.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
config="${repo_root}/config-sync/files/.gitleaks.toml"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

fail() {
    echo "error: $*" >&2
    exit 1
}

command -v gitleaks >/dev/null 2>&1 || fail "gitleaks is not installed; run 'mise install'"

chars="$(head -c 4096 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9')"
[ "${#chars}" -ge 36 ] || fail "could not generate random fixture data"

# Scans a repository named $1 holding one fixture with content $2 and prints
# the IDs of the rules that fired. Like a consuming repository, the config sits
# at the root, where config-sync writes it and gitleaks discovers it without
# --config.
scan() {
    local workdir="${tmp_dir}/$1"
    local report="${tmp_dir}/$1.csv"
    local status=0
    mkdir -p "${workdir}"
    cp "${config}" "${workdir}/.gitleaks.toml"
    printf '%s\n' "$2" >"${workdir}/fixture.txt"
    (
        cd "${workdir}"
        env -u GITLEAKS_CONFIG -u GITLEAKS_CONFIG_TOML \
            gitleaks dir . --no-banner --redact --exit-code 42 \
            --report-format csv --report-path "${report}" >/dev/null 2>"${tmp_dir}/$1.log"
    ) || status=$?
    case "${status}" in
        0 | 42) ;;
        *) fail "gitleaks failed on $1: $(cat "${tmp_dir}/$1.log")" ;;
    esac
    tail -n +2 "${report}" | cut -d, -f1
}

findings="$(scan token "token = \"ghp_${chars:0:36}\"")"
grep -Fqx github-pat <<<"${findings}" ||
    fail "the synced config must detect a GitHub token; add '[extend] useDefault = true' to ${config}"

webhook="https://hooks.slack.com/services/T${chars:0:10}"
findings="$(scan allowlisted "url = \"${webhook}/1234/api/verify/${chars:10:24}\"")"
[ -z "${findings}" ] ||
    fail "the global allowlist must suppress '\\d+/api/verify'; got: ${findings}"
findings="$(scan control "url = \"${webhook}/abcd/api/verify/${chars:10:24}\"")"
grep -Fqx slack-webhook-url <<<"${findings}" ||
    fail "a Slack webhook outside the allowlist must be detected; got: ${findings:-nothing}"

echo "gitleaks config: OK"

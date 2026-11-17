#!/usr/bin/env bash
#
# Tests the scripts of actions/release-publish (#537): release-notes.sh and
# create-release.sh. Stand-ins for `mise` (git-cliff) and `gh` record their
# calls; the action must run each script with the env it reads.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
action_dir="${repo_root}/actions/release-publish"
action="${action_dir}/action.yml"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

fail() {
    echo "error: $*" >&2
    exit 1
}

for script in release-notes create-release; do
    # shellcheck disable=SC2016 # Literal text in action.yml.
    grep -Fxq "      run: bash \"\${GITHUB_ACTION_PATH}/${script}.sh\"" "${action}" ||
        fail "${action} no longer runs ${script}.sh; update this test"
done
for variable in TAG REPO EXTRA ASSETS GH_TOKEN; do
    grep -Eq "^        ${variable}: " "${action}" || fail "${action} does not pass ${variable}"
done

mkdir -p "${tmp_dir}/bin"
cat >"${tmp_dir}/bin/mise" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"${CALLS}"
echo "### Features"
EOF
cat >"${tmp_dir}/bin/gh" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do printf '[%s]' "${arg}"; done >>"${CALLS}"
echo >>"${CALLS}"
EOF
chmod +x "${tmp_dir}/bin/mise" "${tmp_dir}/bin/gh"

# run SCRIPT NAME=value...: runs a script in a fresh case directory ($case_dir).
run() {
    local script="$1"
    shift
    case_dir="$(mktemp -d "${tmp_dir}/case.XXXXXX")"
    env PATH="${tmp_dir}/bin:${PATH}" \
        CALLS="${case_dir}/calls" \
        RELEASE_NOTES_FILE="${case_dir}/notes.md" \
        TAG="v1.2.0" \
        REPO="owner/repo" \
        EXTRA="" \
        ASSETS="" \
        "$@" \
        bash "${action_dir}/${script}.sh" >"${case_dir}/log" 2>&1
}

# --- release-notes.sh ---------------------------------------------------------

run release-notes || fail "notes without a preset failed: $(cat "${case_dir}/log")"
grep -Fxq "exec -- git-cliff --latest --strip all" "${case_dir}/calls" || fail "git-cliff was not run for the latest tag"
[ "$(cat "${case_dir}/notes.md")" = "### Features" ] || fail "notes without a preset must be git-cliff's output only"

run release-notes EXTRA=log-sh || fail "notes with the log-sh preset failed: $(cat "${case_dir}/log")"
head -n1 "${case_dir}/notes.md" | grep -Fxq "### Features" || fail "the preset must follow git-cliff's output"
# shellcheck disable=SC2016 # Backticks are Markdown.
for line in \
    '## log.sh distribution' \
    'This release includes a vendorable copy of `log.sh`. See [docs/logging.md](https://github.com/owner/repo/blob/v1.2.0/docs/logging.md#consuming-logsh-from-other-repositories) for the consumption snippet.' \
    'curl -fsSL https://github.com/owner/repo/releases/download/v1.2.0/log.sh -o scripts/lib/log.sh' \
    'curl -fsSL https://github.com/owner/repo/releases/download/v1.2.0/log.sh.sha256 -o scripts/lib/log.sh.sha256' \
    '( cd scripts/lib && sha256sum -c log.sh.sha256 )' \
    'gh attestation verify ./log.sh --repo owner/repo' \
    'gh attestation verify ./log-sh-v1.2.0.tar.gz --repo owner/repo'; do
    grep -Fxq -- "${line}" "${case_dir}/notes.md" || fail "log-sh notes lack: ${line}"
done
[ "$(grep -c '^```' "${case_dir}/notes.md")" -eq 4 ] || fail "log-sh notes must hold two closed code blocks"

run release-notes EXTRA=unknown && fail "an unknown preset must fail"
grep -Fxq "Unknown extra-notes preset: unknown" "${case_dir}/log" || fail "an unknown preset must be named"

# --- create-release.sh --------------------------------------------------------

common="[release][create][v1.2.0][--repo][owner/repo][--title][v1.2.0][--notes-file]"

run create-release || fail "a notes-only release failed: $(cat "${case_dir}/log")"
[ "$(cat "${case_dir}/calls")" = "${common}[${case_dir}/notes.md]" ] ||
    fail "unexpected notes-only release call: $(cat "${case_dir}/calls")"

run create-release ASSETS=$'dist/log.sh\n  \n  dist/log sh.sha256  \n\n' ||
    fail "a release with assets failed: $(cat "${case_dir}/log")"
[ "$(cat "${case_dir}/calls")" = "${common}[${case_dir}/notes.md][dist/log.sh][dist/log sh.sha256]" ] ||
    fail "assets must be trimmed, blank lines dropped and spaces kept: $(cat "${case_dir}/calls")"

echo "✓ release-publish: release notes, presets and single-shot releases with and without assets."

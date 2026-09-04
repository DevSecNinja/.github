#!/usr/bin/env bash
# shellcheck disable=SC2016 # GitHub expressions and Bash expansions are test literals.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="${repo_root}/.github/workflows/release-please.yml"
caller="${repo_root}/.github/workflows/release-please-caller.yml"
template="${repo_root}/workflow-templates/release-please.yml"
onboarding="${repo_root}/docs/release-please-onboarding.md"
triggers="${repo_root}/docs/workflow-trigger-conventions.md"
architecture="${repo_root}/docs/architecture.md"

fail() {
    echo "error: $*" >&2
    exit 1
}

assert_contains() {
    local file="$1"
    local text="$2"
    grep -Fq -- "${text}" "${file}" || fail "${file} must contain: ${text}"
}

assert_matches_across_lines() {
    local file="$1"
    local pattern="$2"
    grep -zEq -- "${pattern}" "${file}" ||
        fail "${file} must match: ${pattern}"
}

app_id_contract="$(sed -n '/^      app-id:/,/^    secrets:/p' "${workflow}")"
private_key_contract="$(sed -n '/^      app-private-key:/,/^    outputs:/p' "${workflow}")"
job_permissions="$(sed -n '/^    permissions:/,/^    outputs:/p' "${workflow}")"
preflight_step="$(sed -n '/      - name: Validate GitHub App credentials/,/      - name: Generate App token/p' "${workflow}")"
token_step="$(sed -n '/      - name: Generate App token/,/      - name: Run release-please/p' "${workflow}")"

grep -Fq "required: true" <<<"${app_id_contract}" ||
    fail "app-id must be required"
grep -Fq "default:" <<<"${app_id_contract}" &&
    fail "app-id must not have a default"
grep -Fq "required: true" <<<"${private_key_contract}" ||
    fail "app-private-key must be required"

assert_contains "${workflow}" "- name: Validate GitHub App credentials"
assert_contains "${workflow}" '${APP_ID//[[:space:]]/}'
assert_contains "${workflow}" '${APP_PRIVATE_KEY//[[:space:]]/}'
assert_contains "${workflow}" "::error title=GitHub App authentication required::"
assert_contains "${workflow}" "docs/release-please-onboarding.md"
grep -Fq "continue-on-error:" <<<"${preflight_step}" &&
    fail "credential preflight must fail the job"

preflight_line="$(grep -nF -- "- name: Validate GitHub App credentials" "${workflow}" | cut -d: -f1)"
token_line="$(grep -nF -- "- name: Generate App token" "${workflow}" | cut -d: -f1)"
release_line="$(grep -nF -- "- name: Run release-please" "${workflow}" | cut -d: -f1)"
((preflight_line < token_line && token_line < release_line)) ||
    fail "preflight must run before token creation and release-please"

blank_value=$' \t\n'
[[ -z "${blank_value//[[:space:]]/}" ]] ||
    fail "whitespace-only credentials must be rejected"
nonblank_value="  credential  "
[[ -n "${nonblank_value//[[:space:]]/}" ]] ||
    fail "non-empty credentials must pass preflight"

grep -Eq '^[[:space:]]+if:' <<<"${token_step}" &&
    fail "Generate App token must be unconditional"
assert_contains "${workflow}" 'token: ${{ steps.app-token.outputs.token }}'
grep -Eq '^[[:space:]]+token:.*(GITHUB_TOKEN|\|\|)' "${workflow}" &&
    fail "release-please token path must not contain a GITHUB_TOKEN fallback"
assert_contains "${workflow}" "permission-contents: write"
assert_contains "${workflow}" "permission-pull-requests: write"
grep -Fq "issues:" <<<"${job_permissions}" &&
    fail "release job must not request issues permission"

for file in "${caller}" "${template}"; do
    assert_contains "${file}" 'app-id: ${{ vars.RELEASE_PLEASE_APP_ID }}'
    assert_contains "${file}" 'app-private-key: ${{ secrets.RELEASE_PLEASE_APP_PRIVATE_KEY }}'
done

for file in "${onboarding}" "${triggers}"; do
    assert_contains "${file}" "Direct Release Please GitHub Release"
    assert_contains "${file}" "Split tag publisher"
    assert_contains "${file}" "skip-github-release: true"
    assert_matches_across_lines "${file}" \
        'still[[:space:]]+creates[[:space:]]+the[[:space:]]+(version[[:space:]]+)?tag'
    assert_contains "${file}" "default for simple consumers"
    assert_matches_across_lines "${file}" \
        'Allow GitHub Actions to create and approve pull[[:space:]]+requests'
done

assert_contains "${onboarding}" '"skip-github-release": false'
assert_contains "${triggers}" "skip-github-release: false"
assert_contains "${architecture}" "skip-github-release: false"
assert_contains "${architecture}" "skip-github-release: true"

echo "Release Please App authentication contract is enforced."

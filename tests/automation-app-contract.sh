#!/usr/bin/env bash
# shellcheck disable=SC2016 # GitHub expressions are test literals.
#
# Contract test for the single GitHub App ("DevSecNinja Automation") used by
# every central workflow that opens PRs (ADR 0011, docs/automation-app.md).
#
# config-sync, release-please and apm-sync must resolve App credentials the
# same way — explicit `app-id` / `app-private-key`, else the caller repo's
# AUTOMATION_APP_ID variable and AUTOMATION_APP_PRIVATE_KEY secret — read them
# through the provisioning environment without creating deployments, and mint
# a token limited to the calling repository with Contents + Pull requests
# write only. config-sync and apm-sync fall back to GITHUB_TOKEN with a
# warning; release-please fails closed.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflows="${repo_root}/.github/workflows"
reusables=(config-sync release-please apm-sync)
fallback_reusables=(config-sync apm-sync)
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

fail() {
    echo "error: $*" >&2
    exit 1
}

assert_contains() {
    local file="$1"
    local text="$2"
    grep -Fq -- "${text}" "${file}" || fail "${file#"${repo_root}/"} must contain: ${text}"
}

# Block of a workflow_call input or secret: from its key to the next key at the
# same indentation.
declaration() {
    local file="$1"
    local name="$2"
    awk -v name="${name}" '
        $0 ~ "^      " name ":[[:space:]]*$" { found = 1; print; next }
        found && ($0 ~ /^      [A-Za-z_-]+:/ || $0 ~ /^    [a-z]/ || $0 ~ /^[a-z]/) { exit }
        found { print }
    ' "${file}"
}

# The `with:` block of the create-github-app-token step(s).
token_blocks() {
    awk '
        /uses: actions\/create-github-app-token@/ { in_step = 1; next }
        in_step && /^        with:/ { in_with = 1; next }
        in_with {
            if ($0 !~ /^          /) { in_step = 0; in_with = 0; next }
            print
        }
    ' "$1"
}

# Run block (de-indented) of the step named $2.
run_block() {
    awk -v step="$2" '
        $0 == "      - name: " step { in_step = 1; next }
        in_step && /^        run: [|]/ { in_run = 1; next }
        in_run {
            if ($0 !~ /^          / && $0 !~ /^[[:space:]]*$/) exit
            sub(/^          /, "")
            print
        }
    ' "$1"
}

for name in "${reusables[@]}"; do
    file="${workflows}/${name}.yml"

    app_id="$(declaration "${file}" app-id)"
    grep -Fq 'required: false' <<<"${app_id}" || fail "${name}: app-id must be optional"
    grep -Fq 'default: ""' <<<"${app_id}" || fail "${name}: app-id must default to empty (AUTOMATION_APP_ID)"
    environment_input="$(declaration "${file}" app-environment)"
    grep -Fq 'default: production' <<<"${environment_input}" ||
        fail "${name}: app-environment must default to production (the dotfiles provisioning default)"
    for secret in AUTOMATION_APP_PRIVATE_KEY app-private-key; do
        block="$(declaration "${file}" "${secret}")"
        [ -n "${block}" ] || fail "${name}: secret ${secret} must be declared"
        grep -Fq 'required: false' <<<"${block}" || fail "${name}: secret ${secret} must be optional"
    done

    assert_contains "${file}" 'name: ${{ inputs.app-environment }}'
    assert_contains "${file}" 'deployment: false'
    assert_contains "${file}" 'APP_ID: ${{ inputs.app-id || vars.AUTOMATION_APP_ID }}'
    assert_contains "${file}" 'APP_PRIVATE_KEY: ${{ secrets.app-private-key || secrets.AUTOMATION_APP_PRIVATE_KEY }}'

    token="$(token_blocks "${file}")"
    [ -n "${token}" ] || fail "${name}: no create-github-app-token step"
    grep -Fxq '          client-id: ${{ inputs.app-id || vars.AUTOMATION_APP_ID }}' <<<"${token}" ||
        fail "${name}: the token step must use client-id with the resolved App ID"
    grep -Fxq '          private-key: ${{ secrets.app-private-key || secrets.AUTOMATION_APP_PRIVATE_KEY }}' <<<"${token}" ||
        fail "${name}: the token step must use the resolved private key"
    grep -Fxq '          repositories: ${{ github.repository }}' <<<"${token}" ||
        fail "${name}: the token must be limited to the calling repository"
    permissions="$(grep -E '^          permission-' <<<"${token}" | sed 's/^ *//' | sort | tr '\n' ' ')"
    [ "${permissions}" = "permission-contents: write permission-pull-requests: write " ] ||
        fail "${name}: the token must request exactly Contents and Pull requests write (got: ${permissions})"
done

# config-sync no longer needs (or may request) issues: labels are created with
# the Pull requests permission, and requesting more than older callers grant
# fails them with startup_failure.
job_permissions="$(sed -n '/^    permissions:/,/^    steps:/p' "${workflows}/config-sync.yml")"
grep -Eq '^[[:space:]]+issues:' <<<"${job_permissions}" &&
    fail "config-sync must not request issues permission"

# No workflow uses the deprecated `app-id` token input or requests permissions
# the App must never have.
for file in "${workflows}"/*.yml; do
    token="$(token_blocks "${file}")"
    [ -n "${token}" ] || continue
    grep -Eq '^          app-id:' <<<"${token}" &&
        fail "${file#"${repo_root}/"}: use client-id instead of the deprecated app-id input"
    grep -Eq '^          permission-(administration|workflows|issues|secrets|actions):' <<<"${token}" &&
        fail "${file#"${repo_root}/"}: the App token must not request administration, workflows, issues, secrets or actions"
done

# Fallback reusables: resolution script behaviour.
for name in "${fallback_reusables[@]}"; do
    file="${workflows}/${name}.yml"
    script="${tmp_dir}/${name}-resolve.sh"
    run_block "${file}" "Resolve GitHub App credentials" >"${script}"
    [ -s "${script}" ] || fail "${name}: could not extract 'Resolve GitHub App credentials'"

    resolve() {
        local output="${tmp_dir}/output"
        : >"${output}"
        APP_ID="$1" APP_PRIVATE_KEY="$2" GITHUB_OUTPUT="${output}" bash "${script}" >"${tmp_dir}/log" 2>&1 ||
            fail "${name}: the resolve step must never fail the job"
        cat "${output}"
    }

    [ "$(resolve "3563533" "-----BEGIN KEY-----")" = "available=true" ] ||
        fail "${name}: both credentials must select the App"
    grep -Fq '::warning' "${tmp_dir}/log" && fail "${name}: no warning expected when the App is used"

    [ "$(resolve "" "")" = "available=false" ] || fail "${name}: missing credentials must fall back"
    grep -Fq '::warning title=' "${tmp_dir}/log" || fail "${name}: the fallback must warn"
    grep -Fq 'Allow GitHub Actions to create and approve pull requests' "${tmp_dir}/log" ||
        fail "${name}: the fallback warning must name the Actions setting GITHUB_TOKEN depends on"

    [ "$(resolve "3563533" "  ")" = "available=false" ] || fail "${name}: a blank key must fall back"
    grep -Fq 'does not pass the AUTOMATION_APP_PRIVATE_KEY secret' "${tmp_dir}/log" ||
        fail "${name}: an App ID without a key must explain that the caller does not pass the secret"

    [ "$(resolve " " "-----BEGIN KEY-----")" = "available=false" ] || fail "${name}: a blank App ID must fall back"
    grep -Fq 'neither the AUTOMATION_APP_ID variable nor the app-id input' "${tmp_dir}/log" ||
        fail "${name}: a key without an App ID must say where the ID comes from"

    assert_contains "${file}" "if: steps.app.outputs.available == 'true'"
    assert_contains "${file}" '${{ steps.app-token.outputs.token || github.token }}'
done

# release-please fails closed instead.
script="${tmp_dir}/release-please-validate.sh"
run_block "${workflows}/release-please.yml" "Validate GitHub App credentials" >"${script}"
[ -s "${script}" ] || fail "release-please: could not extract 'Validate GitHub App credentials'"
APP_ID="3563533" APP_PRIVATE_KEY="-----BEGIN KEY-----" bash "${script}" >/dev/null 2>&1 ||
    fail "release-please: both credentials must pass validation"
for pair in ":" "3563533:" ":-----BEGIN KEY-----" " : "; do
    if APP_ID="${pair%%:*}" APP_PRIVATE_KEY="${pair#*:}" bash "${script}" >"${tmp_dir}/log" 2>&1; then
        fail "release-please: incomplete credentials ('${pair}') must fail the job"
    fi
done
APP_ID="3563533" APP_PRIVATE_KEY="" bash "${script}" >"${tmp_dir}/log" 2>&1 || true
grep -Fq 'does not pass the AUTOMATION_APP_PRIVATE_KEY secret' "${tmp_dir}/log" ||
    fail "release-please: an App ID without a key must explain that the caller does not pass the secret"

# The local APM materializer reads the standard names, falling back to the
# legacy RELEASE_PLEASE_APP_* names of the same App during the transition.
materialize="${workflows}/apm-materialize.yml"
assert_contains "${materialize}" 'client-id: ${{ vars.AUTOMATION_APP_ID || vars.RELEASE_PLEASE_APP_ID }}'
assert_contains "${materialize}" 'private-key: ${{ secrets.AUTOMATION_APP_PRIVATE_KEY || secrets.RELEASE_PLEASE_APP_PRIVATE_KEY }}'

assert_contains "${repo_root}/docs/automation-app.md" 'AUTOMATION_APP_PRIVATE_KEY: ${{ secrets.AUTOMATION_APP_PRIVATE_KEY }}'

echo "✓ Automation App: ${#reusables[@]} reusable workflows share one credential contract; fallbacks and fail-closed paths behave."

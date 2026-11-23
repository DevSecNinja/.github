#!/usr/bin/env bash
# shellcheck disable=SC2016 # GitHub expressions are test literals.
#
# Contract for the optional test-report step of .github/workflows/pages.yml
# (inputs test-report-paths and test-report-title).

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="${repo_root}/.github/workflows/pages.yml"
validation_script="${repo_root}/scripts/pages/validate-inputs.sh"
architecture="${repo_root}/docs/architecture.md"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

fail() {
    echo "error: $*" >&2
    exit 1
}

# The new inputs are off by default, so existing callers are unchanged.
grep -A8 -E '^      test-report-paths:' "${workflow}" | grep -Fq 'default: ""' ||
    fail "test-report-paths must default to an empty string"
grep -A4 -E '^      test-report-title:' "${workflow}" | grep -Fq 'default: "Tests"' ||
    fail "test-report-title must default to Tests"

test_job="$(sed -n '/^  test:$/,/^  deploy:$/p' "${workflow}")"
for expected in \
    'if: ${{ !cancelled() && inputs.test-report-paths != '"''"' }}' \
    'ref: ${{ job.workflow_sha }}' \
    'actions/test-report/' \
    'id: tests' \
    "REPORT_IF_NO_FILES: \${{ steps.tests.outcome == 'skipped' && 'ignore' || 'warn' }}" \
    'REPORT_PATHS: ${{ inputs.test-report-paths }}' \
    'REPORT_TITLE: ${{ inputs.test-report-title }}' \
    'run: bash "${RUNNER_TEMP}/devsecninja-test-report/actions/test-report/report.sh"'; do
    grep -Fq -- "${expected}" <<<"${test_job}" || fail "pages.yml test job must contain: ${expected}"
done
grep -Fq '`test-report-paths`' "${architecture}" || fail "docs/architecture.md must document test-report-paths"

validate() {
    NODE_VERSION="24" WRANGLER_VERSION="" INSTALL_COMMAND="" TEST_SETUP_COMMAND="" \
        TEST_COMMAND="$1" TEST_REPORT_PATHS="$2" BUILD_COMMAND="" BUILD_GITHUB_TOKEN="false" \
        ARTIFACT_PATH="." ARTIFACT_NAME="" CLOUDFLARE_PREVIEW="false" CLOUDFLARE_PRODUCTION="false" \
        CLOUDFLARE_ACCEPTANCE="false" CLOUDFLARE_CUSTOM_DOMAIN="" CLOUDFLARE_MANAGE_DNS="false" \
        CLOUDFLARE_DNS_ZONE="" CONFIGURED_PROJECT_NAME="" bash "${validation_script}"
}
validate "npm test" "test-results.xml" >/dev/null || fail "test-report-paths with test-command must pass"
validate "" "" >/dev/null || fail "no tests and no report must pass"
if validate "" "test-results.xml" >"${tmp_dir}/out" 2>&1; then
    fail "test-report-paths without test-command must fail"
fi
grep -Fq "test-report-paths requires test-command" "${tmp_dir}/out" || fail "missing validation message"

# Run the step the way the job does: the action copied to RUNNER_TEMP, the
# report env from pages.yml, and the caller's checkout as the workspace.
runner_temp="${tmp_dir}/runner"
workspace="${tmp_dir}/workspace"
mkdir -p "${runner_temp}/devsecninja-test-report/actions" "${workspace}"
cp -R "${repo_root}/actions/test-report" "${runner_temp}/devsecninja-test-report/actions/"
cat >"${workspace}/test-results.xml" <<'XML'
<testsuite name="unit"><testcase name="adds"/><testcase name="skips"><skipped/></testcase></testsuite>
XML
step="$(grep -A12 -F -- '- name: Publish test results' <<<"${test_job}")"
for variable in REPORT_PATHS REPORT_TITLE REPORT_MAX_FAILURES REPORT_IF_NO_FILES; do
    grep -Eq "^          ${variable}: " <<<"${step}" || fail "Publish test results must set ${variable}"
done
(
    cd "${workspace}"
    GITHUB_WORKSPACE="${workspace}" GITHUB_STEP_SUMMARY="${tmp_dir}/summary.md" GITHUB_OUTPUT="${tmp_dir}/output" \
        RUNNER_TEMP="${runner_temp}" REPORT_PATHS="test-results.xml" REPORT_TITLE="Tests" \
        REPORT_MAX_FAILURES="50" REPORT_IF_NO_FILES="warn" \
        bash "${runner_temp}/devsecninja-test-report/actions/test-report/report.sh" >/dev/null
)
grep -Fq "Tests: 1 passed, 0 failed, 1 skipped" "${tmp_dir}/summary.md" || fail "the report step must write the summary"

echo "pages test-report contract passed"

#!/usr/bin/env bash
# shellcheck disable=SC2016 # GitHub expressions and Bash expansions are test literals.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="${repo_root}/.github/workflows/pages.yml"
template="${repo_root}/workflow-templates/pages.yml"
architecture="${repo_root}/docs/architecture.md"
fixtures="${repo_root}/tests/fixtures/cloudflare-pages-domains"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

fail() {
    echo "error: $*" >&2
    exit 1
}

assert_contains() {
    local file="$1"
    local text="$2"
    grep -Fq -- "${text}" "${file}" || fail "${file} must contain: ${text}"
}

assert_not_contains() {
    local file="$1"
    local text="$2"
    if grep -Fq -- "${text}" "${file}"; then
        fail "${file} must not contain: ${text}"
    fi
}

extract_run_step() {
    local step_name="$1"
    local output_file="$2"
    awk -v target="${step_name}" '
        $0 == "      - name: " target {
            in_step = 1
            next
        }
        in_step && $0 == "        run: |-" {
            in_run = 1
            next
        }
        in_run {
            if ($0 ~ /^      - name:/ || $0 ~ /^  [[:alnum:]_-]+:/) {
                exit
            }
            sub(/^          /, "")
            print
        }
    ' "${workflow}" >"${output_file}"
    [ -s "${output_file}" ] || fail "could not extract run block for ${step_name}"
}

custom_domain_contract="$(
    sed -n '/^      cloudflare-custom-domain:/,/^      cloudflare-acceptance:/p' "${workflow}"
)"
grep -Fq 'default: ""' <<<"${custom_domain_contract}" ||
    fail "cloudflare-custom-domain must default to an empty string"
grep -Fq "production Cloudflare Pages" <<<"${custom_domain_contract}" ||
    fail "cloudflare-custom-domain must be documented as production-only"

assert_contains "${workflow}" "cloudflare-custom-domain requires cloudflare-production: true."
assert_contains "${workflow}" "cloudflare-project-name is required when cloudflare-custom-domain is set."
assert_contains "${workflow}" "cloudflare-custom-domain requires CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID."
assert_contains "${workflow}" "needs.detect-cloudflare.outputs.deploy-production == 'true'"
assert_contains "${workflow}" "inputs.cloudflare-custom-domain != ''"
assert_contains "${workflow}" "needs.deploy-cloudflare.result == 'success'"
assert_contains "${workflow}" 'cloudflare-pages-domain-${{ needs.detect-cloudflare.outputs.project-name }}-${{ inputs.cloudflare-custom-domain }}'
assert_contains "${workflow}" 'PROJECT_NAME: ${{ needs.detect-cloudflare.outputs.project-name }}'
assert_contains "${workflow}" 'domain_url="${api_base}/domains/${CUSTOM_DOMAIN}"'
assert_contains "${workflow}" 'request POST "${api_base}/domains"'
assert_contains "${workflow}" "'{name: \$name}'"
assert_contains "${workflow}" "cloudflare-custom-domain-status:"
assert_contains "${workflow}" "cloudflare-custom-domain-dns-target:"
assert_contains "${workflow}" '--header "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}"'
assert_not_contains "${workflow}" "/dns_records"
assert_not_contains "${workflow}" "curl --verbose"
assert_not_contains "${workflow}" "curl -v"

assert_contains "${template}" '# cloudflare-custom-domain: "www.example.com"'
assert_contains "${architecture}" "net-worth-calculator-xn8.pages.dev"
assert_contains "${architecture}" "Keep the previous host or DNS value available as a rollback path"

validation_script="${tmp_dir}/validate.sh"
registration_script="${tmp_dir}/register.sh"
extract_run_step "Validate tool versions" "${validation_script}"
extract_run_step "Register Cloudflare Pages custom domain" "${registration_script}"

run_validation() {
    local domain="$1"
    local production="${2:-true}"
    local project="${3-example-project}"
    local wrangler="${4-4.123.0}"

    NODE_VERSION="" \
        WRANGLER_VERSION="${wrangler}" \
        INSTALL_COMMAND="" \
        TEST_SETUP_COMMAND="" \
        TEST_COMMAND="" \
        BUILD_COMMAND="" \
        ARTIFACT_NAME="" \
        CLOUDFLARE_PREVIEW="false" \
        CLOUDFLARE_PRODUCTION="${production}" \
        CLOUDFLARE_ACCEPTANCE="false" \
        CLOUDFLARE_CUSTOM_DOMAIN="${domain}" \
        CONFIGURED_PROJECT_NAME="${project}" \
        bash "${validation_script}"
}

run_validation "www.example.com" >/dev/null ||
    fail "a valid lowercase FQDN must pass validation"

for invalid_domain in \
    "example" \
    "HTTPS://example.com" \
    "example.com/path" \
    "example.com:443" \
    "*.example.com" \
    "example.com." \
    "bad_label.example.com" \
    "-bad.example.com" \
    "bad-.example.com" \
    "$(printf 'a%.0s' {1..64}).example.com"; do
    if run_validation "${invalid_domain}" >/dev/null 2>&1; then
        fail "invalid custom domain passed validation: ${invalid_domain}"
    fi
done

if run_validation "www.example.com" "false" >/dev/null 2>&1; then
    fail "custom-domain validation must require Cloudflare production"
fi
if run_validation "www.example.com" "true" "" >/dev/null 2>&1; then
    fail "custom-domain validation must require an explicit project name"
fi
if run_validation "www.example.com" "true" "example-project" "" >/dev/null 2>&1; then
    fail "custom-domain validation must require Wrangler"
fi

mkdir -p "${tmp_dir}/bin"
cat >"${tmp_dir}/bin/curl" <<'MOCK_CURL'
#!/usr/bin/env bash
set -euo pipefail

method="GET"
output_file=""
data_file=""
url=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --request)
            method="$2"
            shift 2
            ;;
        --output)
            output_file="$2"
            shift 2
            ;;
        --data-binary)
            data_file="${2#@}"
            shift 2
            ;;
        --header | --connect-timeout | --max-time | --retry | --write-out)
            shift 2
            ;;
        --silent | --show-error | --retry-all-errors)
            shift
            ;;
        http*)
            url="$1"
            shift
            ;;
        *)
            echo "unexpected curl argument: $1" >&2
            exit 2
            ;;
    esac
done

if [ "${MOCK_TRANSPORT_FAILURE:-false}" = "true" ]; then
    exit 7
fi

printf '%s %s\n' "${method}" "${url}" >>"${MOCK_CURL_LOG}"
if [ -n "${data_file}" ]; then
    printf 'BODY %s\n' "$(cat "${data_file}")" >>"${MOCK_CURL_LOG}"
fi

case "${method} ${url}" in
    "GET "*"domains/"*)
        cp "${MOCK_DOMAIN_GET_FIXTURE}" "${output_file}"
        printf '%s' "${MOCK_DOMAIN_GET_STATUS}"
        ;;
    "POST "*"domains")
        cp "${MOCK_DOMAIN_POST_FIXTURE}" "${output_file}"
        printf '%s' "${MOCK_DOMAIN_POST_STATUS}"
        ;;
    "GET "*"/pages/projects/"*)
        cp "${MOCK_PROJECT_FIXTURE}" "${output_file}"
        printf '200'
        ;;
    *)
        echo "unexpected request: ${method} ${url}" >&2
        exit 2
        ;;
esac
MOCK_CURL
chmod +x "${tmp_dir}/bin/curl"

run_registration() {
    local case_name="$1"
    local get_status="$2"
    local get_fixture="$3"
    local transport_failure="${4:-false}"
    local case_dir="${tmp_dir}/${case_name}"
    mkdir -p "${case_dir}"

    if ! env PATH="${tmp_dir}/bin:${PATH}" \
        MOCK_CURL_LOG="${case_dir}/curl.log" \
        MOCK_DOMAIN_GET_STATUS="${get_status}" \
        MOCK_DOMAIN_GET_FIXTURE="${get_fixture}" \
        MOCK_DOMAIN_POST_STATUS="200" \
        MOCK_DOMAIN_POST_FIXTURE="${fixtures}/domain-created.json" \
        MOCK_PROJECT_FIXTURE="${fixtures}/project.json" \
        MOCK_TRANSPORT_FAILURE="${transport_failure}" \
        CLOUDFLARE_ACCOUNT_ID="test-account" \
        CLOUDFLARE_API_TOKEN="super-secret-token" \
        CUSTOM_DOMAIN="net-worth.ravensberg.org" \
        PROJECT_NAME="net-worth-calculator" \
        GITHUB_OUTPUT="${case_dir}/output" \
        GITHUB_STEP_SUMMARY="${case_dir}/summary" \
        bash "${registration_script}" \
        >"${case_dir}/stdout" 2>"${case_dir}/stderr"; then
        cat "${case_dir}/stderr" >&2
        return 1
    fi
}

run_registration "existing" "200" "${fixtures}/domain-active.json"
existing_log="${tmp_dir}/existing/curl.log"
[ "$(grep -c '^GET ' "${existing_log}")" -eq 2 ] ||
    fail "existing domain path must perform domain and project GET requests"
if grep -q '^POST ' "${existing_log}"; then
    fail "an existing custom domain must not be registered again"
fi
assert_contains "${tmp_dir}/existing/output" "status=active"
assert_contains "${tmp_dir}/existing/output" "dns-target=net-worth-calculator-xn8.pages.dev"
assert_contains "${tmp_dir}/existing/stdout" "this workflow did not change DNS"

run_registration "absent" "404" "${fixtures}/domain-not-found.json"
absent_log="${tmp_dir}/absent/curl.log"
[ "$(sed -n '1p' "${absent_log}")" = \
    "GET https://api.cloudflare.com/client/v4/accounts/test-account/pages/projects/net-worth-calculator/domains/net-worth.ravensberg.org" ] ||
    fail "the exact custom domain must be queried first"
[ "$(sed -n '2p' "${absent_log}")" = \
    "POST https://api.cloudflare.com/client/v4/accounts/test-account/pages/projects/net-worth-calculator/domains" ] ||
    fail "an absent domain must be registered after the GET"
assert_contains "${absent_log}" 'BODY {"name":"net-worth.ravensberg.org"}'
assert_contains "${tmp_dir}/absent/output" "status=initializing"
assert_contains "${tmp_dir}/absent/summary" "net-worth-calculator-xn8.pages.dev"
assert_not_contains "${absent_log}" "/dns_records"

if run_registration "api-error" "500" "${fixtures}/api-error.json" >/dev/null 2>&1; then
    fail "an unsuccessful Cloudflare API response must fail closed"
fi
if run_registration "transport-error" "000" "${fixtures}/api-error.json" "true" >/dev/null 2>&1; then
    fail "a curl transport failure must fail closed"
fi

for output_file in \
    "${tmp_dir}/existing/stdout" \
    "${tmp_dir}/existing/stderr" \
    "${tmp_dir}/existing/output" \
    "${tmp_dir}/existing/summary" \
    "${tmp_dir}/absent/stdout" \
    "${tmp_dir}/absent/stderr"; do
    assert_not_contains "${output_file}" "super-secret-token"
done

echo "Cloudflare Pages custom-domain contract is enforced."

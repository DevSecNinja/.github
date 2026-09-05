#!/usr/bin/env bash
# shellcheck disable=SC2016 # GitHub expressions and Bash expansions are test literals.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="${repo_root}/.github/workflows/pages.yml"
template="${repo_root}/workflow-templates/pages.yml"
architecture="${repo_root}/docs/architecture.md"
adr="${repo_root}/docs/design-decisions/0009-pages-managed-dns-cutover.md"
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

input_contract="$(
    sed -n '/^      cloudflare-custom-domain:/,/^      cloudflare-acceptance:/p' "${workflow}"
)"
grep -Fq 'cloudflare-manage-dns:' <<<"${input_contract}" ||
    fail "cloudflare-manage-dns input is missing"
grep -A6 -F 'cloudflare-manage-dns:' <<<"${input_contract}" | grep -Fq 'default: false' ||
    fail "cloudflare-manage-dns must default to false"
grep -A6 -F 'cloudflare-dns-zone:' <<<"${input_contract}" | grep -Fq 'default: ""' ||
    fail "cloudflare-dns-zone must default to an empty string"
grep -A6 -F 'cloudflare-dns-proxied:' <<<"${input_contract}" | grep -Fq 'default: true' ||
    fail "cloudflare-dns-proxied must default to true"

assert_contains "${workflow}" "cloudflare-manage-dns requires cloudflare-production: true."
assert_contains "${workflow}" "cloudflare-manage-dns requires cloudflare-custom-domain."
assert_contains "${workflow}" "cloudflare-manage-dns requires cloudflare-dns-zone."
assert_contains "${workflow}" "cloudflare-custom-domain must equal cloudflare-dns-zone or be its subdomain."
assert_contains "${workflow}" "needs.detect-cloudflare.outputs.deploy-production == 'true'"
assert_contains "${workflow}" "needs.deploy-cloudflare.result"
assert_contains "${workflow}" "== 'success'"
assert_contains "${workflow}" 'cloudflare-pages-domain-${{ needs.detect-cloudflare.outputs.project-name }}-${{ inputs.cloudflare-custom-domain }}'
assert_contains "${workflow}" 'PROJECT_NAME: ${{ needs.detect-cloudflare.outputs.project-name }}'
assert_contains "${workflow}" 'cloudflare-custom-domain-dns-action:'
assert_contains "${workflow}" 'dns_action="unmanaged"'
assert_contains "${workflow}" "A conflicting DNS record already exists"
assert_contains "${workflow}" '--header "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}"'
assert_not_contains "${workflow}" "curl --verbose"
assert_not_contains "${workflow}" "curl -v"

assert_contains "${template}" '# cloudflare-manage-dns: true'
assert_contains "${architecture}" "net-worth-calculator-xn8.pages.dev"
assert_contains "${architecture}" "Zone Read"
assert_contains "${adr}" "Wrangler"

validation_script="${tmp_dir}/validate.sh"
registration_script="${tmp_dir}/register.sh"
extract_run_step "Validate tool versions" "${validation_script}"
extract_run_step "Register Cloudflare Pages custom domain" "${registration_script}"

run_validation() {
    local domain="${1:-}"
    local production="${2:-true}"
    local project="${3-example-project}"
    local wrangler="${4-4.128.0}"
    local manage_dns="${5:-false}"
    local dns_zone="${6:-}"

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
        CLOUDFLARE_MANAGE_DNS="${manage_dns}" \
        CLOUDFLARE_DNS_ZONE="${dns_zone}" \
        CONFIGURED_PROJECT_NAME="${project}" \
        bash "${validation_script}"
}

run_validation "www.example.com" >/dev/null ||
    fail "a valid custom domain with DNS disabled must pass"
run_validation "www.example.com" "true" "example-project" "4.128.0" "true" "example.com" >/dev/null ||
    fail "a valid managed DNS configuration must pass"
run_validation "example.com" "true" "example-project" "4.128.0" "true" "example.com" >/dev/null ||
    fail "the zone apex must be accepted as its own custom domain"

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

if run_validation "" "true" "example-project" "4.128.0" "true" "example.com" >/dev/null 2>&1; then
    fail "managed DNS must require a custom domain"
fi
if run_validation "www.example.com" "false" "example-project" "4.128.0" "true" "example.com" >/dev/null 2>&1; then
    fail "managed DNS must require Cloudflare production"
fi
if run_validation "www.example.com" "true" "example-project" "4.128.0" "true" "" >/dev/null 2>&1; then
    fail "managed DNS must require a zone"
fi
if run_validation "www.example.com" "true" "example-project" "4.128.0" "true" "ample.com" >/dev/null 2>&1; then
    fail "zone containment must enforce a DNS-label boundary"
fi
if run_validation "www.example.com" "true" "example-project" "4.128.0" "true" "EXAMPLE.com" >/dev/null 2>&1; then
    fail "the DNS zone must be normalized lowercase"
fi
if run_validation "www.example.com" "true" "" >/dev/null 2>&1; then
    fail "custom-domain validation must require an explicit project name"
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
        count=0
        [ ! -f "${MOCK_DOMAIN_COUNT_FILE}" ] || count="$(cat "${MOCK_DOMAIN_COUNT_FILE}")"
        count=$((count + 1))
        printf '%s' "${count}" >"${MOCK_DOMAIN_COUNT_FILE}"
        if [ "${count}" -eq 1 ]; then
            cp "${MOCK_DOMAIN_GET_FIXTURE}" "${output_file}"
            printf '%s' "${MOCK_DOMAIN_GET_STATUS}"
        else
            cp "${MOCK_DOMAIN_POLL_FIXTURE}" "${output_file}"
            printf '%s' "${MOCK_DOMAIN_POLL_STATUS}"
        fi
        ;;
    "POST "*"domains")
        cp "${MOCK_DOMAIN_POST_FIXTURE}" "${output_file}"
        printf '%s' "${MOCK_DOMAIN_POST_STATUS}"
        ;;
    "GET "*"/pages/projects/"*)
        cp "${MOCK_PROJECT_FIXTURE}" "${output_file}"
        printf '%s' "${MOCK_PROJECT_STATUS}"
        ;;
    "GET "*"zones?name="*)
        cp "${MOCK_ZONE_FIXTURE}" "${output_file}"
        printf '%s' "${MOCK_ZONE_STATUS}"
        ;;
    "GET "*"/dns_records?"*)
        cp "${MOCK_DNS_GET_FIXTURE}" "${output_file}"
        printf '%s' "${MOCK_DNS_GET_STATUS}"
        ;;
    "POST "*"/dns_records")
        cp "${MOCK_DNS_POST_FIXTURE}" "${output_file}"
        printf '%s' "${MOCK_DNS_POST_STATUS}"
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
    local manage_dns="${4:-false}"
    local dns_proxied="${5:-true}"
    local dns_get_fixture="${6:-${fixtures}/dns-empty.json}"
    local zone_fixture="${7:-${fixtures}/zone-active.json}"
    local dns_get_status="${8:-200}"
    local dns_post_status="${9:-200}"
    local transport_failure="${10:-false}"
    local domain_poll_fixture="${11:-${fixtures}/domain-active.json}"
    local case_dir="${tmp_dir}/${case_name}"
    mkdir -p "${case_dir}"

    if ! env PATH="${tmp_dir}/bin:${PATH}" \
        MOCK_CURL_LOG="${case_dir}/curl.log" \
        MOCK_DOMAIN_COUNT_FILE="${case_dir}/domain-count" \
        MOCK_DOMAIN_GET_STATUS="${get_status}" \
        MOCK_DOMAIN_GET_FIXTURE="${get_fixture}" \
        MOCK_DOMAIN_POST_STATUS="200" \
        MOCK_DOMAIN_POST_FIXTURE="${fixtures}/domain-created.json" \
        MOCK_DOMAIN_POLL_STATUS="200" \
        MOCK_DOMAIN_POLL_FIXTURE="${domain_poll_fixture}" \
        MOCK_PROJECT_STATUS="200" \
        MOCK_PROJECT_FIXTURE="${fixtures}/project.json" \
        MOCK_ZONE_STATUS="200" \
        MOCK_ZONE_FIXTURE="${zone_fixture}" \
        MOCK_DNS_GET_STATUS="${dns_get_status}" \
        MOCK_DNS_GET_FIXTURE="${dns_get_fixture}" \
        MOCK_DNS_POST_STATUS="${dns_post_status}" \
        MOCK_DNS_POST_FIXTURE="$(
            if [ "${dns_proxied}" = "true" ]; then
                printf '%s' "${fixtures}/dns-created-proxied.json"
            else
                printf '%s' "${fixtures}/dns-created-unproxied.json"
            fi
        )" \
        MOCK_TRANSPORT_FAILURE="${transport_failure}" \
        PAGES_DOMAIN_POLL_INTERVAL_SECONDS="0" \
        CLOUDFLARE_ACCOUNT_ID="test-account" \
        CLOUDFLARE_API_TOKEN="super-secret-token" \
        CUSTOM_DOMAIN="net-worth.ravensberg.org" \
        MANAGE_DNS="${manage_dns}" \
        DNS_ZONE="ravensberg.org" \
        DNS_PROXIED="${dns_proxied}" \
        PROJECT_NAME="net-worth-calculator" \
        GITHUB_OUTPUT="${case_dir}/output" \
        GITHUB_STEP_SUMMARY="${case_dir}/summary" \
        bash "${registration_script}" \
        >"${case_dir}/stdout" 2>"${case_dir}/stderr"; then
        cat "${case_dir}/stderr" >&2
        return 1
    fi
}

run_registration "default-no-dns" "200" "${fixtures}/domain-active.json"
default_log="${tmp_dir}/default-no-dns/curl.log"
assert_not_contains "${default_log}" "/zones"
assert_not_contains "${default_log}" "/dns_records"
assert_contains "${tmp_dir}/default-no-dns/output" "dns-action=unmanaged"
assert_contains "${tmp_dir}/default-no-dns/summary" "DNS proxied: \`not managed\`"

run_registration "create" "404" "${fixtures}/domain-not-found.json" "true"
create_log="${tmp_dir}/create/curl.log"
assert_contains "${create_log}" "GET https://api.cloudflare.com/client/v4/zones?name=ravensberg.org&status=active&account.id=test-account&page=1&per_page=50"
assert_contains "${create_log}" "GET https://api.cloudflare.com/client/v4/zones/test-zone/dns_records?name=net-worth.ravensberg.org&page=1&per_page=100"
assert_contains "${create_log}" "POST https://api.cloudflare.com/client/v4/zones/test-zone/dns_records"
assert_contains "${create_log}" 'BODY {"type":"CNAME","name":"net-worth.ravensberg.org","content":"net-worth-calculator-xn8.pages.dev","ttl":1,"proxied":true}'
assert_contains "${tmp_dir}/create/output" "dns-action=created"
assert_contains "${tmp_dir}/create/output" "status=active"
assert_contains "${tmp_dir}/create/summary" "Resolved project: \`net-worth-calculator\`"
assert_contains "${tmp_dir}/create/summary" "DNS CNAME target: \`net-worth-calculator-xn8.pages.dev\`"

run_registration "no-op" "200" "${fixtures}/domain-active.json" "true" "true" "${fixtures}/dns-existing.json"
no_op_log="${tmp_dir}/no-op/curl.log"
if grep -q '^POST .*dns_records' "${no_op_log}"; then
    fail "an exact matching DNS CNAME must not be created again"
fi
assert_contains "${tmp_dir}/no-op/output" "dns-action=no-op"

if run_registration "conflict" "200" "${fixtures}/domain-active.json" "true" "true" "${fixtures}/dns-conflict.json" >/dev/null 2>&1; then
    fail "a conflicting DNS record must fail closed"
fi
if [ -f "${tmp_dir}/conflict/curl.log" ] && grep -q '^POST .*dns_records' "${tmp_dir}/conflict/curl.log"; then
    fail "a conflicting DNS record must never be replaced"
fi
if run_registration "proxy-conflict" "200" "${fixtures}/domain-active.json" "true" "false" "${fixtures}/dns-existing.json" >/dev/null 2>&1; then
    fail "an existing CNAME with another proxy state must fail closed"
fi
if run_registration "duplicate-conflict" "200" "${fixtures}/domain-active.json" "true" "true" "${fixtures}/dns-duplicate.json" >/dev/null 2>&1; then
    fail "duplicate exact-name DNS records must fail closed"
fi

run_registration "unproxied" "404" "${fixtures}/domain-not-found.json" "true" "false"
assert_contains "${tmp_dir}/unproxied/curl.log" '"proxied":false'
assert_contains "${tmp_dir}/unproxied/summary" "DNS proxied: \`false\`"

run_registration "pagination" "200" "${fixtures}/domain-active.json" "true" "true" "${fixtures}/dns-empty-paginated.json"
assert_contains "${tmp_dir}/pagination/curl.log" "page=2&per_page=100"

run_registration "pending-timeout" "404" "${fixtures}/domain-not-found.json" "true" "true" "${fixtures}/dns-empty.json" "${fixtures}/zone-active.json" "200" "200" "false" "${fixtures}/domain-created.json"
assert_contains "${tmp_dir}/pending-timeout/output" "status=initializing"
assert_contains "${tmp_dir}/pending-timeout/stdout" "remains 'initializing' after the bounded activation wait"
[ "$(grep -c '/domains/net-worth.ravensberg.org$' "${tmp_dir}/pending-timeout/curl.log")" -eq 13 ] ||
    fail "pending custom domain must use exactly 12 bounded poll attempts"

if run_registration "zone-multiple" "200" "${fixtures}/domain-active.json" "true" "true" "${fixtures}/dns-empty.json" "${fixtures}/zone-multiple.json" >/dev/null 2>&1; then
    fail "multiple matching active zones must fail closed"
fi
if run_registration "zone-api-error" "200" "${fixtures}/domain-active.json" "true" "true" "${fixtures}/dns-empty.json" "${fixtures}/api-error.json" >/dev/null 2>&1; then
    fail "an unsuccessful zone API response must fail closed"
fi
if run_registration "dns-api-error" "200" "${fixtures}/domain-active.json" "true" "true" "${fixtures}/api-error.json" "${fixtures}/zone-active.json" "500" >/dev/null 2>&1; then
    fail "an unsuccessful DNS query must fail closed"
fi
if run_registration "dns-create-error" "200" "${fixtures}/domain-active.json" "true" "true" "${fixtures}/dns-empty.json" "${fixtures}/zone-active.json" "200" "500" >/dev/null 2>&1; then
    fail "an unsuccessful DNS creation must fail closed"
fi
if run_registration "pages-api-error" "500" "${fixtures}/api-error.json" >/dev/null 2>&1; then
    fail "an unsuccessful Pages API response must fail closed"
fi
if run_registration "transport-error" "000" "${fixtures}/api-error.json" "false" "true" "${fixtures}/dns-empty.json" "${fixtures}/zone-active.json" "200" "200" "true" >/dev/null 2>&1; then
    fail "a curl transport failure must fail closed"
fi

assert_contains "${workflow}" "needs.detect-cloudflare.outputs.deploy-production == 'true'"
assert_contains "${workflow}" "needs.deploy-cloudflare.result"
assert_not_contains "${tmp_dir}/default-no-dns/curl.log" "/dns_records"

while IFS= read -r output_file; do
    assert_not_contains "${output_file}" "super-secret-token"
done < <(find "${tmp_dir}" -type f ! -path '*/bin/*')

echo "Cloudflare Pages custom-domain and managed-DNS contract is enforced."

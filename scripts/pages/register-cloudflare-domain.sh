#!/usr/bin/env bash
#
# Registers the custom domain on the production Cloudflare Pages project and,
# with MANAGE_DNS=true, creates its CNAME when absent (job
# register-cloudflare-domain of .github/workflows/pages.yml).
#
# shellcheck disable=SC2312 # api_errors never fails: it falls back to a fixed message.

set -euo pipefail

api_base="https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/pages/projects/${PROJECT_NAME}"
domain_response="$(mktemp)"
project_response="$(mktemp)"
zone_response="$(mktemp)"
records_response="$(mktemp)"
records_all="$(mktemp)"
records_next="$(mktemp)"
request_body="$(mktemp)"
trap 'rm -f "${domain_response}" "${project_response}" "${zone_response}" "${records_response}" "${records_all}" "${records_next}" "${request_body}"' EXIT

api_errors() {
    local response_file="$1"
    jq -r \
        'if ([.errors[]?.message] | length) > 0
     then [.errors[]?.message] | join("; ")
     else "no error details returned"
     end' \
        "${response_file}" 2>/dev/null || printf '%s' "invalid JSON response"
}

request() {
    local method="$1"
    local url="$2"
    local output_file="$3"
    local data_file="${4:-}"
    local -a args=(
        --silent
        --show-error
        --connect-timeout 10
        --max-time 60
        --output "${output_file}"
        --write-out "%{http_code}"
        --request "${method}"
        --header "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}"
    )

    if [ "${method}" = "GET" ]; then
        args+=(--retry 2 --retry-all-errors)
    fi

    if [ -n "${data_file}" ]; then
        args+=(
            --header "Content-Type: application/json"
            --data-binary "@${data_file}"
        )
    fi

    local http_code
    if ! http_code="$(curl "${args[@]}" "${url}")"; then
        echo "::error::Cloudflare API ${method} request failed before an HTTP response was received." >&2
        return 1
    fi
    printf '%s' "${http_code}"
}

domain_url="${api_base}/domains/${CUSTOM_DOMAIN}"
domain_http_code="$(request GET "${domain_url}" "${domain_response}")"

if [ "${domain_http_code}" = "200" ]; then
    if ! jq -e \
        --arg domain "${CUSTOM_DOMAIN}" \
        '.success == true and .result.name == $domain' \
        "${domain_response}" >/dev/null; then
        echo "::error::Cloudflare returned an unsuccessful or mismatched custom-domain response: $(api_errors "${domain_response}")"
        exit 1
    fi
    status="$(jq -r '.result.status' "${domain_response}")"
    case "${status}" in
    active | pending | initializing)
        echo "Cloudflare Pages custom domain '${CUSTOM_DOMAIN}' already exists with status '${status}'."
        ;;
    *)
        echo "::error::Cloudflare Pages custom domain '${CUSTOM_DOMAIN}' is in unexpected status '${status}'."
        exit 1
        ;;
    esac
elif [ "${domain_http_code}" = "404" ]; then
    jq -cn --arg name "${CUSTOM_DOMAIN}" '{name: $name}' >"${request_body}"
    domain_http_code="$(request POST "${api_base}/domains" "${domain_response}" "${request_body}")"
    if [ "${domain_http_code}" -lt 200 ] || [ "${domain_http_code}" -ge 300 ]; then
        echo "::error::Failed to register Cloudflare Pages custom domain '${CUSTOM_DOMAIN}' (HTTP ${domain_http_code}): $(api_errors "${domain_response}")"
        exit 1
    fi
    if ! jq -e \
        --arg domain "${CUSTOM_DOMAIN}" \
        '.success == true and .result.name == $domain' \
        "${domain_response}" >/dev/null; then
        echo "::error::Cloudflare returned an unsuccessful or mismatched custom-domain registration response: $(api_errors "${domain_response}")"
        exit 1
    fi
    status="$(jq -r '.result.status' "${domain_response}")"
    case "${status}" in
    active | pending | initializing)
        echo "Registered Cloudflare Pages custom domain '${CUSTOM_DOMAIN}' with status '${status}'."
        ;;
    *)
        echo "::error::Cloudflare registered custom domain '${CUSTOM_DOMAIN}' with unexpected status '${status}'."
        exit 1
        ;;
    esac
else
    echo "::error::Failed to query Cloudflare Pages custom domain '${CUSTOM_DOMAIN}' (HTTP ${domain_http_code}): $(api_errors "${domain_response}")"
    exit 1
fi

project_http_code="$(request GET "${api_base}" "${project_response}")"
if [ "${project_http_code}" -lt 200 ] || [ "${project_http_code}" -ge 300 ]; then
    echo "::error::Failed to query Cloudflare Pages project '${PROJECT_NAME}' (HTTP ${project_http_code}): $(api_errors "${project_response}")"
    exit 1
fi
if ! dns_target="$(
    jq -er \
        --arg project "${PROJECT_NAME}" \
        'select(.success == true and .result.name == $project)
     | .result.subdomain
     | select(type == "string" and endswith(".pages.dev"))' \
        "${project_response}"
)"; then
    echo "::error::Cloudflare returned an unsuccessful project response or no valid pages.dev subdomain: $(api_errors "${project_response}")"
    exit 1
fi

dns_action="unmanaged"
dns_proxied_summary="not managed"
if [ "${MANAGE_DNS}" = "true" ]; then
    dns_proxied_summary="${DNS_PROXIED}"
    zones_url="https://api.cloudflare.com/client/v4/zones?name=${DNS_ZONE}&status=active&account.id=${CLOUDFLARE_ACCOUNT_ID}&page=1&per_page=50"
    zones_http_code="$(request GET "${zones_url}" "${zone_response}")"
    if [ "${zones_http_code}" -lt 200 ] || [ "${zones_http_code}" -ge 300 ]; then
        echo "::error::Failed to resolve active Cloudflare DNS zone '${DNS_ZONE}' (HTTP ${zones_http_code}): $(api_errors "${zone_response}")"
        exit 1
    fi
    if ! jq -e \
        --arg zone "${DNS_ZONE}" \
        --arg account "${CLOUDFLARE_ACCOUNT_ID}" \
        '.success == true
     and (.result | type) == "array"
     and ((.result_info.total_pages // 1) == 1)
     and ([.result[]
           | select(.name == $zone
                    and .status == "active"
                    and .account.id == $account)]
          | length) == 1
     and (.result | length) == 1' \
        "${zone_response}" >/dev/null; then
        echo "::error::Cloudflare must return exactly one active '${DNS_ZONE}' zone in the configured account: $(api_errors "${zone_response}")"
        exit 1
    fi
    zone_id="$(jq -er '.result[0].id | select(type == "string" and length > 0)' "${zone_response}")"
    zone_api="https://api.cloudflare.com/client/v4/zones/${zone_id}"

    printf '[]' >"${records_all}"
    page=1
    total_pages=1
    while [ "${page}" -le "${total_pages}" ]; do
        records_url="${zone_api}/dns_records?name=${CUSTOM_DOMAIN}&page=${page}&per_page=100"
        records_http_code="$(request GET "${records_url}" "${records_response}")"
        if [ "${records_http_code}" -lt 200 ] || [ "${records_http_code}" -ge 300 ]; then
            echo "::error::Failed to query DNS records for '${CUSTOM_DOMAIN}' (HTTP ${records_http_code}): $(api_errors "${records_response}")"
            exit 1
        fi
        if ! jq -e \
            '.success == true
       and (.result | type) == "array"
       and ((.result_info.total_pages // 1) | type) == "number"
       and (.result_info.total_pages // 1) >= 1' \
            "${records_response}" >/dev/null; then
            echo "::error::Cloudflare returned an invalid DNS records response: $(api_errors "${records_response}")"
            exit 1
        fi
        total_pages="$(jq -r '.result_info.total_pages // 1' "${records_response}")"
        jq -s '.[0] + .[1].result' "${records_all}" "${records_response}" >"${records_next}"
        mv "${records_next}" "${records_all}"
        page=$((page + 1))
    done

    record_count="$(
        jq -r --arg name "${CUSTOM_DOMAIN}" \
            '[.[] | select(.name == $name)] | length' \
            "${records_all}"
    )"
    if [ "${record_count}" -eq 0 ]; then
        jq -cn \
            --arg name "${CUSTOM_DOMAIN}" \
            --arg content "${dns_target}" \
            --argjson proxied "${DNS_PROXIED}" \
            '{type: "CNAME", name: $name, content: $content, ttl: 1, proxied: $proxied}' \
            >"${request_body}"
        create_http_code="$(request POST "${zone_api}/dns_records" "${records_response}" "${request_body}")"
        if [ "${create_http_code}" -lt 200 ] || [ "${create_http_code}" -ge 300 ]; then
            echo "::error::Failed to create DNS CNAME for '${CUSTOM_DOMAIN}' (HTTP ${create_http_code}): $(api_errors "${records_response}")"
            exit 1
        fi
        if ! jq -e \
            --arg name "${CUSTOM_DOMAIN}" \
            --arg content "${dns_target}" \
            --argjson proxied "${DNS_PROXIED}" \
            '.success == true
       and .result.type == "CNAME"
       and .result.name == $name
       and .result.content == $content
       and .result.proxied == $proxied' \
            "${records_response}" >/dev/null; then
            echo "::error::Cloudflare returned an unsuccessful or mismatched DNS creation response: $(api_errors "${records_response}")"
            exit 1
        fi
        dns_action="created"
        echo "Created DNS CNAME '${CUSTOM_DOMAIN}' pointing to '${dns_target}' (proxied: ${DNS_PROXIED})."
    elif [ "${record_count}" -eq 1 ] && jq -e \
        --arg name "${CUSTOM_DOMAIN}" \
        --arg content "${dns_target}" \
        --argjson proxied "${DNS_PROXIED}" \
        '.[] | select(.name == $name)
     | .type == "CNAME"
       and .content == $content
       and .proxied == $proxied' \
        "${records_all}" >/dev/null; then
        dns_action="no-op"
        echo "DNS CNAME '${CUSTOM_DOMAIN}' already points to '${dns_target}' with the requested proxy state."
    else
        echo "::error::A conflicting DNS record already exists for '${CUSTOM_DOMAIN}'. Refusing to change or replace it."
        exit 1
    fi

    if [ "${status}" != "active" ]; then
        poll_interval="${PAGES_DOMAIN_POLL_INTERVAL_SECONDS:-10}"
        for attempt in $(seq 1 12); do
            sleep "${poll_interval}"
            domain_http_code="$(request GET "${domain_url}" "${domain_response}")"
            if [ "${domain_http_code}" != "200" ] || ! jq -e \
                --arg domain "${CUSTOM_DOMAIN}" \
                '.success == true and .result.name == $domain' \
                "${domain_response}" >/dev/null; then
                echo "::error::Failed to poll Cloudflare Pages custom domain '${CUSTOM_DOMAIN}' (HTTP ${domain_http_code}): $(api_errors "${domain_response}")"
                exit 1
            fi
            status="$(jq -r '.result.status' "${domain_response}")"
            case "${status}" in
            active)
                echo "Cloudflare Pages custom domain '${CUSTOM_DOMAIN}' is active."
                break
                ;;
            pending | initializing)
                if [ "${attempt}" -eq 12 ]; then
                    echo "::notice title=Cloudflare Pages domain pending::Custom domain '${CUSTOM_DOMAIN}' remains '${status}' after the bounded activation wait."
                fi
                ;;
            *)
                echo "::error::Cloudflare Pages custom domain '${CUSTOM_DOMAIN}' entered unexpected status '${status}'."
                exit 1
                ;;
            esac
        done
    fi
fi

{
    echo "status=${status}"
    echo "dns-target=${dns_target}"
    echo "dns-action=${dns_action}"
} >>"${GITHUB_OUTPUT}"
echo "::notice title=Cloudflare Pages custom domain::Domain '${CUSTOM_DOMAIN}', project '${PROJECT_NAME}', target '${dns_target}', DNS '${dns_action}', proxied '${dns_proxied_summary}', Pages status '${status}'."
{
    echo "### Cloudflare Pages custom domain"
    echo
    echo "- Domain: \`${CUSTOM_DOMAIN}\`"
    echo "- Resolved project: \`${PROJECT_NAME}\`"
    echo "- DNS CNAME target: \`${dns_target}\`"
    echo "- DNS action: \`${dns_action}\`"
    echo "- DNS proxied: \`${dns_proxied_summary}\`"
    echo "- Pages domain status: \`${status}\`"
} >>"${GITHUB_STEP_SUMMARY}"

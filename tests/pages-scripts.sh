#!/usr/bin/env bash
#
# Tests the scripts in scripts/pages/ that .github/workflows/pages.yml runs and
# that tests/pages-custom-domain-contract.sh doesn't cover (#537):
# detect-cloudflare.sh, update-sitemap-lastmod.sh and
# delete-preview-deployments.sh. A stand-in for curl serves Cloudflare API
# responses and records the requests.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scripts="${repo_root}/scripts/pages"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

fail() {
    echo "error: $*" >&2
    exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq is not installed"

# --- detect-cloudflare.sh ---------------------------------------------------

# Runs detect-cloudflare.sh with the defaults below, overridden by the
# NAME=value arguments. Sets $case_dir; the outputs are in ${case_dir}/output.
detect() {
    case_dir="$(mktemp -d "${tmp_dir}/detect.XXXXXX")"
    env \
        CLOUDFLARE_ACCOUNT_ID="account" \
        CLOUDFLARE_API_TOKEN="token" \
        CLOUDFLARE_PREVIEW="true" \
        CLOUDFLARE_PRODUCTION="false" \
        CLOUDFLARE_PRODUCTION_ON_RELEASE="false" \
        CLOUDFLARE_ACCEPTANCE="false" \
        CLOUDFLARE_CUSTOM_DOMAIN="" \
        CLOUDFLARE_PRODUCTION_BRANCH="main" \
        CLOUDFLARE_ACCEPTANCE_BRANCH="acceptance" \
        PRODUCTION_BRANCH="main" \
        EVENT_NAME="push" \
        GIT_REF="refs/heads/main" \
        CONFIGURED_PROJECT_NAME="" \
        REPOSITORY_NAME="my-site" \
        GITHUB_OUTPUT="${case_dir}/output" \
        "$@" \
        bash "${scripts}/detect-cloudflare.sh" >"${case_dir}/stdout" 2>&1
}

# Asserts that output $1 of the last detect run is $2.
expect_output() {
    local actual
    actual="$(sed -n "s/^$1=//p" "${case_dir}/output")"
    [ "${actual}" = "$2" ] || fail "detect-cloudflare: expected $1=$2, got '${actual}' (${case_dir})"
}

production='{"target":"production","environment":"cloudflare-pages","branch":"main"}'
acceptance='{"target":"acceptance","environment":"cloudflare-pages-acceptance","branch":"acceptance"}'

detect CLOUDFLARE_PREVIEW=false || fail "disabled deploys must pass"
expect_output enabled false
expect_output targets "[]"
grep -Fq "disabled by input" "${case_dir}/stdout" || fail "disabled deploys must say so"

detect CLOUDFLARE_API_TOKEN= || fail "previews without secrets must be skipped, not fail"
expect_output enabled false
expect_output deploy-production false
grep -Fq "::notice::Missing Cloudflare secrets; skipping preview deploys." "${case_dir}/stdout" ||
    fail "previews without secrets must explain the skip"

if detect CLOUDFLARE_ACCOUNT_ID= CLOUDFLARE_CUSTOM_DOMAIN=www.example.com; then
    fail "a custom domain without secrets must fail"
fi
grep -Fq "::error::cloudflare-custom-domain requires CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID." \
    "${case_dir}/stdout" || fail "a custom domain without secrets must explain the failure"
expect_output enabled false

for flag in CLOUDFLARE_PRODUCTION CLOUDFLARE_ACCEPTANCE; do
    if detect CLOUDFLARE_API_TOKEN= "${flag}=true"; then
        fail "${flag} without secrets must fail"
    fi
done

if detect REPOSITORY_NAME=My_Site; then
    fail "an invalid project name must fail"
fi
grep -Fq "must contain only lowercase letters, numbers, and hyphens" "${case_dir}/stdout" ||
    fail "an invalid project name must explain the rule"

detect CLOUDFLARE_PRODUCTION=true || fail "a production push must pass"
expect_output enabled true
expect_output project-name my-site
expect_output deploy-production true
expect_output targets "[${production}]"

detect CLOUDFLARE_PRODUCTION=true CONFIGURED_PROJECT_NAME=other-site || fail "a configured project must pass"
expect_output project-name other-site

detect CLOUDFLARE_PRODUCTION=true GIT_REF=refs/heads/feature || fail "a feature push must pass"
expect_output deploy-production false
expect_output targets "[]"

detect CLOUDFLARE_PRODUCTION=true CLOUDFLARE_PRODUCTION_ON_RELEASE=true ||
    fail "production-on-release on a push must pass"
expect_output deploy-production false
detect CLOUDFLARE_PRODUCTION=true CLOUDFLARE_PRODUCTION_ON_RELEASE=true EVENT_NAME=release GIT_REF=refs/tags/v1.0.0 ||
    fail "production-on-release on a release must pass"
expect_output deploy-production true
expect_output targets "[${production}]"

detect CLOUDFLARE_PRODUCTION=true CLOUDFLARE_ACCEPTANCE=true || fail "production and acceptance must pass"
expect_output targets "[${production},${acceptance}]"

detect CLOUDFLARE_ACCEPTANCE=true EVENT_NAME=pull_request GIT_REF=refs/heads/main ||
    fail "acceptance on a pull request must pass"
expect_output enabled true
expect_output targets "[]"

# --- update-sitemap-lastmod.sh ----------------------------------------------

sitemap="${tmp_dir}/sitemap.xml"
if SITEMAP_PATH="${tmp_dir}/missing.xml" bash "${scripts}/update-sitemap-lastmod.sh" >"${tmp_dir}/sitemap.out" 2>&1; then
    fail "a missing sitemap must fail"
fi
grep -Fq "does not exist" "${tmp_dir}/sitemap.out" || fail "a missing sitemap must say so"

printf '<urlset><url><loc>https://example.com/</loc></url></urlset>\n' >"${sitemap}"
if SITEMAP_PATH="${sitemap}" bash "${scripts}/update-sitemap-lastmod.sh" >"${tmp_dir}/sitemap.out" 2>&1; then
    fail "a sitemap without lastmod tags must fail"
fi
grep -Fq "No sitemap lastmod tags found" "${tmp_dir}/sitemap.out" || fail "a sitemap without lastmod must say so"

cat >"${sitemap}" <<'EOF'
<urlset>
<url><loc>https://example.com/</loc><lastmod>2020-01-02</lastmod></url>
<url><loc>https://example.com/a</loc><lastmod>2021-03-04</lastmod></url>
<url><loc>https://example.com/b</loc><lastmod>2021-03-04T10:00:00Z</lastmod></url>
</urlset>
EOF
today="$(date -u +%Y-%m-%d)"
SITEMAP_PATH="${sitemap}" bash "${scripts}/update-sitemap-lastmod.sh" || fail "a valid sitemap must pass"
[ "$(grep -c "<lastmod>${today}</lastmod>" "${sitemap}")" -eq 2 ] || fail "every date-only lastmod must become today"
grep -Fq "<lastmod>2021-03-04T10:00:00Z</lastmod>" "${sitemap}" || fail "a lastmod with a time must stay unchanged"

# --- delete-preview-deployments.sh ------------------------------------------

# `curl -sS -o FILE -w "%{http_code}" [-X DELETE] -H HEADER URL` logs the
# method and URL to $MOCK_CURL_LOG. A list request returns $MOCK_LIST_FIXTURE
# with status $MOCK_LIST_STATUS; a delete returns 200, or 500 for the
# deployment ID in $MOCK_DELETE_FAIL.
mkdir -p "${tmp_dir}/bin"
cat >"${tmp_dir}/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
method=GET
output=""
url=""
while [ "$#" -gt 0 ]; do
    case "$1" in
    -o) output="$2" && shift 2 ;;
    -X) method="$2" && shift 2 ;;
    -w | -H) shift 2 ;;
    -sS) shift ;;
    https://*) url="$1" && shift ;;
    *) echo "unexpected curl argument: $1" >&2 && exit 2 ;;
    esac
done
printf '%s %s\n' "${method}" "${url}" >>"${MOCK_CURL_LOG}"
if [ "${method}" = GET ]; then
    cp "${MOCK_LIST_FIXTURE}" "${output}"
    printf '%s' "${MOCK_LIST_STATUS}"
elif [[ "${url}" == */deployments/${MOCK_DELETE_FAIL:-none}\?force=true ]]; then
    printf '{"success":false}' >"${output}"
    printf '500'
else
    printf '{"success":true}' >"${output}"
    printf '200'
fi
EOF
chmod +x "${tmp_dir}/bin/curl"

deployments='{"result":[
  {"id":"d1","deployment_trigger":{"metadata":{"branch":"feature/x"}}},
  {"id":"d2","deployment_trigger":{"metadata":{"branch":"main"}}},
  {"id":"d3","deployment_trigger":{"metadata":{"branch":"feature/x"}}}
]}'
printf '%s\n' "${deployments}" >"${tmp_dir}/deployments.json"
printf '{"success":false,"errors":[{"message":"denied"}]}\n' >"${tmp_dir}/denied.json"

# Runs delete-preview-deployments.sh for branch $1 with list fixture $2 and
# status $3. Sets $case_dir; stdout is in ${case_dir}/stdout.
delete_previews() {
    case_dir="$(mktemp -d "${tmp_dir}/delete.XXXXXX")"
    : >"${case_dir}/curl.log"
    env PATH="${tmp_dir}/bin:${PATH}" \
        MOCK_CURL_LOG="${case_dir}/curl.log" \
        MOCK_LIST_FIXTURE="$2" \
        MOCK_LIST_STATUS="$3" \
        MOCK_DELETE_FAIL="${4:-}" \
        BRANCH="$1" \
        CLOUDFLARE_ACCOUNT_ID="account" \
        CLOUDFLARE_API_TOKEN="token" \
        PROJECT_NAME="my-site" \
        bash "${scripts}/delete-preview-deployments.sh" >"${case_dir}/stdout" 2>&1
}

api="https://api.cloudflare.com/client/v4/accounts/account/pages/projects/my-site/deployments"

delete_previews feature/x "${tmp_dir}/deployments.json" 200 || fail "deleting previews must pass"
expected="GET ${api}
DELETE ${api}/d1?force=true
DELETE ${api}/d3?force=true"
[ "$(cat "${case_dir}/curl.log")" = "${expected}" ] ||
    fail "only the branch's deployments must be deleted, got:"$'\n'"$(cat "${case_dir}/curl.log")"

delete_previews feature/x "${tmp_dir}/deployments.json" 200 d1 || fail "a failed delete must only warn"
grep -Fq "::warning::Failed to delete deployment d1 (HTTP 500):" "${case_dir}/stdout" ||
    fail "a failed delete must be reported"
grep -Fq "Deleted d3" "${case_dir}/stdout" || fail "a failed delete must not stop the others"

delete_previews other "${tmp_dir}/deployments.json" 200 || fail "a branch without previews must pass"
grep -Fq "No preview deployments found for branch 'other'" "${case_dir}/stdout" ||
    fail "a branch without previews must say so"
[ "$(wc -l <"${case_dir}/curl.log")" -eq 1 ] || fail "a branch without previews must delete nothing"

if delete_previews feature/x "${tmp_dir}/denied.json" 403; then
    fail "a failed list request must fail"
fi
grep -Fq "::error::Failed to list deployments (HTTP 403):" "${case_dir}/stdout" ||
    fail "a failed list request must be reported"

if delete_previews feature/x "${tmp_dir}/denied.json" 200; then
    fail "a list response without a result array must fail"
fi
grep -Fq "::error::Failed to parse Cloudflare deployments response:" "${case_dir}/stdout" ||
    fail "an unparsable list response must be reported"

echo "✓ pages: detect-cloudflare, update-sitemap-lastmod and delete-preview-deployments behave as before."

#!/usr/bin/env bash
#
# Deletes the Cloudflare Pages preview deployments of a closed pull request's
# branch (job close-preview of .github/workflows/pages.yml).

set -euo pipefail

http_code="$(
    curl -sS -o /tmp/cf_response.json -w "%{http_code}" \
        -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
        "https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/pages/projects/${PROJECT_NAME}/deployments"
)"
if [ "${http_code}" -lt 200 ] || [ "${http_code}" -ge 300 ]; then
    echo "::error::Failed to list deployments (HTTP ${http_code}):"
    cat /tmp/cf_response.json
    exit 1
fi

if ! deployment_ids="$(
    jq -r \
        --arg branch "${BRANCH}" \
        'if (.result | type) == "array" then
      .result[]
      | select(.deployment_trigger.metadata.branch == $branch)
      | .id
    else
      error("Cloudflare response did not include a result array")
    end' \
        /tmp/cf_response.json
)"; then
    echo "::error::Failed to parse Cloudflare deployments response:"
    cat /tmp/cf_response.json
    exit 1
fi

if [ -z "${deployment_ids}" ]; then
    echo "No preview deployments found for branch '${BRANCH}'"
    exit 0
fi

for deployment_id in ${deployment_ids}; do
    echo "Deleting deployment ${deployment_id} for branch '${BRANCH}'"
    del_code="$(
        curl -sS -o /tmp/cf_del_response.json -w "%{http_code}" -X DELETE \
            -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
            "https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/pages/projects/${PROJECT_NAME}/deployments/${deployment_id}?force=true"
    )"
    if [ "${del_code}" -lt 200 ] || [ "${del_code}" -ge 300 ]; then
        echo "::warning::Failed to delete deployment ${deployment_id} (HTTP ${del_code}):"
        cat /tmp/cf_del_response.json
    else
        echo "Deleted ${deployment_id}"
    fi
done

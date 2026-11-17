#!/usr/bin/env bash
#
# Decides which Cloudflare Pages deploys run for this event (job detect-cloudflare
# of .github/workflows/pages.yml) and writes them to $GITHUB_OUTPUT.

set -euo pipefail

project_name="${CONFIGURED_PROJECT_NAME:-${REPOSITORY_NAME}}"

if [ "${CLOUDFLARE_PREVIEW}" != "true" ] && [ "${CLOUDFLARE_PRODUCTION}" != "true" ] && [ "${CLOUDFLARE_ACCEPTANCE}" != "true" ]; then
    {
        echo "enabled=false"
        echo "deploy-production=false"
        echo "targets=[]"
    } >>"${GITHUB_OUTPUT}"
    echo "Cloudflare Pages deployments are disabled by input."
    exit 0
fi

if [ -z "${CLOUDFLARE_API_TOKEN}" ] || [ -z "${CLOUDFLARE_ACCOUNT_ID}" ]; then
    {
        echo "enabled=false"
        echo "deploy-production=false"
        echo "targets=[]"
    } >>"${GITHUB_OUTPUT}"
    if [ -n "${CLOUDFLARE_CUSTOM_DOMAIN}" ]; then
        echo "::error::cloudflare-custom-domain requires CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID."
        exit 1
    elif [ "${CLOUDFLARE_PRODUCTION}" = "true" ] || [ "${CLOUDFLARE_ACCEPTANCE}" = "true" ]; then
        echo "::error::cloudflare-production or cloudflare-acceptance is enabled, but CLOUDFLARE_API_TOKEN or CLOUDFLARE_ACCOUNT_ID is missing."
        exit 1
    fi

    echo "::notice::Missing Cloudflare secrets; skipping preview deploys."
    exit 0
fi

if [ -z "${project_name}" ]; then
    echo "::error::cloudflare-project-name is required."
    exit 1
fi

if ! [[ "${project_name}" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
    echo "::error::cloudflare-project-name must contain only lowercase letters, numbers, and hyphens."
    exit 1
fi

# Work out which production-style targets deploy for this event.
# Pull request previews are handled by a separate job.
is_production_branch="false"
if [ "${EVENT_NAME}" != "pull_request" ] && [ "${GIT_REF}" = "refs/heads/${PRODUCTION_BRANCH}" ]; then
    is_production_branch="true"
fi

deploy_production="false"
if [ "${CLOUDFLARE_PRODUCTION}" = "true" ]; then
    if [ "${CLOUDFLARE_PRODUCTION_ON_RELEASE}" = "true" ]; then
        [ "${EVENT_NAME}" = "release" ] && deploy_production="true"
    else
        [ "${is_production_branch}" = "true" ] && deploy_production="true"
    fi
fi

deploy_acceptance="false"
if [ "${CLOUDFLARE_ACCEPTANCE}" = "true" ] && [ "${is_production_branch}" = "true" ]; then
    deploy_acceptance="true"
fi

targets="$(
    jq -cn \
        --arg prod_branch "${CLOUDFLARE_PRODUCTION_BRANCH}" \
        --arg acc_branch "${CLOUDFLARE_ACCEPTANCE_BRANCH}" \
        --argjson prod "${deploy_production}" \
        --argjson acc "${deploy_acceptance}" \
        '[
       (if $prod then {target: "production", environment: "cloudflare-pages", branch: $prod_branch} else empty end),
       (if $acc then {target: "acceptance", environment: "cloudflare-pages-acceptance", branch: $acc_branch} else empty end)
     ]'
)"

{
    echo "project-name=${project_name}"
    echo "enabled=true"
    echo "deploy-production=${deploy_production}"
    echo "targets=${targets}"
} >>"${GITHUB_OUTPUT}"
echo "Cloudflare Pages deployments are configured (targets: ${targets})."

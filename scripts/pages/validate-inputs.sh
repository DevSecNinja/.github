#!/usr/bin/env bash
#
# Validates the inputs of .github/workflows/pages.yml (job validate-inputs).

set -euo pipefail

if [ -z "${NODE_VERSION}" ] && {
    [ -n "${INSTALL_COMMAND}" ] ||
        [ -n "${TEST_SETUP_COMMAND}" ] ||
        [ -n "${TEST_COMMAND}" ] ||
        [ -n "${BUILD_COMMAND}" ]
}; then
    echo "::error::node-version is required when install-command, test-setup-command, test-command, or build-command is set; provide node-version or clear those commands."
    exit 1
fi

if [ -n "${ARTIFACT_NAME}" ] && [ -n "${BUILD_COMMAND}" ]; then
    echo "::error::artifact-name and build-command are mutually exclusive; the artifact is deployed as-is."
    exit 1
fi

if [ "${BUILD_GITHUB_TOKEN}" = "true" ]; then
    if [ -z "${BUILD_COMMAND}" ]; then
        echo "::error::build-github-token requires build-command."
        exit 1
    fi

    # The deploy jobs delete artifact-path before restoring the built
    # artifact, so it must be a dedicated subdirectory of the workspace.
    # Trailing slashes are harmless; any other empty, `.` or `..` path
    # component (including an absolute path or the workspace root) is
    # rejected, since `rm -rf` refuses operands ending in `.`.
    # shellcheck disable=SC2153 # ARTIFACT_PATH comes from the step env.
    artifact_path="${ARTIFACT_PATH}"
    while [[ "${artifact_path}" == */ ]]; do artifact_path="${artifact_path%/}"; done
    case "/${artifact_path}/" in
    //* | *//* | */./* | */../*)
        echo "::error::build-github-token requires artifact-path to be a dedicated relative subdirectory (for example 'dist'), not '${ARTIFACT_PATH}'."
        exit 1
        ;;
    *) ;;
    esac
fi

if [ -z "${WRANGLER_VERSION}" ] && {
    [ "${CLOUDFLARE_PREVIEW}" = "true" ] ||
        [ "${CLOUDFLARE_PRODUCTION}" = "true" ] ||
        [ "${CLOUDFLARE_ACCEPTANCE}" = "true" ]
}; then
    echo "::error::wrangler-version is required when cloudflare-preview, cloudflare-production, or cloudflare-acceptance is enabled."
    exit 1
fi

if [ -n "${CLOUDFLARE_CUSTOM_DOMAIN}" ]; then
    if [ "${CLOUDFLARE_PRODUCTION}" != "true" ]; then
        echo "::error::cloudflare-custom-domain requires cloudflare-production: true."
        exit 1
    fi

    if [ -z "${CONFIGURED_PROJECT_NAME}" ]; then
        echo "::error::cloudflare-project-name is required when cloudflare-custom-domain is set."
        exit 1
    fi

    if [ "${#CLOUDFLARE_CUSTOM_DOMAIN}" -gt 253 ] ||
        ! [[ "${CLOUDFLARE_CUSTOM_DOMAIN}" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ ]]; then
        echo "::error::cloudflare-custom-domain must be a lowercase FQDN with at least two labels; schemes, paths, ports, wildcards, underscores, and trailing dots are not allowed."
        exit 1
    fi
fi

if [ "${CLOUDFLARE_MANAGE_DNS}" = "true" ]; then
    if [ "${CLOUDFLARE_PRODUCTION}" != "true" ]; then
        echo "::error::cloudflare-manage-dns requires cloudflare-production: true."
        exit 1
    fi

    if [ -z "${CLOUDFLARE_CUSTOM_DOMAIN}" ]; then
        echo "::error::cloudflare-manage-dns requires cloudflare-custom-domain."
        exit 1
    fi

    if [ -z "${CLOUDFLARE_DNS_ZONE}" ]; then
        echo "::error::cloudflare-manage-dns requires cloudflare-dns-zone."
        exit 1
    fi

    if [ "${#CLOUDFLARE_DNS_ZONE}" -gt 253 ] ||
        ! [[ "${CLOUDFLARE_DNS_ZONE}" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ ]]; then
        echo "::error::cloudflare-dns-zone must be a lowercase DNS zone with at least two labels; schemes, paths, ports, wildcards, underscores, and trailing dots are not allowed."
        exit 1
    fi

    case "${CLOUDFLARE_CUSTOM_DOMAIN}" in
    "${CLOUDFLARE_DNS_ZONE}" | *."${CLOUDFLARE_DNS_ZONE}") ;;
    *)
        echo "::error::cloudflare-custom-domain must equal cloudflare-dns-zone or be its subdomain."
        exit 1
        ;;
    esac
fi

echo "Input validation passed."

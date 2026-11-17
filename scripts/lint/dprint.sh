#!/usr/bin/env bash
#
# Checks formatting with dprint.
# A step of .github/workflows/lint.yml, run the same way in both lint modes.
# Env: CONFIG_DIR: lint-config-dir; its dprint.json replaces the repository's config.

set -eo pipefail

bash "$(dirname "${BASH_SOURCE[0]}")/require-mise-tool.sh" dprint
if [ -n "${CONFIG_DIR}" ] && [ -f "${CONFIG_DIR}/dprint.json" ]; then
    mise exec -- dprint check \
        --config "${CONFIG_DIR}/dprint.json" \
        --config-discovery=false \
        --allow-no-files
else
    mise exec -- dprint check --allow-no-files
fi

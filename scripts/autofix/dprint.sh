#!/usr/bin/env bash
#
# Formats Markdown with dprint (job autofix of .github/workflows/autofix.yml).
# Env: CONFIG_DIR.

set -e

if [ -n "${CONFIG_DIR}" ] && [ -f "${CONFIG_DIR}/dprint.json" ]; then
    mise exec -- dprint fmt \
        --config "${CONFIG_DIR}/dprint.json" \
        --config-discovery=false
else
    mise exec -- dprint fmt
fi

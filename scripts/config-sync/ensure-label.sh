#!/usr/bin/env bash
#
# Creates or updates the config-sync label; only warns when that fails (job sync
# of .github/workflows/config-sync.yml).
# Env: GH_TOKEN.

set -e

if ! gh label create "config-sync" \
    --color "0075ca" \
    --description "Automated config sync PR" \
    --force; then
    echo "::warning::Could not create/update config-sync label (transient error or org policy). The PR will be created without it."
fi

#!/usr/bin/env bash
#
# Formats YAML with yamlfmt (job autofix of .github/workflows/autofix.yml).
# Env: CONFIG_DIR.

set -e

# shellcheck disable=SC2312 # No pipefail, as before the move (#537): xargs' status decides.
if [ -n "${CONFIG_DIR}" ] && [ -f "${CONFIG_DIR}/.yamlfmt.yaml" ]; then
    find . \( -name '*.yaml' -o -name '*.yml' \) -print0 |
        xargs -0 mise exec -- yamlfmt -conf "${CONFIG_DIR}/.yamlfmt.yaml"
else
    find . \( -name '*.yaml' -o -name '*.yml' \) -print0 |
        xargs -0 mise exec -- yamlfmt
fi

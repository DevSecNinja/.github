#!/usr/bin/env bash
#
# Checks the formatting of every YAML file with yamlfmt.
# A step of .github/workflows/lint.yml, run the same way in both lint modes.
# Env: CONFIG_DIR: lint-config-dir; its .yamlfmt.yaml replaces the repository's config.

set -eo pipefail

bash "$(dirname "${BASH_SOURCE[0]}")/require-mise-tool.sh" yamlfmt
if [ -n "${CONFIG_DIR}" ] && [ -f "${CONFIG_DIR}/.yamlfmt.yaml" ]; then
    find . \( -name '*.yaml' -o -name '*.yml' \) -print0 |
        xargs -0 mise exec -- yamlfmt -conf "${CONFIG_DIR}/.yamlfmt.yaml" -lint
else
    find . \( -name '*.yaml' -o -name '*.yml' \) -print0 |
        xargs -0 mise exec -- yamlfmt -lint
fi

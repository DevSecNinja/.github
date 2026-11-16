#!/usr/bin/env bash
#
# Lints every YAML file with yamllint.
# A step of .github/workflows/lint.yml, run the same way in both lint modes.
# Env: CONFIG_DIR: lint-config-dir; its .yamllint.yaml replaces the repository's config.

set -eo pipefail

bash "$(dirname "${BASH_SOURCE[0]}")/require-mise-tool.sh" yamllint
if [ -n "${CONFIG_DIR}" ] && [ -f "${CONFIG_DIR}/.yamllint.yaml" ]; then
    find . \( -name '*.yaml' -o -name '*.yml' \) -print0 |
        xargs -0 mise exec -- yamllint -c "${CONFIG_DIR}/.yamllint.yaml"
else
    find . \( -name '*.yaml' -o -name '*.yml' \) -print0 |
        xargs -0 mise exec -- yamllint
fi

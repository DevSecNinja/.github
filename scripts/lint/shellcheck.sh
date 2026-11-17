#!/usr/bin/env bash
#
# Lints every shell script with shellcheck.
# A step of .github/workflows/lint.yml, run the same way in both lint modes.
# Env: CONFIG_DIR (its .shellcheckrc applies unless the repository has one), EXCLUDE_PATTERN (lint-shellcheck-exclude).

set -eo pipefail

bash "$(dirname "${BASH_SOURCE[0]}")/require-mise-tool.sh" shellcheck
repo_dir="${GITHUB_WORKSPACE:-$PWD}"
shellcheck_workdir="${repo_dir}"

if [ -n "${CONFIG_DIR}" ] && [ -f "${CONFIG_DIR}/.shellcheckrc" ]; then
    if [ -f "${repo_dir}/.shellcheckrc" ]; then
        echo "::notice::.shellcheckrc already exists; using the local file"
    else
        shellcheck_workdir="${RUNNER_TEMP:-/tmp}/shellcheck-config"
        mkdir -p "${shellcheck_workdir}"
        cp "${CONFIG_DIR}/.shellcheckrc" "${shellcheck_workdir}/.shellcheckrc"
    fi
fi

if [ -n "${EXCLUDE_PATTERN}" ]; then
    find "${repo_dir}" -name '*.sh' -not -path "${repo_dir}/${EXCLUDE_PATTERN}" -print0 |
        (cd "${shellcheck_workdir}" && xargs -0 -r mise exec -- shellcheck)
else
    find "${repo_dir}" -name '*.sh' -print0 |
        (cd "${shellcheck_workdir}" && xargs -0 -r mise exec -- shellcheck)
fi

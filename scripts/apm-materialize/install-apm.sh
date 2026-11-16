#!/usr/bin/env bash
#
# Installs the pinned apm-cli from PyPI for the runner user (job materialize of
# .github/workflows/apm-materialize.yml).
# Env: apm_cli_version.

set -euo pipefail
# ubuntu-24.04 ships python3 + pip; install the pinned apm-cli for this user.
# shellcheck disable=SC2154 # apm_cli_version comes from the step env.
python3 -m pip install --user "apm-cli==${apm_cli_version}"
echo "${HOME}/.local/bin" >>"${GITHUB_PATH}"

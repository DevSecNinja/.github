#!/usr/bin/env bash
#
# Installs the apm CLI with the official installer (job apm-sync of
# .github/workflows/apm-sync.yml).
# Env: VERSION, APM_INSTALL_DIR, APM_LIB_DIR.

set -euo pipefail
curl -sSL https://aka.ms/apm-unix | sh
echo "${APM_INSTALL_DIR}" >>"${GITHUB_PATH}"

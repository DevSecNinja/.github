#!/usr/bin/env bash
#
# Re-resolves the APM packages and redeploys their primitives (job apm-sync of
# .github/workflows/apm-sync.yml).
# Env: PACKAGES.

set -euo pipefail
apm --version
# shellcheck disable=SC2086 # PACKAGES is an intentional arg list.
apm update --yes ${PACKAGES}

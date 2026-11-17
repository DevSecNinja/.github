#!/usr/bin/env bash
#
# Runs apm install to refresh apm.lock.yaml and redeploy the primitives (job
# materialize of .github/workflows/apm-materialize.yml).

set -euo pipefail
apm --version
apm install

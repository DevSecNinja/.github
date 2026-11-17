#!/usr/bin/env bash
#
# Skips the sync when the repository has no apm.yml (job apm-sync of
# .github/workflows/apm-sync.yml).

set -e

if [ ! -f apm.yml ]; then
    echo "::notice::No apm.yml in this repo; nothing to sync."
    echo "skip=true" >>"${GITHUB_OUTPUT}"
else
    echo "skip=false" >>"${GITHUB_OUTPUT}"
fi

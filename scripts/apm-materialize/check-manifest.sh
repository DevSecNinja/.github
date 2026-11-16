#!/usr/bin/env bash
#
# Skips the materialize run when the repository has no apm.yml (job materialize
# of .github/workflows/apm-materialize.yml).

set -e

if [ ! -f apm.yml ]; then
    echo "::notice::No apm.yml in this repo; nothing to materialize."
    echo "skip=true" >>"${GITHUB_OUTPUT}"
else
    echo "skip=false" >>"${GITHUB_OUTPUT}"
fi

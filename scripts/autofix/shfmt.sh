#!/usr/bin/env bash
#
# Formats shell scripts with shfmt (job autofix of .github/workflows/autofix.yml).

set -e

# shellcheck disable=SC2312 # No pipefail, as before the move (#537): xargs' status decides.
find . -name '*.sh' -print0 | xargs -0 mise exec -- shfmt --write

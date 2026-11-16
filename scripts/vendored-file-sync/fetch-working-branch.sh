#!/usr/bin/env bash
#
# Fetches the PR branch so the pinned open-pr's bare --force-with-lease has a
# remote-tracking ref to lease against (job sync of
# .github/workflows/vendored-file-sync.yml).
# Env: BRANCH.

set -e

depth=()
# shellcheck disable=SC2312 # A failed check means a full clone: fetch without --depth.
if [ "$(git rev-parse --is-shallow-repository)" = "true" ]; then
    depth=(--depth=1)
fi
git fetch --no-tags "${depth[@]}" origin "+refs/heads/${BRANCH}:refs/remotes/origin/${BRANCH}" || true

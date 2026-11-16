#!/usr/bin/env bash
#
# Commits and pushes the formatting changes, if any (job autofix of
# .github/workflows/autofix.yml).
# Env: COMMIT_MESSAGE.

set -e

git config user.name "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"
if git diff --quiet; then
    echo "No formatting changes to commit."
else
    git add .
    git commit -m "${COMMIT_MESSAGE}"
    git push
fi

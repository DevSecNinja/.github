#!/usr/bin/env bash
#
# Generates the AI commits badges (actions/ai-commits-badge, step "Generate AI
# commits badges") by running ai_commits_badge.py with the action's inputs.

set -euo pipefail

action_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
args=(
    "--repo-dir=${BADGE_REPO_DIR}"
    "--ref=${BADGE_REF}"
    "--since=${BADGE_SINCE}"
    "--name=${BADGE_NAME}"
    "--label=${BADGE_LABEL}"
    "--out=${BADGE_OUT}"
    "--github-output=${GITHUB_OUTPUT}"
)
case "${BADGE_THEMES}" in
true) args+=(--themes) ;;
false) ;;
*)
    echo "::error::themes must be true or false." >&2
    exit 1
    ;;
esac
python3 "${action_dir}/ai_commits_badge.py" "${args[@]}"

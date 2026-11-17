#!/usr/bin/env bash
#
# Creates the immutable GitHub Release for TAG in REPO (actions/release-publish,
# step "Create immutable GitHub Release") with the notes in /tmp/release-notes.md
# and the newline-delimited ASSETS. RELEASE_NOTES_FILE overrides the notes path
# for tests.

set -euo pipefail

notes_file="${RELEASE_NOTES_FILE:-/tmp/release-notes.md}"

# Convert newline-delimited assets into a bash array, stripping
# blank/whitespace-only lines (so trailing newlines in YAML don't
# turn into spurious "" arguments to gh).
asset_args=()
while IFS= read -r line; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    [ -n "${trimmed}" ] && asset_args+=("${trimmed}")
done <<<"${ASSETS}"

# Single-shot upload: notes, title, and assets in one call so the
# release is compatible with the repo's Immutable-Releases setting
# (no later `gh release upload --clobber` / `gh release edit`).
if [ ${#asset_args[@]} -gt 0 ]; then
    gh release create "${TAG}" \
        --repo "${REPO}" \
        --title "${TAG}" \
        --notes-file "${notes_file}" \
        "${asset_args[@]}"
else
    gh release create "${TAG}" \
        --repo "${REPO}" \
        --title "${TAG}" \
        --notes-file "${notes_file}"
fi

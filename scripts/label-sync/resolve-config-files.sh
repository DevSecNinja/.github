#!/usr/bin/env bash
#
# Lists the label config files that exist, for sync-labels.sh (job label-sync
# of .github/workflows/label-sync.yml).

set -euo pipefail

config_files=""
for file in "${BASE_LABELS_FILE}" "${LABELS_FILE}"; do
    [ -z "${file}" ] && continue
    if [ -f "${file}" ]; then
        echo "  ✓ including ${file}"
        config_files="${config_files}${file}"$'\n'
    else
        echo "  ⊘ skipping ${file} (not found)"
    fi
done

if [ -z "${config_files}" ]; then
    echo "::error::No label config files found (looked for '${BASE_LABELS_FILE}' and '${LABELS_FILE}')"
    exit 1
fi

{
    echo "config-files<<EOF"
    printf '%s' "${config_files}"
    echo "EOF"
} >>"${GITHUB_OUTPUT}"

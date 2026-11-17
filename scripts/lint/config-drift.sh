#!/usr/bin/env bash
#
# Compares the repository's config files with DevSecNinja/.github/config-sync/files.
# A step of .github/workflows/lint.yml, run the same way in both lint modes.

set -eo pipefail

BASE_URL="https://raw.githubusercontent.com/DevSecNinja/.github/main/config-sync/files"
API_URL="https://api.github.com/repos/DevSecNinja/.github/contents/config-sync/files"
drifted=0

# Dynamically discover files from the central repo
files=$(curl -sf "${API_URL}" | grep '"name"' | sed 's/.*"name": "\(.*\)".*/\1/')

for file in ${files}; do
    if [ ! -f "${file}" ]; then
        echo "::warning::${file} exists in central repo but not locally (skipping)"
        continue
    fi

    echo "Checking ${file}..."
    if ! curl -sf "${BASE_URL}/${file}" | diff -u "${file}" - >/tmp/diff_output 2>&1; then
        echo "::error::${file} has drifted from central config"
        cat /tmp/diff_output
        drifted=1
    else
        echo "  ✓ ${file} matches"
    fi
done

if [ "${drifted}" -eq 1 ]; then
    echo ""
    echo "Config files have drifted from DevSecNinja/.github/config-sync/files/"
    echo "Run the config-sync workflow or manually update the files."
    exit 1
fi

echo ""
echo "All config files match the central repository."

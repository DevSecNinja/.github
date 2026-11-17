#!/usr/bin/env bash
#
# Lints the repository's JavaScript, TypeScript, JSON and CSS files with Biome
# and checks their formatting (`biome ci`, which never writes to the files).
# A step of .github/workflows/lint.yml, run the same way in both lint modes.
# Biome reads the repository's own config (biome.json or biome.jsonc).
# Env: EXCLUDE_PATTERN (lint-biome-exclude): skip the paths matching this bash
# pattern. UPLOAD_SARIF: also write the findings as SARIF for code scanning,
# and sarif=true to GITHUB_OUTPUT.

set -eo pipefail

lint_dir="$(dirname "${BASH_SOURCE[0]}")"
bash "${lint_dir}/require-mise-tool.sh" biome
mapfile -d '' listed < <(bash "${lint_dir}/language-files.sh" web)
files=()
for file in "${listed[@]}"; do
    # shellcheck disable=SC2053 # EXCLUDE_PATTERN is a pattern, not a string.
    if [ -z "${EXCLUDE_PATTERN}" ] || [[ "${file}" != ${EXCLUDE_PATTERN} ]]; then
        files+=("${file}")
    fi
done
# Without file arguments Biome would check the whole directory.
if [ "${#files[@]}" -eq 0 ]; then
    echo "::notice::No JavaScript, TypeScript, JSON or CSS files found; skipping Biome"
    exit 0
fi

# The default reporter shows formatting diffs in the log, the github one
# annotates the PR. --no-errors-on-unmatched: the config may ignore every file.
reporters=(--reporter=default --reporter=github)
if [ "${UPLOAD_SARIF}" = "true" ]; then
    reporters+=(--reporter=sarif "--reporter-file=${RUNNER_TEMP}/biome.sarif")
fi

status=0
mise exec -- biome ci --no-errors-on-unmatched "${reporters[@]}" -- "${files[@]}" || status=1
if [ "${UPLOAD_SARIF}" = "true" ] && [ -f "${RUNNER_TEMP}/biome.sarif" ]; then
    echo "sarif=true" >>"${GITHUB_OUTPUT}"
fi
exit "${status}"

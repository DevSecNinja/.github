#!/usr/bin/env bash
#
# Lints the repository's JavaScript, TypeScript, JSON and CSS files with Biome
# and checks their formatting (`biome ci`, which never writes to the files).
# A step of .github/workflows/lint.yml, run the same way in both lint modes.
# Biome reads the repository's own config (biome.json or biome.jsonc).
# Pinning biome in the repository's mise config is the opt-in, as for ruff:
# without the pin (or with one older than 2.4.0) Biome is skipped with a warning.
# Env: EXCLUDE_PATTERN (lint-biome-exclude): skip the paths matching this bash
# pattern. UPLOAD_SARIF: also write the findings as SARIF for code scanning,
# and sarif=true to GITHUB_OUTPUT.

set -eo pipefail

lint_dir="$(dirname "${BASH_SOURCE[0]}")"
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
# After the guard: a repository whose files are all excluded needs no pin.
if ! mise which biome >/dev/null 2>&1; then
    echo "::warning title=biome is not pinned::This repository has JavaScript, TypeScript, JSON or CSS files, but Biome is skipped because biome isn't pinned in the repository's mise config. To lint them, pin biome in .mise.toml (Renovate-managed), e.g. 'mise use biome@<version>', and add a Biome config: biome.json (config-sync has a template) or biome.jsonc. Set lint-biome: false to silence this warning."
    exit 0
fi
# Multiple reporters and --reporter-file need Biome 2.4.0 or later.
version="$(mise exec -- biome --version 2>/dev/null || true)"
version="${version##* }"
if [ -n "${version}" ] && [ "$(printf '%s\n' 2.4.0 "${version}" | sort -V | head -n 1)" != 2.4.0 ]; then
    echo "::warning title=biome is too old::This repository pins biome ${version}, but Biome is skipped because the shared Lint workflow needs 2.4.0 or later. To lint, update the biome pin in .mise.toml. Set lint-biome: false to silence this warning."
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

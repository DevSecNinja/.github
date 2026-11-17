#!/usr/bin/env bash
#
# Lints the repository's Python files with ruff and checks their formatting.
# A step of .github/workflows/lint.yml, run the same way in both lint modes.
# ruff reads the repository's own config (ruff.toml, .ruff.toml or pyproject.toml).
# Env: UPLOAD_SARIF: also write the lint findings as SARIF for code scanning,
# and sarif=true to GITHUB_OUTPUT.

set -eo pipefail

lint_dir="$(dirname "${BASH_SOURCE[0]}")"
bash "${lint_dir}/require-mise-tool.sh" ruff
mapfile -d '' files < <(bash "${lint_dir}/language-files.sh" python)
# Without file arguments ruff would check the whole directory.
if [ "${#files[@]}" -eq 0 ]; then
    echo "::notice::No Python files found; skipping ruff"
    exit 0
fi

# --force-exclude keeps the config's excludes for the files passed explicitly,
# and --no-fix overrides a `fix = true` in it: checks must not edit the files.
if [ "${UPLOAD_SARIF}" = "true" ]; then
    mise exec -- ruff check --force-exclude --no-fix --exit-zero \
        --output-format sarif --output-file "${RUNNER_TEMP}/ruff.sarif" -- "${files[@]}"
    echo "sarif=true" >>"${GITHUB_OUTPUT}"
fi

status=0
mise exec -- ruff check --force-exclude --no-fix --output-format github -- "${files[@]}" || status=1
mise exec -- ruff format --force-exclude --diff -- "${files[@]}" || status=1
exit "${status}"

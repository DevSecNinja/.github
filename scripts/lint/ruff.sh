#!/usr/bin/env bash
#
# Lints the repository's Python files with ruff and checks their formatting.
# A step of .github/workflows/lint.yml, run the same way in both lint modes.
# ruff reads the repository's own config (ruff.toml, .ruff.toml or pyproject.toml).
# Pinning ruff in the repository's mise config is the opt-in: without the pin
# ruff is skipped with a warning, so repositories adopt it on their own
# schedule instead of failing on the first lint.yml bump (#567).
# Env: UPLOAD_SARIF: also write the lint findings as SARIF for code scanning,
# and sarif=true to GITHUB_OUTPUT.

set -eo pipefail

lint_dir="$(dirname "${BASH_SOURCE[0]}")"
mapfile -d '' files < <(bash "${lint_dir}/language-files.sh" python)
# Without file arguments ruff would check the whole directory.
if [ "${#files[@]}" -eq 0 ]; then
    echo "::notice::No Python files found; skipping ruff"
    exit 0
fi
if ! mise which ruff >/dev/null 2>&1; then
    echo "::warning title=ruff is not pinned::This repository has Python files, but ruff is skipped because it isn't pinned in the repository's mise config. To lint them, pin ruff in .mise.toml (Renovate-managed), e.g. 'mise use ruff@<version>', and add a ruff config: ruff.toml (config-sync has a template) or [tool.ruff] in pyproject.toml. Set lint-ruff: false to silence this warning."
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

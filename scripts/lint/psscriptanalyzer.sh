#!/usr/bin/env bash
#
# Lints the repository's PowerShell files with PSScriptAnalyzer, through
# psscriptanalyzer.ps1 (pwsh is preinstalled on the ubuntu runners).
# A step of .github/workflows/lint.yml, run the same way in both lint modes.
# The repository's PSScriptAnalyzerSettings.psd1, when present, configures it.
# Env: PSSCRIPTANALYZER_VERSION (psscriptanalyzer-version): the module version
# to install; without it the linter skips with a warning naming the fix.
# UPLOAD_SARIF: also write the findings as SARIF for code scanning, and
# sarif=true to GITHUB_OUTPUT.

set -eo pipefail

lint_dir="$(dirname "${BASH_SOURCE[0]}")"
mapfile -d '' files < <(bash "${lint_dir}/language-files.sh" powershell)
if [ "${#files[@]}" -eq 0 ]; then
    echo "::notice::No PowerShell files found; skipping PSScriptAnalyzer"
    exit 0
fi
# Like an unpinned ruff or Biome: adopting the linter must not turn a
# caller's lint red before it has picked a version.
if [ -z "${PSSCRIPTANALYZER_VERSION}" ]; then
    echo "::warning title=psscriptanalyzer-version is not set::This repository has PowerShell files, but PSScriptAnalyzer is skipped because no psscriptanalyzer-version is passed to the shared Lint workflow. To lint them, pass psscriptanalyzer-version (Renovate-managed, see workflow-templates/lint.yml in DevSecNinja/.github) and add a PSScriptAnalyzerSettings.psd1 (config-sync has a template). Set lint-psscriptanalyzer: false to silence this warning."
    exit 0
fi

args=(-Version "${PSSCRIPTANALYZER_VERSION}" -PathList "${RUNNER_TEMP}/psscriptanalyzer-files")
if [ "${UPLOAD_SARIF}" = "true" ]; then
    args+=(-SarifFile "${RUNNER_TEMP}/psscriptanalyzer.sarif")
fi
# A list file, not arguments: pwsh -File would read a path such as -x.ps1 as a
# parameter name.
printf '%s\0' "${files[@]}" >"${RUNNER_TEMP}/psscriptanalyzer-files"

status=0
pwsh -NoProfile -NonInteractive -File "${lint_dir}/psscriptanalyzer.ps1" "${args[@]}" || status=1
if [ "${UPLOAD_SARIF}" = "true" ] && [ -f "${RUNNER_TEMP}/psscriptanalyzer.sarif" ]; then
    echo "sarif=true" >>"${GITHUB_OUTPUT}"
fi
exit "${status}"

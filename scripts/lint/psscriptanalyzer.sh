#!/usr/bin/env bash
#
# Lints the repository's PowerShell files with PSScriptAnalyzer, through
# psscriptanalyzer.ps1 (pwsh is preinstalled on the ubuntu runners).
# A step of .github/workflows/lint.yml, run the same way in both lint modes.
# The repository's PSScriptAnalyzerSettings.psd1, when present, configures it.
# Env: PSSCRIPTANALYZER_VERSION (psscriptanalyzer-version): the module version
# to install. UPLOAD_SARIF: also write the findings as SARIF for code scanning,
# and sarif=true to GITHUB_OUTPUT.

set -eo pipefail

lint_dir="$(dirname "${BASH_SOURCE[0]}")"
mapfile -d '' files < <(bash "${lint_dir}/language-files.sh" powershell)
if [ "${#files[@]}" -eq 0 ]; then
    echo "::notice::No PowerShell files found; skipping PSScriptAnalyzer"
    exit 0
fi
if [ -z "${PSSCRIPTANALYZER_VERSION}" ]; then
    echo "::error::PowerShell linting is required (PowerShell files found) but no psscriptanalyzer-version input was provided. Pass psscriptanalyzer-version (Renovate-managed, see workflow-templates/lint.yml in DevSecNinja/.github) when calling this reusable workflow, or set lint-psscriptanalyzer: false."
    exit 1
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

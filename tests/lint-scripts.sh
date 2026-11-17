#!/usr/bin/env bash
#
# Tests the linter scripts in scripts/lint/ that .github/workflows/lint.yml runs
# in both lint modes (#537). gitleaks has its own test, lint-gitleaks-report.sh.
#
# Each script runs in a scratch repository. Stand-ins for mise and curl record
# how they were called, so the tests pin down which config, files and flags
# each linter gets without installing the linters.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scripts="${repo_root}/scripts/lint"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

fail() {
    echo "error: $*" >&2
    exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq is not installed"
# The real pwsh, before the stand-ins below shadow it.
real_pwsh="$(command -v pwsh || true)"

# `mise which <tool>` succeeds for the tools in $FAKE_TOOLS. `mise exec -- <cmd>`
# records the working directory and command in $MISE_LOG, and exits $FAKE_EXIT.
mkdir -p "${tmp_dir}/bin"
cat >"${tmp_dir}/bin/mise" <<'EOF'
#!/usr/bin/env bash
case "$1" in
which) [[ " ${FAKE_TOOLS} " == *" $2 "* ]] ;;
exec)
    shift 2
    printf '%s: %s\n' "${PWD}" "$*" >>"${MISE_LOG}"
    [ -z "${FAKE_STDOUT:-}" ] || echo "${FAKE_STDOUT}"
    [ -z "${FAKE_WRITES:-}" ] || touch "${FAKE_WRITES}"
    exit "${FAKE_EXIT:-0}"
    ;;
*) exit 2 ;;
esac
EOF
# `curl -sf <url>` serves the central config-sync/files from $FAKE_CENTRAL: the
# contents API lists the file names, raw URLs return a file.
cat >"${tmp_dir}/bin/curl" <<'EOF'
#!/usr/bin/env bash
url="${*: -1}"
case "${url}" in
https://api.github.com/repos/DevSecNinja/.github/contents/config-sync/files)
    find "${FAKE_CENTRAL}" -type f | while IFS= read -r file; do
        printf '  {\n    "name": "%s",\n' "${file##*/}"
    done
    ;;
https://raw.githubusercontent.com/DevSecNinja/.github/main/config-sync/files/*)
    cat "${FAKE_CENTRAL}/${url##*/}"
    ;;
*) exit 22 ;;
esac
EOF
chmod +x "${tmp_dir}/bin/mise" "${tmp_dir}/bin/curl"

export PATH="${tmp_dir}/bin:${PATH}"
export MISE_LOG="${tmp_dir}/mise.log"
export GITHUB_OUTPUT="${tmp_dir}/output"
export GITHUB_STEP_SUMMARY="${tmp_dir}/summary.md"
export RUNNER_TEMP="${tmp_dir}/runner-temp"
export FAKE_TOOLS="dprint yamlfmt yamllint shellcheck shfmt trivy"
export FAKE_CENTRAL="${tmp_dir}/central"
export CONFIG_DIR="" EXCLUDE_PATTERN="" UPLOAD_SARIF=true FAKE_EXIT=0

repo="${tmp_dir}/repo"
config="${tmp_dir}/config"
mkdir -p "${repo}/sub" "${repo}/vendor" "${config}" "${FAKE_CENTRAL}"
touch "${repo}/mise.toml" "${repo}/a.yml" "${repo}/sub/b.yaml" "${repo}/a.sh" "${repo}/sub/b.sh" "${repo}/vendor/v.sh"
touch "${config}/dprint.json" "${config}/.yamlfmt.yaml" "${config}/.yamllint.yaml" "${config}/.shellcheckrc" "${config}/trivy.yaml"

# Runs scripts/lint/$2.sh in directory $1 with the extra environment in $3...
# $2 may add arguments: "require-mise-tool dprint". Sets status, out (stdout
# and stderr), log (mise calls), outputs and summary.
run_in() {
    local dir="$1" script args
    read -r script args <<<"$2"
    shift 2
    rm -rf "${RUNNER_TEMP}"
    mkdir -p "${RUNNER_TEMP}"
    : >"${MISE_LOG}"
    : >"${GITHUB_OUTPUT}"
    : >"${GITHUB_STEP_SUMMARY}"
    status=0
    # shellcheck disable=SC2086 # split the arguments
    out="$(cd "${dir}" && env "$@" bash "${scripts}/${script}.sh" ${args} 2>&1)" || status=$?
    out="${out//$'\r'/}" # jq on Windows ends lines with CRLF
    log="$(cat "${MISE_LOG}")"
    outputs="$(cat "${GITHUB_OUTPUT}")"
    summary="$(cat "${GITHUB_STEP_SUMMARY}")"
}
run() { run_in "${repo}" "$@"; }

expect_status() {
    [ "${status}" -eq "$1" ] || fail "$2: expected exit $1, got ${status}: ${out}"
}
# xargs exits 123 when the linter it runs fails.
expect_failure() {
    [ "${status}" -ne 0 ] || fail "$1: expected a failure: ${out}"
}
expect_out() {
    grep -Fq -- "$1" <<<"${out}" || fail "$2: expected '$1' in the output: ${out}"
}
expect_log() {
    grep -Fq -- "$1" <<<"${log}" || fail "$2: expected the mise call '$1': ${log}"
}

# require-mise-tool: a mise config is required, and the tool must be pinned.
mkdir -p "${tmp_dir}/bare/.config/mise"
run_in "${tmp_dir}/bare" "require-mise-tool dprint"
expect_status 1 "no mise config"
expect_out "::error::No mise config found." "no mise config"
touch "${tmp_dir}/bare/.config/mise/config.toml"
run_in "${tmp_dir}/bare" "require-mise-tool dprint"
expect_status 0 ".config/mise/config.toml counts as a mise config"
run "require-mise-tool dprint" FAKE_TOOLS=yamlfmt
expect_status 1 "an unpinned tool"
expect_out "::error::'dprint' is not pinned in this repository's mise config." "an unpinned tool"
[ -z "${log}" ] || fail "an unpinned tool must not run: ${log}"

# Every linter that needs a pinned tool checks for it first.
for script in dprint yamlfmt yamllint shellcheck shfmt trivy; do
    run "${script}" FAKE_TOOLS=""
    expect_status 1 "${script} without its tool"
    expect_out "::error::'${script}' is not pinned" "${script} without its tool"
    [ -z "${log}" ] || fail "${script} must not run without its tool: ${log}"
done

# dprint, yamlfmt and yamllint use the lint-config-dir config when it has one.
run dprint
expect_status 0 dprint
expect_log "${repo}: dprint check --allow-no-files" dprint
run dprint CONFIG_DIR="${config}"
expect_log "dprint check --config ${config}/dprint.json --config-discovery=false --allow-no-files" "dprint with a config dir"
run yamlfmt
expect_log "yamlfmt -lint" yamlfmt
expect_log "a.yml" yamlfmt
expect_log "sub/b.yaml" yamlfmt
run yamlfmt CONFIG_DIR="${config}"
expect_log "yamlfmt -conf ${config}/.yamlfmt.yaml -lint" "yamlfmt with a config dir"
run yamllint CONFIG_DIR="${config}"
expect_log "yamllint -c ${config}/.yamllint.yaml" "yamllint with a config dir"
run yamllint FAKE_EXIT=1
expect_failure "a failing yamllint"

# The shellcheck script checks every *.sh except the excluded paths, with the
# config dir's .shellcheckrc unless the repository has its own.
run shellcheck GITHUB_WORKSPACE="${repo}" EXCLUDE_PATTERN="vendor/*"
expect_status 0 shellcheck
expect_log "${repo}: shellcheck" shellcheck
expect_log "${repo}/a.sh" shellcheck
expect_log "${repo}/sub/b.sh" shellcheck
grep -Fq vendor <<<"${log}" && fail "shellcheck must skip the excluded paths: ${log}"
run shellcheck GITHUB_WORKSPACE="${repo}" CONFIG_DIR="${config}"
expect_log "${RUNNER_TEMP}/shellcheck-config: shellcheck" "shellcheck with a config dir"
expect_log "${repo}/vendor/v.sh" "shellcheck without an exclude"
cmp -s "${config}/.shellcheckrc" "${RUNNER_TEMP}/shellcheck-config/.shellcheckrc" ||
    fail "shellcheck must use the config dir's .shellcheckrc"
touch "${repo}/.shellcheckrc"
run shellcheck GITHUB_WORKSPACE="${repo}" CONFIG_DIR="${config}"
expect_out "::notice::.shellcheckrc already exists; using the local file" "shellcheck with a local .shellcheckrc"
expect_log "${repo}: shellcheck" "shellcheck with a local .shellcheckrc"
rm "${repo}/.shellcheckrc"
run shellcheck GITHUB_WORKSPACE="${repo}" FAKE_EXIT=1
expect_failure "a failing shellcheck"

# shfmt diffs every *.sh except the excluded paths.
run shfmt EXCLUDE_PATTERN="vendor/*"
expect_status 0 shfmt
expect_log "shfmt --diff" shfmt
expect_log "./sub/b.sh" shfmt
grep -Fq vendor <<<"${log}" && fail "shfmt must skip the excluded paths: ${log}"
run shfmt FAKE_EXIT=1
expect_failure "a failing shfmt"

# checkov, trivy and zizmor write SARIF for code scanning (checkov and trivy
# findings then don't fail the step), or gate on their exit code without it.
run checkov FAKE_EXIT=1
expect_status 0 "checkov with SARIF"
expect_log "checkov -d . --output sarif --output-file-path ${RUNNER_TEMP}" "checkov with SARIF"
run checkov UPLOAD_SARIF=false FAKE_EXIT=1
expect_status 1 "checkov without SARIF"
expect_log "checkov -d . --compact --quiet" "checkov without SARIF"
run trivy CONFIG_DIR="${config}" FAKE_EXIT=1
expect_status 0 "trivy with SARIF"
expect_log "trivy fs --config ${config}/trivy.yaml --scanners misconfig,secret --format sarif --output ${RUNNER_TEMP}/trivy.sarif ." "trivy with SARIF"
run trivy UPLOAD_SARIF=false FAKE_EXIT=1
expect_status 1 "trivy without SARIF"
expect_log "trivy fs --scanners misconfig,secret --exit-code 1 ." "trivy without SARIF"
run zizmor
expect_status 0 "zizmor with SARIF"
expect_log "zizmor --format sarif ." "zizmor with SARIF"
[ -f "${RUNNER_TEMP}/zizmor.sarif" ] || fail "zizmor must write ${RUNNER_TEMP}/zizmor.sarif"
run zizmor UPLOAD_SARIF=false FAKE_EXIT=1
expect_status 1 "zizmor without SARIF"
expect_log "${repo}: zizmor ." "zizmor without SARIF"

# The language linters see the tracked files of their language, minus every
# path the shared dprint.json excludes (vendored and generated files).
code="${tmp_dir}/code"
mkdir -p "${code}/sub"
git -C "${code}" init -q
touch "${code}/mise.toml" "${code}/a.py" "${code}/sub/b.pyi" "${code}/untracked.py" "${code}/c.sh"
excluded=()
while IFS= read -r pattern; do
    pattern="${pattern%$'\r'}" # jq on Windows ends lines with CRLF
    # **/node_modules -> sub/node_modules/x.py, .venv*/** -> .venvx/x.py
    path="${pattern/#\*\*\//sub/}"
    path="${path%/\*\*}"
    path="${path//\*/x}/x.py"
    mkdir -p "${code}/${path%/*}"
    touch "${code}/${path}"
    excluded+=("${path}")
done < <(jq -r '.excludes[] | select(endswith(".md") | not)' "${repo_root}/config-sync/files/dprint.json")
[ "${#excluded[@]}" -ge 10 ] || fail "expected the dprint.json excludes, got: ${excluded[*]}"
git -C "${code}" add -f -- mise.toml a.py sub/b.pyi c.sh "${excluded[@]}"
listed="$(cd "${code}" && bash "${scripts}/language-files.sh" python | tr '\0' '\n')"
[ "${listed}" = $'a.py\nsub/b.pyi' ] || fail "language-files.sh python must list only a.py and sub/b.pyi; got: ${listed}"
run_in "${code}" "language-files bogus"
expect_status 2 "an unknown language"

run_in "${code}" "detect-language python"
expect_status 0 "a repository with Python files"
[ "${outputs}" = found=true ] || fail "expected found=true; got: ${outputs}"
run "detect-language python"
expect_status 0 "a repository without Python files"
[ "${outputs}" = found=false ] || fail "expected found=false; got: ${outputs}"
expect_out "::notice::No python files found; skipping its linter" "a repository without Python files"

# A repository with Python files that doesn't pin ruff opts out: ruff is
# skipped with a warning that names the fix, and the step passes (#567).
run_in "${code}" ruff
expect_status 0 "ruff without its pin"
expect_out "::warning title=ruff is not pinned::" "ruff without its pin"
expect_out "pin ruff in .mise.toml" "ruff without its pin"
expect_out "ruff.toml" "ruff without its pin"
[ -z "${log}" ] || fail "ruff must not run without its pin: ${log}"
[ -z "${outputs}" ] || fail "ruff without its pin must not report a SARIF report: ${outputs}"

# ruff lints and format-checks only those files, and writes SARIF for code
# scanning without letting it gate the step.
export FAKE_TOOLS="${FAKE_TOOLS} ruff"
run_in "${code}" ruff
expect_status 0 "ruff with SARIF"
expect_log "ruff check --force-exclude --no-fix --exit-zero --output-format sarif --output-file ${RUNNER_TEMP}/ruff.sarif -- a.py sub/b.pyi" \
    "ruff with SARIF"
expect_log "ruff check --force-exclude --no-fix --output-format github -- a.py sub/b.pyi" "ruff with SARIF"
expect_log "ruff format --force-exclude --diff -- a.py sub/b.pyi" "ruff with SARIF"
[ "${outputs}" = sarif=true ] || fail "ruff must report its SARIF report; got: ${outputs}"
run_in "${code}" ruff UPLOAD_SARIF=false FAKE_EXIT=1
expect_status 1 "a failing ruff"
grep -Fq sarif <<<"${log}${outputs}" && fail "ruff without SARIF must not write it: ${log} ${outputs}"
expect_log "ruff format --force-exclude --diff" "a failing ruff check must not skip the format check"
git -C "${code}" rm -q --cached a.py sub/b.pyi
run_in "${code}" ruff
expect_status 0 "ruff without Python files"
expect_out "::notice::No Python files found; skipping ruff" "ruff without Python files"
[ -z "${log}" ] || fail "ruff must not run without Python files: ${log}"
run_in "${code}" ruff FAKE_TOOLS=""
expect_out "::notice::No Python files found; skipping ruff" "a repository without Python files must not warn about the pin"
grep -Fq '::warning' <<<"${out}" && fail "a repository without Python files must not warn about the ruff pin: ${out}"

# Biome checks the JavaScript, TypeScript, JSON and CSS files in one read-only
# `biome ci` run, which also writes SARIF when asked.
mkdir -p "${code}/.specify"
touch "${code}/a.json" "${code}/b.mjs" "${code}/sub/c.tsx" "${code}/sub/d.css" "${code}/e.md" "${code}/.specify/f.json"
git -C "${code}" add -f -- a.json b.mjs sub/c.tsx sub/d.css e.md .specify/f.json
listed="$(cd "${code}" && bash "${scripts}/language-files.sh" web | tr '\0' '\n')"
[ "${listed}" = $'a.json\nb.mjs\nsub/c.tsx\nsub/d.css' ] ||
    fail "language-files.sh web must list the JavaScript, TypeScript, JSON and CSS files; got: ${listed}"
# Biome steps aside for ESLint, unless lint-biome-with-eslint clears STEP_ASIDE_FOR.
touch "${code}/sub/.eslintrc"
git -C "${code}" add -f -- sub/.eslintrc
run_in "${code}" "detect-language web" STEP_ASIDE_FOR=eslint
[ "${outputs}" = found=false ] || fail "Biome must step aside for ESLint; got: ${outputs}"
expect_out "::notice::The repository has eslint config; skipping the web linter" "a repository with ESLint"
run_in "${code}" "detect-language web" STEP_ASIDE_FOR=
[ "${outputs}" = found=true ] || fail "lint-biome-with-eslint must run Biome; got: ${outputs}"
git -C "${code}" rm -q --cached sub/.eslintrc
run_in "${code}" "detect-language web" STEP_ASIDE_FOR=eslint
[ "${outputs}" = found=true ] || fail "Biome must run without ESLint; got: ${outputs}"
# Without a biome pin, Biome warns how to opt in and skips instead of failing.
run_in "${code}" biome FAKE_TOOLS=""
expect_status 0 "Biome without its tool"
expect_out "::warning title=biome is not pinned::" "Biome without its tool"
expect_out "pin biome in .mise.toml" "Biome without its tool"
expect_out "biome.json" "Biome without its tool"
[ -z "${log}${outputs}" ] || fail "Biome without its tool must not run: ${log} ${outputs}"
# Excluding every file skips Biome before it needs a pin.
run_in "${code}" biome FAKE_TOOLS="" EXCLUDE_PATTERN="*"
expect_status 0 "Biome with every file excluded"
expect_out "::notice::No JavaScript, TypeScript, JSON or CSS files found; skipping Biome" "Biome with every file excluded"
grep -Fq '::warning' <<<"${out}" && fail "a repository without Biome's files must not warn about the biome pin: ${out}"
export FAKE_TOOLS="${FAKE_TOOLS} biome"
biome_call="biome ci --no-errors-on-unmatched --reporter=default --reporter=github"
run_in "${code}" biome FAKE_WRITES="${RUNNER_TEMP}/biome.sarif"
expect_status 0 "Biome with SARIF"
expect_log "${biome_call} --reporter=sarif --reporter-file=${RUNNER_TEMP}/biome.sarif -- a.json b.mjs sub/c.tsx sub/d.css" \
    "Biome with SARIF"
[ "${outputs}" = sarif=true ] || fail "Biome must report its SARIF report; got: ${outputs}"
run_in "${code}" biome FAKE_EXIT=1
expect_status 1 "a failing Biome"
[ -z "${outputs}" ] || fail "Biome must not report a SARIF report it didn't write: ${outputs}"
# Biome before 2.4.0 lacks multiple reporters: it warns and skips.
run_in "${code}" biome FAKE_STDOUT="Version: 2.3.11"
expect_status 0 "Biome 2.3.11"
expect_out "::warning title=biome is too old::This repository pins biome 2.3.11" "Biome 2.3.11"
[[ "${log}" != *"biome ci"* ]] || fail "Biome 2.3.11 must not run: ${log}"
run_in "${code}" biome FAKE_STDOUT="Version: 2.4.0"
expect_log "biome ci" "Biome 2.4.0"
run_in "${code}" biome UPLOAD_SARIF=false
expect_status 0 "Biome without SARIF"
expect_log "${biome_call} -- a.json" "Biome without SARIF"
run_in "${code}" biome UPLOAD_SARIF=false EXCLUDE_PATTERN="sub/*"
[[ "${log}" == *"${biome_call} -- a.json b.mjs" ]] || fail "lint-biome-exclude must skip sub/: ${log}"
git -C "${code}" rm -q --cached a.json b.mjs sub/c.tsx sub/d.css
run_in "${code}" biome
expect_status 0 "Biome without its files"
expect_out "::notice::No JavaScript, TypeScript, JSON or CSS files found; skipping Biome" "Biome without its files"
[ -z "${log}" ] || fail "Biome must not run without its files: ${log}"

# PSScriptAnalyzer runs psscriptanalyzer.ps1 with pwsh, which is not a mise
# tool. The stand-in pwsh logs its arguments and the files of -PathList.
cat >"${tmp_dir}/bin/pwsh" <<'EOF'
#!/usr/bin/env bash
printf 'pwsh %s\n' "${*##*/scripts/lint/}" >>"${MISE_LOG}"
while [ "$#" -gt 0 ]; do
    [ "$1" != -PathList ] || printf 'files: %s\n' "$(tr '\0' ' ' <"$2")" >>"${MISE_LOG}"
    shift
done
[ -z "${FAKE_WRITES:-}" ] || touch "${FAKE_WRITES}"
exit "${FAKE_EXIT:-0}"
EOF
chmod +x "${tmp_dir}/bin/pwsh"
touch "${code}/a.ps1" "${code}/sub/b.psm1" "${code}/sub/c.psd1" "${code}/.specify/d.ps1"
git -C "${code}" add -f -- a.ps1 sub/b.psm1 sub/c.psd1 .specify/d.ps1
run_in "${code}" psscriptanalyzer
expect_status 0 "PowerShell files without psscriptanalyzer-version"
expect_out "::warning title=psscriptanalyzer-version is not set::This repository has PowerShell files, but PSScriptAnalyzer is skipped" \
    "PowerShell files without psscriptanalyzer-version"
expect_out "To lint them, pass psscriptanalyzer-version" "the skip warning must name the fix"
[ -z "${log}" ] || fail "PSScriptAnalyzer must not run without a version: ${log}"
[ -z "${outputs}" ] || fail "a skipped PSScriptAnalyzer must not report a SARIF report: ${outputs}"
export PSSCRIPTANALYZER_VERSION=1.25.0
pssa_call="pwsh -NoProfile -NonInteractive -File psscriptanalyzer.ps1 -Version 1.25.0"
pssa_call+=" -PathList ${RUNNER_TEMP}/psscriptanalyzer-files"
run_in "${code}" psscriptanalyzer FAKE_WRITES="${RUNNER_TEMP}/psscriptanalyzer.sarif"
expect_status 0 "PSScriptAnalyzer with SARIF"
expect_log "${pssa_call} -SarifFile ${RUNNER_TEMP}/psscriptanalyzer.sarif" "PSScriptAnalyzer with SARIF"
expect_log "files: a.ps1 sub/b.psm1 sub/c.psd1 " "PSScriptAnalyzer must get the PowerShell files, minus the excludes"
[ "${outputs}" = sarif=true ] || fail "PSScriptAnalyzer must report its SARIF report; got: ${outputs}"
run_in "${code}" psscriptanalyzer FAKE_EXIT=1 UPLOAD_SARIF=false
expect_status 1 "a failing PSScriptAnalyzer"
[[ "${log}" == "${pssa_call}"$'\n'* ]] || fail "PSScriptAnalyzer without SARIF: ${log}"
[ -z "${outputs}" ] || fail "PSScriptAnalyzer must not report a SARIF report it didn't write: ${outputs}"
git -C "${code}" rm -q --cached a.ps1 sub/b.psm1 sub/c.psd1
run_in "${code}" psscriptanalyzer PSSCRIPTANALYZER_VERSION=
expect_status 0 "PSScriptAnalyzer without PowerShell files"
expect_out "::notice::No PowerShell files found; skipping PSScriptAnalyzer" "PSScriptAnalyzer without PowerShell files"
[ -z "${log}" ] || fail "PSScriptAnalyzer must not run without PowerShell files: ${log}"

# The real psscriptanalyzer.ps1, when pwsh and PSScriptAnalyzer are installed
# (ubuntu-24.04 runners ship both): it analyzes file names with wildcard
# characters literally, and the template's settings keep parse errors.
pssa_version=""
if [ -n "${real_pwsh}" ]; then
    pssa_version="$("${real_pwsh}" -NoProfile -Command \
        '(Get-Module -ListAvailable PSScriptAnalyzer | Sort-Object Version | Select-Object -Last 1).Version.ToString()' |
        tr -d '\r')" || true
fi
if [ -z "${pssa_version}" ]; then
    echo "::notice::pwsh or PSScriptAnalyzer is not installed; skipping the psscriptanalyzer.ps1 run"
else
    ps_dir="${tmp_dir}/powershell"
    mkdir -p "${ps_dir}"
    printf 'gci\n' >"${ps_dir}/deploy[1].ps1"
    printf 'Get-ChildItem\n' >"${ps_dir}/deploy1.ps1"
    printf 'function Get-X {\n' >"${ps_dir}/broken.ps1"
    cp "${repo_root}/config-sync/templates/PSScriptAnalyzerSettings.psd1" "${ps_dir}/"
    ps1="${scripts}/psscriptanalyzer.ps1"
    if command -v cygpath >/dev/null 2>&1; then ps1="$(cygpath -w "${ps1}")"; fi
    # Analyzes the files $@ of ${ps_dir}; sets status and out.
    run_pssa() {
        printf '%s\0' "$@" >"${ps_dir}/files"
        status=0
        out="$(cd "${ps_dir}" &&
            "${real_pwsh}" -NoProfile -NonInteractive -File "${ps1}" -Version "${pssa_version}" -PathList files 2>&1)" ||
            status=$?
        out="${out//$'\r'/}"
    }
    run_pssa 'deploy[1].ps1' deploy1.ps1
    expect_status 1 "PSScriptAnalyzer on deploy[1].ps1"
    expect_out "::warning file=deploy[1].ps1,line=1,col=1,title=PSAvoidUsingCmdletAliases::" \
        "deploy[1].ps1 must be analyzed, not deploy1.ps1 twice"
    run_pssa deploy1.ps1
    expect_status 0 "PSScriptAnalyzer on a clean file"
    run_pssa broken.ps1
    expect_status 1 "a script that doesn't parse, with the template settings"
    expect_out "::error file=broken.ps1," "a script that doesn't parse, with the template settings"
fi

# The SARIF filter drops checkov's skipped checks (level none) and tolerates a
# missing report.
run checkov-sarif-filter
expect_status 0 "the SARIF filter without a report"
mkdir -p "${RUNNER_TEMP}"
sarif='{"runs":[{"results":[{"ruleId":"skipped","level":"none"},{"ruleId":"found","level":"error"}]}]}'
(cd "${repo}" && printf '%s\n' "${sarif}" >"${RUNNER_TEMP}/results_sarif.sarif" && bash "${scripts}/checkov-sarif-filter.sh") ||
    fail "the SARIF filter failed"
[ "$(jq -c '[.runs[].results[].ruleId]' "${RUNNER_TEMP}/results_sarif.sarif")" = '["found"]' ] ||
    fail "the SARIF filter must keep only reported checks: $(cat "${RUNNER_TEMP}/results_sarif.sarif")"

# Go linting runs only when the Go version file exists, and then needs a
# golangci-lint version.
run go-version-file GO_VERSION_FILE=go.mod
expect_status 0 "a repository without go.mod"
[ "${outputs}" = exists=false ] || fail "expected exists=false; got: ${outputs}"
expect_out "::notice::go.mod not found; skipping Go linter" "a repository without go.mod"
touch "${repo}/go.mod"
run go-version-file GO_VERSION_FILE=go.mod
[ "${outputs}" = exists=true ] || fail "expected exists=true; got: ${outputs}"
rm "${repo}/go.mod"
run golangci-lint-version GO_VERSION_FILE=go.mod
expect_status 1 "a Go repository without golangci-lint-version"
expect_out "::error::Go linting is required (go.mod found) but no golangci-lint-version input was provided." \
    "a Go repository without golangci-lint-version"

# The single-job mode accepts auto and single only (parallel never reaches it).
for mode in auto single; do
    run lint-job-mode LINT_JOB_MODE="${mode}"
    expect_status 0 "lint-job-mode ${mode}"
done
run lint-job-mode LINT_JOB_MODE=bogus
expect_status 1 "an unknown lint-job-mode"
expect_out "::error::lint-job-mode must be one of: auto, single, parallel (got 'bogus')." "an unknown lint-job-mode"

# The single-job report lists every step and fails on any failure.
passed='{"dprint":{"outcome":"success"},"go":{"outcome":"skipped"}}'
run report-results STEP_RESULTS="${passed}" JOB_STATUS=success
expect_status 0 "passing linters"
expect_out "All enabled linters passed." "passing linters"
# shellcheck disable=SC2016 # literal backticks
grep -Fqx '| `go` | skipped |' <<<"${summary}" || fail "the summary must list every step; got: ${summary}"
failed='{"dprint":{"outcome":"failure"},"shfmt":{"outcome":"success"},"trivy":{"outcome":"failure"}}'
run report-results STEP_RESULTS="${failed}" JOB_STATUS=success
expect_status 1 "failing linters"
expect_out "::error::Lint step 'dprint' failed; see its log above." "failing linters"
expect_out "::error::Lint step 'trivy' failed; see its log above." "failing linters"
grep -Fq "'shfmt'" <<<"${out}" && fail "a passing step must not be reported as failed: ${out}"
run report-results STEP_RESULTS="${passed}" JOB_STATUS=failure
expect_status 1 "a failed setup step"
expect_out "::error::A setup step failed before the linters could run" "a failed setup step"

# Config drift compares every central config file that exists locally.
echo "same" >"${FAKE_CENTRAL}/.editorconfig"
echo "central" >"${FAKE_CENTRAL}/.yamllint.yaml"
echo "missing" >"${FAKE_CENTRAL}/dprint.json"
echo "same" >"${repo}/.editorconfig"
echo "central" >"${repo}/.yamllint.yaml"
run config-drift
expect_status 0 "config without drift"
expect_out "✓ .editorconfig matches" "config without drift"
expect_out "::warning::dprint.json exists in central repo but not locally (skipping)" "config without drift"
expect_out "All config files match the central repository." "config without drift"
echo "local" >"${repo}/.yamllint.yaml"
run config-drift
expect_status 1 "drifted config"
expect_out "::error::.yamllint.yaml has drifted from central config" "drifted config"
expect_out "+central" "drifted config"

echo "lint scripts: OK"

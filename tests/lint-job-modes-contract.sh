#!/usr/bin/env bash
#
# Contract test for the two lint scheduling modes in .github/workflows/lint.yml.
#
# `lint-job-mode: parallel` runs one job per linter; `single` runs every linter
# as a step of the `all-linters` job (ADR 0010). Both modes run the same scripts
# from scripts/lint/ (#537). This test keeps the two `run:` lines of each linter
# identical and the job guards mutually exclusive, so a fix made to one mode
# cannot silently miss the other, and checks that every job fetches the scripts
# it runs.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="${repo_root}/.github/workflows/lint.yml"
combined_job="all-linters"
linter_jobs=(dprint yamlfmt yamllint actionlint gitleaks go shellcheck shfmt checkov trivy zizmor ruff biome psscriptanalyzer config-drift inline-scripts line-endings attestations)
parallel_guard="(inputs.lint-job-mode == 'parallel' || (inputs.lint-job-mode == 'auto' && !github.event.repository.private))"

fail() {
    echo "error: $*" >&2
    exit 1
}

# Print the `run:` line and its block (verbatim, trailing blank lines dropped)
# of the step named $2 in job $1. Steps are expected at the standard
# 6-space list indentation used throughout lint.yml.
extract_run() {
    awk -v job="$1" -v step="$2" '
        /^[^[:space:]#]/ {
            if (in_run) exit
            in_job = 0
            next
        }
        /^  [A-Za-z0-9_-]+:[[:space:]]*$/ {
            if (in_run) exit
            name = $0
            sub(/^  /, "", name)
            sub(/:[[:space:]]*$/, "", name)
            in_job = (name == job)
            in_step = 0
            next
        }
        in_job && /^      - / {
            if (in_run) exit
            name = ""
            if ($0 ~ /^      - name: /) {
                name = $0
                sub(/^      - name: /, "", name)
            }
            in_step = (name == step)
            next
        }
        in_job && in_step && !in_run && /^        run:/ {
            print
            if ($0 ~ /^        run: *[|>][-+]?[[:space:]]*$/) {
                in_run = 1
                next
            }
            exit
        }
        in_run {
            if ($0 ~ /^[[:space:]]*$/) {
                blank = blank $0 "\n"
                next
            }
            if ($0 !~ /^          /) exit
            printf "%s", blank
            blank = ""
            print
        }
    ' "${workflow}"
}

# Names of the steps in job $1 that have a `run:` key.
run_step_names() {
    awk -v job="$1" '
        /^[^[:space:]#]/ { in_job = 0; next }
        /^  [A-Za-z0-9_-]+:[[:space:]]*$/ {
            name = $0
            sub(/^  /, "", name)
            sub(/:[[:space:]]*$/, "", name)
            in_job = (name == job)
            step = ""
            next
        }
        in_job && /^      - / {
            step = ""
            if ($0 ~ /^      - name: /) {
                step = $0
                sub(/^      - name: /, "", step)
            }
            next
        }
        in_job && step != "" && /^        run:/ { print step }
    ' "${workflow}"
}

# Value of the job-level `if:` of job $1, with YAML line folding applied
# (yamlfmt wraps long conditions onto continuation lines).
job_if() {
    awk -v job="$1" '
        /^[^[:space:]#]/ { in_job = 0; next }
        /^  [A-Za-z0-9_-]+:[[:space:]]*$/ {
            if (in_if) exit
            name = $0
            sub(/^  /, "", name)
            sub(/:[[:space:]]*$/, "", name)
            in_job = (name == job)
            next
        }
        in_if {
            if ($0 !~ /^      /) exit
            line = $0
            sub(/^[[:space:]]+/, "", line)
            value = (value == "" ? line : value " " line)
            next
        }
        in_job && /^    if:/ {
            value = $0
            sub(/^    if:[[:space:]]*/, "", value)
            if (value ~ /^[|>][-+]?$/) value = ""
            in_if = 1
        }
        END { print value }
    ' "${workflow}"
}

# The mode input exists, defaults to auto, and is documented.
mode_input="$(sed -n '/^      lint-job-mode:/,/^permissions:/p' "${workflow}")"
[ -n "${mode_input}" ] || fail "lint-job-mode input is missing"
grep -Fq 'default: auto' <<<"${mode_input}" || fail "lint-job-mode must default to auto"
grep -Fq 'required: false' <<<"${mode_input}" || fail "lint-job-mode must stay optional"

# Exactly one mode runs: per-linter jobs carry the parallel guard, the
# combined job its negation.
for job in "${linter_jobs[@]}"; do
    condition="$(job_if "${job}")"
    [ "${condition}" = "\${{ inputs.lint-${job} && ${parallel_guard} }}" ] ||
        fail "job ${job} must use: if: \${{ inputs.lint-${job} && ${parallel_guard} }} (found: ${condition})"
done
condition="$(job_if "${combined_job}")"
[ "${condition}" = "\${{ !${parallel_guard} }}" ] ||
    fail "job ${combined_job} must use: if: \${{ !${parallel_guard} }} (found: ${condition})"

# Every run script of every per-linter job is repeated verbatim in the
# combined job.
compared=0
for job in "${linter_jobs[@]}"; do
    while IFS= read -r step; do
        [ -n "${step}" ] || continue
        expected="$(extract_run "${job}" "${step}")"
        actual="$(extract_run "${combined_job}" "${step}")"
        [ -n "${actual}" ] ||
            fail "${combined_job} has no step '${step}' (from job ${job})"
        if [ "${expected}" != "${actual}" ]; then
            diff <(printf '%s\n' "${expected}") <(printf '%s\n' "${actual}") >&2 || true
            fail "step '${step}' differs between job ${job} and ${combined_job}; keep both copies identical"
        fi
        compared=$((compared + 1))
    done < <(run_step_names "${job}")
done
[ "${compared}" -ge "${#linter_jobs[@]}" ] || fail "expected at least ${#linter_jobs[@]} run steps, compared ${compared}"

# The linter scripts live in scripts/ of this repository (#537). lint.yml runs
# in the caller's checkout, so every job that runs one first checks the scripts
# out from the caller's pinned commit of DevSecNinja/.github and moves them out
# of the workspace, with identical steps in every job.
fetch_step="Checkout lint scripts"
move_step="Move lint scripts out of the workspace"

# The text of step $2 of job $1, from its `- name:` line to the next step.
step_block() {
    awk -v job="$1" -v step="$2" '
        /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { if (in_step) exit; in_job = ($0 == "  " job ":"); next }
        in_job && /^      - / { if (in_step) exit; in_step = ($0 == "      - name: " step) }
        in_step && !/^[[:space:]]*$/ { print }
    ' "${workflow}"
}

# "job|first step|second step" for every job that runs a fetched script.
script_jobs="$(
    awk '
        function flush() { if (job != "" && uses) print job "|" first "|" second }
        /^  [A-Za-z0-9_-]+:[[:space:]]*$/ {
            flush()
            job = $0
            sub(/^  /, "", job)
            sub(/:[[:space:]]*$/, "", job)
            steps = 0; first = ""; second = ""; uses = 0
            next
        }
        /^      - name: / {
            steps++
            name = $0
            sub(/^      - name: /, "", name)
            if (steps == 1) first = name
            if (steps == 2) second = name
        }
        /^        run: .*\$\{RUNNER_TEMP\}\/devsecninja-lint\// { uses = 1 }
        END { flush() }
    ' "${workflow}"
)"
reference_fetch="$(step_block "${combined_job}" "${fetch_step}")"
# shellcheck disable=SC2016 # literal workflow expression
grep -Fq 'ref: ${{ job.workflow_sha }}' <<<"${reference_fetch}" ||
    fail "'${fetch_step}' must check out job.workflow_sha, the commit the caller pinned"
script_job_count=0
while IFS='|' read -r job first second; do
    [ -n "${job}" ] || continue
    [ "${first}|${second}" = "${fetch_step}|${move_step}" ] ||
        fail "job ${job} runs lint scripts, so its first steps must be '${fetch_step}' and '${move_step}' (found '${first}', '${second}')"
    [ "$(step_block "${job}" "${fetch_step}")" = "${reference_fetch}" ] ||
        fail "job ${job}: '${fetch_step}' differs from the one in ${combined_job}; keep them identical"
    script_job_count=$((script_job_count + 1))
done <<<"${script_jobs}"
for job in "${linter_jobs[@]}" "${combined_job}"; do
    [ "${job}" = actionlint ] && continue
    grep -q "^${job}|" <<<"${script_jobs}" || fail "job ${job} runs no script from scripts/"
done

# Every fetched script exists, and the sparse checkout includes it.
script_count=0
while IFS= read -r script; do
    [ -f "${repo_root}/${script}" ] || fail "lint.yml runs ${script}, which does not exist"
    grep -Eq "^            ${script%/*}/$|^            ${script}$" <<<"${reference_fetch}" ||
        fail "'${fetch_step}' does not check out ${script}"
    script_count=$((script_count + 1))
done < <(
    grep -oE '^        run: .*"\$\{RUNNER_TEMP\}/devsecninja-lint/[^"]+"' "${workflow}" |
        sed -E 's|.*/devsecninja-lint/||; s|"$||' | sort -u
)

# Every linter toggle gates a step of the combined job.
combined_block="$(sed -n "/^  ${combined_job}:/,\$p" "${workflow}")"
for job in "${linter_jobs[@]}"; do
    grep -Fq "inputs.lint-${job}" <<<"${combined_block}" ||
        fail "${combined_job} never checks inputs.lint-${job}"
done

# Every mise-action step installs the caller's whole mise toolset. A scoped
# install such as `install_args: "uv pipx:yamllint"` skips a Python the caller
# configures (for example through `.python-version`), and mise then refuses the
# pipx tool: "requires configured install dependency 'python@…', but its
# selected version is not installed" (#502). A full `mise install` orders
# Python before the pipx tools, and installs no Python when none is configured.
mise_steps="$(
    awk '
        function flush() {
            if (is_mise) print job "|" has_install "|" has_args
            is_mise = 0
        }
        /^  [A-Za-z0-9_-]+:[[:space:]]*$/ {
            flush()
            job = $0
            sub(/^  /, "", job)
            sub(/:[[:space:]]*$/, "", job)
            next
        }
        /^      - / { flush(); has_install = 0; has_args = 0 }
        /uses: jdx\/mise-action@/ { is_mise = 1 }
        /^          ["'\'']?install["'\'']?[[:space:]]*:[[:space:]]*["'\'']?true["'\'']?[[:space:]]*(#.*)?$/ { has_install = 1 }
        # Any non-comment mention, so quoted keys and flow mappings count too.
        /^[^#]*install_args/ { has_args = 1 }
        END { flush() }
    ' "${workflow}"
)"
mise_count=0
while IFS='|' read -r job has_install has_args; do
    [ -n "${job}" ] || continue
    [ "${has_install}" = 1 ] || fail "job ${job}: jdx/mise-action must set 'install: true'"
    [ "${has_args}" = 0 ] ||
        fail "job ${job}: jdx/mise-action must not set install_args; scoped installs skip the caller's Python that pipx tools need (#502)"
    mise_count=$((mise_count + 1))
done <<<"${mise_steps}"
for job in yamllint checkov "${combined_job}"; do
    grep -q "^${job}|" <<<"${mise_steps}" || fail "job ${job} runs a pipx tool but has no jdx/mise-action step"
done

echo "✓ lint.yml: ${#linter_jobs[@]} linters, ${compared} run scripts identical across parallel and single-job modes."
echo "✓ lint.yml: ${script_job_count} jobs fetch the ${script_count} scripts they run from the caller's pinned commit."
echo "✓ lint.yml: ${mise_count} mise-action steps install the caller's full toolset (pipx tools get their Python)."

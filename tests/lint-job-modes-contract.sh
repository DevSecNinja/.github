#!/usr/bin/env bash
#
# Contract test for the two lint scheduling modes in .github/workflows/lint.yml.
#
# `lint-job-mode: parallel` runs one job per linter; `single` runs every linter
# as a step of the `all-linters` job (ADR 0010). The linter scripts therefore
# exist twice. This test keeps the copies identical and the job guards
# mutually exclusive, so a fix made to one mode cannot silently miss the other.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="${repo_root}/.github/workflows/lint.yml"
combined_job="all-linters"
linter_jobs=(dprint yamlfmt yamllint actionlint gitleaks go shellcheck shfmt checkov trivy zizmor config-drift)
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

# Every linter toggle gates a step of the combined job.
combined_block="$(sed -n "/^  ${combined_job}:/,\$p" "${workflow}")"
for job in "${linter_jobs[@]}"; do
    grep -Fq "inputs.lint-${job}" <<<"${combined_block}" ||
        fail "${combined_job} never checks inputs.lint-${job}"
done

echo "✓ lint.yml: ${#linter_jobs[@]} linters, ${compared} run scripts identical across parallel and single-job modes."

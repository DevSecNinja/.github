#!/usr/bin/env bash
#
# Tests the gitleaks steps of .github/workflows/lint.yml (#501): "Run gitleaks"
# writes a redacted JSON report, and "Report gitleaks findings" turns it into
# one `::error file=,line=` annotation per finding plus a step-summary table.
#
# Both scripts are extracted from the parallel `gitleaks` job (the contract test
# keeps the single-job copies identical) and run against a scratch repository
# that commits an obviously fake GitHub token. The test asserts the annotation
# format, the summary row, the unchanged exit code, and that the raw token
# never appears in any output. The token is generated at test time so no
# committed fixture trips the repository's own secret scan.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="${repo_root}/.github/workflows/lint.yml"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

fail() {
    echo "error: $*" >&2
    exit 1
}

command -v gitleaks >/dev/null 2>&1 || fail "gitleaks is not installed; run 'mise install'"
command -v jq >/dev/null 2>&1 || fail "jq is not installed"

# Body of the `run: |-` block of step $1 in the `gitleaks` job, dedented.
extract_run() {
    awk -v step="$1" '
        /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { in_job = ($0 == "  gitleaks:"); next }
        in_job && /^      - / { if (in_run) exit; in_step = ($0 == "      - name: " step); next }
        in_job && in_step && /^        run: \|-$/ { in_run = 1; next }
        in_run {
            if ($0 !~ /^          / && $0 !~ /^[[:space:]]*$/) exit
            sub(/^          /, "")
            print
        }
    ' "${workflow}"
}

run_script="$(extract_run "Run gitleaks")"
report_script="$(extract_run "Report gitleaks findings")"
grep -Fq -- '--report-format json' <<<"${run_script}" || fail "'Run gitleaks' must write a JSON report"
grep -Fq -- '--redact' <<<"${run_script}" || fail "'Run gitleaks' must keep --redact"
[ -n "${report_script}" ] || fail "the gitleaks job has no 'Report gitleaks findings' step"

# Stand-in for mise: the workflow calls `mise which` and `mise exec --`.
mkdir -p "${tmp_dir}/bin"
cat >"${tmp_dir}/bin/mise" <<'EOF'
#!/usr/bin/env bash
case "$1" in
which) command -v "$2" ;;
exec) shift 2 && exec "$@" ;;
*) exit 2 ;;
esac
EOF
chmod +x "${tmp_dir}/bin/mise"

chars="$(head -c 4096 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9')"
[ "${#chars}" -ge 36 ] || fail "could not generate random fixture data"
fake_token="ghp_${chars:0:36}"

# Runs both steps in a fresh repository named $1 whose single commit holds
# file $2 with content $3 (when given), scanned with the .gitleaks.toml in
# $config_dir (the default rules when empty). Sets status (the gitleaks step's
# exit code), out (both steps' combined output) and summary.
config_dir=""
scan() {
    local repo="${tmp_dir}/$1" temp="${tmp_dir}/$1-runner-temp"
    mkdir -p "${repo}" "${temp}"
    : >"${tmp_dir}/$1-summary.md"
    (
        cd "${repo}"
        git init -q
        git config user.name test
        git config user.email test@example.invalid
        git config commit.gpgsign false
        touch mise.toml
        [ -z "${2:-}" ] || printf '%s\n' "$3" >"$2"
        git add -A
        git commit -qm fixture
    )
    status=0
    (cd "${repo}" && PATH="${tmp_dir}/bin:${PATH}" RUNNER_TEMP="${temp}" CONFIG_DIR="${config_dir}" \
        bash -eo pipefail -c "${run_script}") >"${tmp_dir}/$1.out" 2>&1 || status=$?
    (cd "${repo}" && RUNNER_TEMP="${temp}" GITHUB_STEP_SUMMARY="${tmp_dir}/$1-summary.md" \
        FINDINGS_ARTIFACT=gitleaks-findings-42 bash -eo pipefail -c "${report_script}") >>"${tmp_dir}/$1.out" 2>&1 ||
        fail "'Report gitleaks findings' failed on $1: $(cat "${tmp_dir}/$1.out")"
    out="$(cat "${tmp_dir}/$1.out")"
    summary="$(cat "${tmp_dir}/$1-summary.md")"
}

scan leak "fake,token.txt" "token = \"${fake_token}\""
[ "${status}" -eq 1 ] || fail "gitleaks must still exit 1 on a leak (got ${status}): ${out}"
commit="$(git -C "${tmp_dir}/leak" rev-parse --short=7 HEAD)"
annotation="::error file=fake%2Ctoken.txt,line=1,title=gitleaks github-pat::github-pat in commit ${commit} (secret redacted)"
grep -Fqx -- "${annotation}" <<<"${out}" ||
    fail "expected annotation '${annotation}'; got: ${out}"
[ "$(grep -c '^::error file=' <<<"${out}")" -eq 1 ] || fail "expected exactly one annotation; got: ${out}"
grep -Eq "^\| github-pat \| fake,token\.txt:1 \| ${commit} \| [0-9]{4}-[0-9]{2}-[0-9]{2}T" <<<"${summary}" ||
    fail "the step summary must list rule, file:line, commit and date; got: ${summary}"
# shellcheck disable=SC2016 # literal backticks
grep -Fq '`gitleaks-findings-42` artifact' <<<"${summary}" ||
    fail "the step summary must name the job's findings artifact; got: ${summary}"
# A caller may run lint.yml twice in one run (lint-caller.yml runs both modes),
# so each upload needs a job-unique artifact name.
artifact_names="$(grep -E '^          name: gitleaks-findings' "${workflow}" | sort -u)"
# shellcheck disable=SC2016 # literal workflow expression
[ "${artifact_names}" = '          name: gitleaks-findings-${{ job.check_run_id }}' ] ||
    fail "the gitleaks-findings artifact name must be unique per job; got: ${artifact_names}"
for artifact in "${tmp_dir}/leak.out" "${tmp_dir}/leak-summary.md" \
    "${tmp_dir}/leak-runner-temp/gitleaks-report.json" "${tmp_dir}/leak-runner-temp/gitleaks-findings.json"; do
    [ -f "${artifact}" ] || fail "missing ${artifact##*/}"
    if grep -Fq -- "${chars:0:36}" "${artifact}"; then
        fail "the raw secret leaked into ${artifact##*/}"
    fi
done

# A path-only rule reports StartLine 0; annotate the file without a line.
config_dir="${tmp_dir}/path-rule-config"
mkdir -p "${config_dir}"
cat >"${config_dir}/.gitleaks.toml" <<'EOF'
[[rules]]
id = "fake-key-file"
description = "Fake key file"
path = '''\.fakekey$'''
EOF
scan pathonly "id.fakekey" "not a real key"
config_dir=""
[ "${status}" -eq 1 ] || fail "gitleaks must exit 1 on a path-only finding (got ${status}): ${out}"
commit="$(git -C "${tmp_dir}/pathonly" rev-parse --short=7 HEAD)"
annotation="::error file=id.fakekey,title=gitleaks fake-key-file::fake-key-file in commit ${commit} (secret redacted)"
grep -Fqx -- "${annotation}" <<<"${out}" ||
    fail "expected file-level annotation '${annotation}'; got: ${out}"
grep -Eq "^\| fake-key-file \| id\.fakekey \| ${commit} \| " <<<"${summary}" ||
    fail "a path-only finding must list the file without a line; got: ${summary}"

scan clean
[ "${status}" -eq 0 ] || fail "gitleaks must pass a clean repository (got ${status}): ${out}"
if grep -q '^::error' <<<"${out}" || [ -n "${summary}" ]; then
    fail "a clean scan must not annotate or write a summary; got: ${out}${summary}"
fi

echo "gitleaks report: OK"

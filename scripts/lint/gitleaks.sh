#!/usr/bin/env bash
#
# Scans for secrets with gitleaks (#501, #520, #525).
# A step of .github/workflows/lint.yml, run the same way in both lint modes.
# Env: CONFIG_DIR, BASE_SHA, HEAD_SHA, BASE_REF, UPLOAD_SARIF, GH_TOKEN; writes mode= and sarif= to GITHUB_OUTPUT.

set -eo pipefail

bash "$(dirname "${BASH_SOURCE[0]}")/require-mise-tool.sh" gitleaks
config_args=()
if [ -n "${CONFIG_DIR}" ] && [ -f "${CONFIG_DIR}/.gitleaks.toml" ]; then
    config_args=(--config "${CONFIG_DIR}/.gitleaks.toml")
fi
# --redact keeps the secret out of every report.
report="${RUNNER_TEMP}/gitleaks-report.json"

# Pull requests (and merge queues) scan only their own commits, so
# old history never shows up on an unrelated PR, and a secret added
# in the PR fails it. The next step annotates those findings.
if [ -n "${BASE_SHA}" ] && [ -n "${HEAD_SHA}" ]; then
    echo "mode=pr" >>"${GITHUB_OUTPUT}"
    for sha in "${BASE_SHA}" "${HEAD_SHA}"; do
        if ! git cat-file -e "${sha}^{commit}" 2>/dev/null; then
            echo "::error::Commit ${sha} of this pull request isn't checked out (pull_request_target?), so its commits can't be scanned."
            exit 1
        fi
    done
    # Also skip commits already on the base branch's current tip: the
    # event's base SHA can be older when the PR merged newer commits.
    range="${HEAD_SHA} --not ${BASE_SHA}"
    if base_tip="$(git rev-parse --verify -q "refs/remotes/origin/${BASE_REF#refs/heads/}^{commit}")"; then
        range="${range} ${base_tip}"
    fi
    mise exec -- gitleaks detect --redact --log-opts="${range}" \
        --report-format json --report-path "${report}" "${config_args[@]}"
    exit 0
fi

# Other events (push, schedule, dispatch) scan the full history, so
# new gitleaks rules re-check old commits. This only reports, so the
# findings are triaged as alerts. Job logs of public repositories are
# public: there the findings go only to code scanning, and the log
# shows a count. Internal repositories (logs visible enterprise-wide)
# and a failed visibility lookup count as public.
if [ "$(gh api "repos/${GITHUB_REPOSITORY}" --jq .visibility 2>/dev/null)" = private ]; then
    mode=history-private
    format=json
else
    mode=history-public
    format=sarif
    report="${RUNNER_TEMP}/gitleaks-history.sarif"
fi
echo "mode=${mode}" >>"${GITHUB_OUTPUT}"
status=0
log="${RUNNER_TEMP}/gitleaks-history.log"
mise exec -- gitleaks detect --redact --exit-code 42 \
    --report-format "${format}" --report-path "${report}" "${config_args[@]}" >"${log}" 2>&1 || status=$?
if [ "${mode}" = history-private ]; then
    cat "${log}"
fi
rm -f "${log}"
if [ "${status}" -ne 0 ] && [ "${status}" -ne 42 ]; then
    if [ "${mode}" = history-public ]; then
        # gitleaks' diagnostics can name findings (for example an invalid
        # .gitleaksignore entry), and this log is public: withhold them.
        echo "::error::gitleaks failed (exit ${status}). Its log is withheld because job logs of public repositories are public: run gitleaks on a private clone to see why."
    fi
    exit "${status}"
fi
if [ "${mode}" = history-private ]; then
    count="$(jq length "${report}")"
    where="See the job summary."
else
    # Make the SARIF valid for code scanning, whose upload would
    # otherwise log invalid URIs (file paths) or reject path-only
    # findings (line 0): percent-encode paths, drop empty regions.
    # Without a security-severity, code scanning files the findings as
    # non-security warnings.
    jq '(.runs[].results[].locations[]?.physicalLocation) |= (
      .artifactLocation.uri |= (split("/") | map(@uri) | join("/"))
      | if .region then .region |= with_entries(select(.value | type != "number" or . >= 1)) else . end
      | if (.region.startLine // 0) < 1 then del(.region) else . end
    )
    # Leaked secrets are security alerts: high severity, error level.
    | (.runs[].tool.driver.rules[]?.properties) |= ((. // {}) + {"security-severity": "8.0"}
        | .tags = ((.tags // []) + ["security", "secret"]))
    | (.runs[].results[]?.level) = "error"
    # The upload also rejects repeated tags, which gitleaks copies from rules.
    | walk(if type == "object" then (if (.tags | type) == "array" then .tags |= unique else . end) else . end)
  ' "${report}" >"${report}.tmp"
    mv "${report}.tmp" "${report}"
    count="$(jq '[.runs[].results[]] | length' "${report}")"
    where="They are in code scanning (category gitleaks/history), visible only with write access."
    if [ "${UPLOAD_SARIF}" != true ]; then
        where="upload-sarif is off, so they are not published: run gitleaks on a private clone."
    elif [ "${RUNNER_DEBUG:-}" = 1 ]; then
        # With debug logging the upload logs file paths it can't fingerprint.
        where="Debug logging is on, so the code scanning upload is skipped: re-run without it."
    else
        echo "sarif=true" >>"${GITHUB_OUTPUT}"
    fi
fi
if [ "${count}" -gt 0 ]; then
    echo "::warning::gitleaks found ${count} finding(s) in the git history. ${where}"
fi

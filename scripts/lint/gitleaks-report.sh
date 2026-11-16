#!/usr/bin/env bash
#
# Turns the gitleaks report into annotations and a step-summary table.
# A step of .github/workflows/lint.yml, run the same way in both lint modes.
# Env: SCAN_MODE (the gitleaks step's mode output), FINDINGS_ARTIFACT.

set -eo pipefail

# Turns the gitleaks report into one annotation per finding and a
# step-summary table. Only the rule, location, commit and date leave
# the report: never the secret, the match or the matched line. On
# public repositories only PR findings get here: full-history
# findings go to code scanning, never to the public log.
case "${SCAN_MODE}" in
pr) level=error scope="this pull request's commits" ;;
history-private) level=warning scope="the git history" ;;
*) exit 0 ;;
esac
report="${RUNNER_TEMP}/gitleaks-report.json"
findings="${RUNNER_TEMP}/gitleaks-findings.json"
[ -s "${report}" ] || exit 0
jq '[.[] | {RuleID, Description, File, StartLine, EndLine, Commit, Date, Fingerprint}]' \
    "${report}" >"${findings}"
count="$(jq length "${findings}")"
if [ "${count}" -eq 0 ]; then
    rm -f "${findings}"
    exit 0
fi

jq -r --arg level "${level}" '
  def msg: tostring | gsub("%"; "%25") | gsub("\r"; "%0D") | gsub("\n"; "%0A");
  def prop: msg | gsub(":"; "%3A") | gsub(","; "%2C");
  # Path-only rules report StartLine 0; annotate those at file level.
  .[] | "::\($level) file=\(.File | prop)\(if .StartLine > 0 then ",line=\(.StartLine)" else "" end)"
    + ",title=gitleaks \(.RuleID | prop)::"
    + "\(.RuleID | msg) in commit \((.Commit // "")[0:7] | msg) (secret redacted)"
' "${findings}"

{
    echo "### gitleaks: ${count} finding(s) in ${scope}"
    echo ""
    echo "Secrets are redacted. To accept a false positive, add its fingerprint (in the"
    echo "\`${FINDINGS_ARTIFACT}\` artifact) to \`.gitleaksignore\`; rotate any real secret."
    echo ""
    echo "| Rule | File:line | Commit | Author date |"
    echo "| ---- | --------- | ------ | ----------- |"
    jq -r '
    def cell: tostring | gsub("\\|"; "\\|") | gsub("[\r\n]"; " ");
    .[] | "| \(.RuleID | cell) | \(.File | cell)\(if .StartLine > 0 then ":\(.StartLine)" else "" end)"
      + " | \((.Commit // "")[0:7]) | \(.Date | cell) |"
  ' "${findings}"
} >>"${GITHUB_STEP_SUMMARY}"

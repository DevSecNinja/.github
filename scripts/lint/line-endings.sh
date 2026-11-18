#!/usr/bin/env bash
#
# Fails when a tracked text file is committed with CRLF (or mixed) line
# endings, using git's own attribute resolution (`git ls-files --eol`):
# a path whose .gitattributes rule unsets `text` (`-text`, or `binary`) is
# stored byte for byte and skipped. An `eol=crlf` path passes once git
# stores it with LF (it only checks it out with CRLF); one still stored
# with CRLF is reported, like any other, until `git add --renormalize`.
# A step of .github/workflows/lint.yml, run the same way in both lint modes.
# Env: LINT_LINE_ENDINGS_BLOCKING (true: errors, fail; false: warnings only).

set -euo pipefail
# Bytes, not characters: in a UTF-8 locale `read -d ''` can swallow the NUL
# after a path that ends in an incomplete multibyte sequence.
export LC_ALL=C

blocking="${LINT_LINE_ENDINGS_BLOCKING:-true}"
case "${blocking}" in
true) level=error ;;
false) level=warning ;;
*)
    echo "::error::lint-line-endings-blocking must be true or false (got '${blocking}')."
    exit 2
    ;;
esac

# Escapes the message of a workflow command, and (escape_property) a
# property value such as file=....
escape_data() {
    local value="$1"
    value="${value//%/%25}"
    value="${value//$'\r'/%0D}"
    value="${value//$'\n'/%0A}"
    printf '%s' "${value}"
}
escape_property() {
    local value
    value="$(escape_data "$1")"
    value="${value//:/%3A}"
    value="${value//,/%2C}"
    printf '%s' "${value}"
}

max_annotations=50
checked=0
found=()
# A file, not a process substitution: `set -e` then stops on a failing
# `git ls-files` (no repository, dubious ownership) instead of passing.
listing="$(mktemp)"
trap 'rm -f "${listing}"' EXIT
git ls-files --eol -z >"${listing}"
# Each record is "i/<index eol> w/<worktree eol> attr/<attributes>\t<path>";
# split at the first tab only, so a path keeps its own tabs.
while IFS= read -r -d '' record; do
    checked=$((checked + 1))
    info="${record%%$'\t'*}"
    path="${record#*$'\t'}"
    case "${info%% *}" in
    i/crlf | i/mixed) ;;
    *) continue ;;
    esac
    attributes="${info#*attr/}"
    case " ${attributes} " in
    *" -text "*) continue ;;
    *) ;;
    esac
    found+=("${path}")
done <"${listing}"

if [ "${#found[@]}" -eq 0 ]; then
    echo "✓ No text file is committed with CRLF line endings (${checked} files checked)."
    exit 0
fi

for path in "${found[@]:0:${max_annotations}}"; do
    echo "::${level} file=$(escape_property "${path}"),title=CRLF line endings::$(escape_data "${path}") is committed with CRLF line endings."
done
[ "${#found[@]}" -le "${max_annotations}" ] ||
    echo "… and $((${#found[@]} - max_annotations)) more file(s)."
echo "::${level} title=CRLF line endings::${#found[@]} text file(s) are committed with CRLF line endings. Store them with LF: put \"* text=auto eol=lf\" in .gitattributes, run \"git add .gitattributes\" and \"git add --renormalize .\", and commit both. A file that needs CRLF gets its own .gitattributes rule: \"eol=crlf\" (CRLF in the checkout, LF in the repository) or \"-text\" (stored byte for byte)."
[ "${blocking}" = false ] || exit 1

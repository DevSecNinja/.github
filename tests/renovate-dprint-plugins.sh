#!/usr/bin/env bash
#
# Checks the Renovate custom managers for dprint plugin URLs in
# .renovate/customManagers.json5:
#
# - official plugins (`plugins.dprint.dev/<name>-<version>.wasm`) resolve to the
#   dprint/dprint-plugin-<name> GitHub releases with bare tags;
# - third-party plugins (`plugins.dprint.dev/<owner>/<repo>-v<version>.wasm`)
#   resolve to <owner>/<repo> with v-prefixed tags;
# - process plugins and other URLs are not matched;
# - every plugin URL in this repository's dprint configs is tracked;
# - plugin updates keep the soak and automerge but get their own PR, so a
#   formatting change cannot block the weekly non-major batch.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
custom_managers="${repo_root}/.renovate/customManagers.json5"

if ! command -v pyjson5 >/dev/null 2>&1; then
    echo "error: 'pyjson5' not found on PATH. Run via 'mise run test'." >&2
    exit 1
fi

managers="$(
    pyjson5 --as-json "${custom_managers}" |
        jq -c '[.customManagers[] | select(.depTypeTemplate == "dprint-plugin")]' |
        tr -d '\r'
)"

MANAGERS="${managers}" REPO_ROOT="${repo_root}" python3 - <<'PY'
import json
import os
import re
import sys
from pathlib import Path

managers = json.loads(os.environ["MANAGERS"])
errors = []
if len(managers) != 2:
    print(f"error: expected 2 dprint plugin managers, found {len(managers)}", file=sys.stderr)
    sys.exit(1)

file_patterns = set()
for manager in managers:
    if manager.get("datasourceTemplate") != "github-releases":
        errors.append(f"{manager['description']}: datasourceTemplate must be github-releases")
    for pattern in manager["managerFilePatterns"]:
        file_patterns.add(pattern)
    for pattern in manager["matchStrings"]:
        # Renovate runs custom-manager regexes on RE2, which has no lookaround.
        if re.search(r"\(\?<?[=!]", pattern):
            errors.append(f"{manager['description']}: lookaround is not supported by Renovate's RE2 engine")


def render(template, groups):
    return re.sub(r"\{\{\{(\w+)\}\}\}", lambda m: groups.get(m.group(1)) or "", template)


def extract(text):
    """(depName, currentValue) for every plugin URL the managers match."""
    found = []
    for manager in managers:
        # Renovate uses JavaScript named groups; Python spells them (?P<name>...).
        pattern = re.compile(manager["matchStrings"][0].replace("(?<", "(?P<"))
        for match in pattern.finditer(text):
            groups = match.groupdict()
            found.append((render(manager["depNameTemplate"], groups), groups["currentValue"]))
    return sorted(found)


def file_matched(path):
    js = [p.strip("/").replace("\\\\", "\\") for p in file_patterns]
    return any(re.search(p, path) for p in js)


cases = {
    '"https://plugins.dprint.dev/markdown-0.21.1.wasm"': [("dprint/dprint-plugin-markdown", "0.21.1")],
    '"https://plugins.dprint.dev/typescript-0.96.1.wasm",': [("dprint/dprint-plugin-typescript", "0.96.1")],
    '"https://plugins.dprint.dev/g-plane/malva-v0.16.0.wasm"': [("g-plane/malva", "v0.16.0")],
    '"https://plugins.dprint.dev/g-plane/markup_fmt-v0.27.3.wasm"': [("g-plane/markup_fmt", "v0.27.3")],
    '"https://plugins.dprint.dev/someone/dprint-plugin-x-v1.2.3.wasm"': [("someone/dprint-plugin-x", "v1.2.3")],
    # Process plugins carry a checksum and are not WASM: never matched.
    '"https://plugins.dprint.dev/prettier-0.40.0.json@0123abcd"': [],
    '"https://example.com/markdown-0.21.1.wasm"': [],
    '"https://plugins.dprint.dev/markdown-latest.wasm"': [],
}
for text, want in cases.items():
    got = extract(text)
    if got != want:
        errors.append(f"{text}: want {want}, got {got}")

for path, want in {
    "dprint.json": True,
    "config-sync/files/dprint.json": True,
    ".dprint.jsonc": True,
    "sub/dir/.dprint.json": True,
    "dprint.json.bak": False,
    "notdprint.json": False,
}.items():
    if file_matched(path) != want:
        errors.append(f"managerFilePatterns: {path} should {'' if want else 'not '}match")

# Every plugin URL in this repository's dprint configs is tracked.
root = Path(os.environ["REPO_ROOT"])
for path in sorted([*root.glob("dprint.json"), *root.glob("config-sync/files/dprint.json")]):
    text = path.read_text(encoding="utf-8")
    urls = re.findall(r'"https://plugins\.dprint\.dev/[^"]+\.wasm"', text)
    if not urls:
        errors.append(f"{path.relative_to(root)}: no plugin URLs found")
    for url in urls:
        if not extract(url):
            errors.append(f"{path.relative_to(root)}: plugin URL not tracked: {url}")

if errors:
    print("error: dprint plugin managers:\n  " + "\n  ".join(errors), file=sys.stderr)
    sys.exit(1)
print("Renovate dprint plugin managers: OK")
PY

# Effective package rules for a dprint plugin update, in the order
# .renovate/default.json5 extends the presets (tests/lib/renovate-effective.jq).
mapfile -t presets < <(
    pyjson5 --as-json "${repo_root}/.renovate/default.json5" |
        jq -r '.extends[] | select(startswith("github>DevSecNinja/.github//.renovate/")) | ltrimstr("github>DevSecNinja/.github//.renovate/")' |
        tr -d '\r'
)
rules="$(
    for preset in "${presets[@]}"; do
        pyjson5 --as-json "${repo_root}/.renovate/${preset}" | jq '.packageRules // []'
    done | jq -s 'add'
)"
base="$(pyjson5 --as-json "${repo_root}/.renovate/base.json5" | jq -c '{minimumReleaseAge}')"
for update in minor patch; do
    dep="$(printf '{"manager":"custom.regex","datasource":"github-releases","depType":"dprint-plugin","updateType":"%s","packageName":"dprint/dprint-plugin-markdown","currentValue":"0.21.1"}' "${update}")"
    result="$(jq -c --argjson dep "${dep}" --argjson base "${base}" -f "${repo_root}/tests/lib/renovate-effective.jq" <<<"${rules}")"
    jq -e '.enabled == true and has("groupName") and .groupName == null and .minimumReleaseAge == "14 days" and .automerge == true' \
        <<<"${result}" >/dev/null || {
        echo "error: dprint plugin ${update} update must keep the soak and automerge in its own PR: ${result}" >&2
        exit 1
    }
done
echo "Renovate dprint plugin updates: own PR, soaked"

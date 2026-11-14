#!/usr/bin/env bash
#
# Checks the Renovate custom manager for apm.yml tag pins: whole-package and
# subpath pins must both resolve to the owner/repo that the github-tags
# datasource looks up, and every pin in this repository's apm.yml must match.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
custom_managers="${repo_root}/.renovate/customManagers.json5"

if ! command -v pyjson5 >/dev/null 2>&1; then
    echo "error: 'pyjson5' not found on PATH. Run via 'mise run test'." >&2
    exit 1
fi

pattern="$(
    pyjson5 --as-json "${custom_managers}" |
        jq -r '.customManagers[]
            | select(.managerFilePatterns | index("/(^|/)apm\\.yml$/"))
            | .matchStrings[0]'
)"
[ -n "${pattern}" ] || {
    echo "error: no apm.yml custom manager in ${custom_managers}" >&2
    exit 1
}

PATTERN="${pattern}" APM_YML="${repo_root}/apm.yml" python3 - <<'PY'
import os
import re
import sys

# Renovate uses JavaScript named groups; Python spells them (?P<name>...).
pattern = re.compile(os.environ["PATTERN"].replace("(?<", "(?P<"))

cases = {
    "  - DevSecNinja/ai-toolkit#v0.9.1": ("DevSecNinja/ai-toolkit", "v0.9.1"),
    "  - DevSecNinja/ai-toolkit/.apm/skills/renovate-triage-and-merge#v0.9.1": (
        "DevSecNinja/ai-toolkit",
        "v0.9.1",
    ),
    "  - DevSecNinja/ai-toolkit/.apm/instructions/writing-style.instructions.md#v1.2.3": (
        "DevSecNinja/ai-toolkit",
        "v1.2.3",
    ),
    # SHA pins are Renovate's digest business, not this manager's.
    "  - github/awesome-copilot/agents/x.agent.md#3e36d367091a1e67b77974cade6f1aa48bc77a81": None,
}

errors = []
for line, want in cases.items():
    match = pattern.search(line)
    got = (match["depName"], match["currentValue"]) if match else None
    if got != want:
        errors.append(f"{line.strip()}: want {want}, got {got}")

with open(os.environ["APM_YML"], encoding="utf-8") as apm_yml:
    pins = [line for line in apm_yml if "#v" in line]
if not pins:
    errors.append("apm.yml has no #vX.Y.Z pins")
for line in pins:
    match = pattern.search(line)
    ref = line.strip().removeprefix("- ").split("#")[0]
    owner_repo = "/".join(ref.split("/")[:2])
    if not match or match["depName"] != owner_repo:
        errors.append(f"apm.yml pin not tracked as {owner_repo}: {line.strip()}")

if errors:
    print("error: apm.yml Renovate manager:\n  " + "\n  ".join(errors), file=sys.stderr)
    sys.exit(1)
PY

echo "renovate apm.yml manager: OK"

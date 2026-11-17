#!/usr/bin/env bash
#
# Checks the annotation-driven Renovate custom managers in
# .renovate/customManagers.json5:
#
# - "Process tool versions in GitHub Actions workflows": depName= and
#   registryUrl= are optional and a single-element matrix list
#   (`python-version: [3.14]`) is tracked;
# - "Process versions in Ansible inventory YAML files": any datasource, an
#   optional registryUrl and any key on the annotated line.
#
# Every annotated version line in this repository's workflows must still match.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
custom_managers="${repo_root}/.renovate/customManagers.json5"

if ! command -v pyjson5 >/dev/null 2>&1; then
    echo "error: 'pyjson5' not found on PATH. Run via 'mise run test'." >&2
    exit 1
fi

pattern_for() {
    pyjson5 --as-json "${custom_managers}" |
        jq -r --arg d "$1" '.customManagers[] | select(.description == $d) | .matchStrings[0]' |
        tr -d '\r'
}

WORKFLOW_PATTERN="$(pattern_for "Process tool versions in GitHub Actions workflows")" \
ANSIBLE_PATTERN="$(pattern_for "Process versions in Ansible inventory YAML files")" \
REPO_ROOT="${repo_root}" python3 - <<'PY'
import os
import re
import sys
from pathlib import Path

errors = []


def compile_pattern(name):
    raw = os.environ[name]
    if not raw:
        print(f"error: {name} not found in customManagers.json5", file=sys.stderr)
        sys.exit(1)
    # Renovate uses JavaScript named groups; Python spells them (?P<name>...).
    return re.compile(raw.replace("(?<", "(?P<"))


def fields(match, names):
    return None if not match else tuple(match.groupdict().get(n) for n in names)


workflow = compile_pattern("WORKFLOW_PATTERN")
ansible = compile_pattern("ANSIBLE_PATTERN")
names = ("datasource", "depName", "currentValue")

# Renovate runs custom-manager regexes on RE2, which has no lookaround.
for name in ("WORKFLOW_PATTERN", "ANSIBLE_PATTERN"):
    if re.search(r"\(\?<?[=!]", os.environ[name]):
        errors.append(f"{name}: lookaround is not supported by Renovate's RE2 engine")

workflow_cases = {
    '        # renovate: datasource=github-releases depName=jdx/mise\n          version: "2026.10.19"':
        ("github-releases", "jdx/mise", "2026.10.19"),
    '      # renovate: datasource=github-releases depName=golangci/golangci-lint\n      golangci-lint-version: "v2.12.2"':
        ("github-releases", "golangci/golangci-lint", "v2.12.2"),
    "        # renovate: datasource=python-version\n        python-version: [3.14]":
        ("python-version", None, "3.14"),
    '        # renovate: datasource=python-version\n        python-version: ["3.14"]':
        ("python-version", None, "3.14"),
    "        # renovate: datasource=python-version\n        python-version: 3.14":
        ("python-version", None, "3.14"),
    '      # renovate: datasource=github-releases depName=jdx/mise\n      version: "2026.10.19" # pinned\n      other: x':
        ("github-releases", "jdx/mise", "2026.10.19"),
    # A multi-version matrix is a compatibility list, not one version: never
    # track (and replace) only its first entry.
    "        # renovate: datasource=python-version\n        python-version: [3.13, 3.14]":
        None,
    '        # renovate: datasource=python-version\n        python-version: ["3.13", "3.14"]\n':
        None,
    "        # renovate: datasource=python-version\n        python-version: [3.13,3.14]":
        None,
    "        # renovate: datasource=github-tags depName=DevSecNinja/.github\n        uses: DevSecNinja/.github/actions/x@0123 # main":
        None,
}
for text, want in workflow_cases.items():
    got = fields(workflow.search(text), names)
    if got != want:
        errors.append(f"workflow manager: {text!r}: want {want}, got {got}")

# An optional registryUrl, e.g. the PowerShell Gallery for a module.
psgallery = "https://www.powershellgallery.com/api/v2/"
for text, want in {
    f'      # renovate: datasource=nuget depName=PSScriptAnalyzer registryUrl={psgallery}\n      psscriptanalyzer-version: "1.25.0"':
        ("nuget", "PSScriptAnalyzer", "1.25.0", psgallery),
    '      # renovate: datasource=github-releases depName=jdx/mise\n      mise-version: "2026.10.19"':
        ("github-releases", "jdx/mise", "2026.10.19", None),
}.items():
    got = fields(workflow.search(text), names + ("registryUrl",))
    if got != want:
        errors.append(f"workflow manager: {text!r}: want {want}, got {got}")

deb_url = "https://download.docker.com/linux/debian?suite=trixie&components=stable&binaryArch=amd64"
ansible_cases = {
    f'    # renovate: datasource=deb depName=docker-ce registryUrl={deb_url}\n    docker_ce: "5:29.6.2-1~debian.13~trixie"':
        ("deb", "docker-ce", "5:29.6.2-1~debian.13~trixie", deb_url),
    '    # renovate: datasource=github-releases depName=getsops/sops\n    sops_version: "v3.11.0"':
        ("github-releases", "getsops/sops", "v3.11.0", None),
    "    # renovate: datasource=github-releases\n    sops_version: v3.11.0":
        None,
}
for text, want in ansible_cases.items():
    got = fields(ansible.search(text), names + ("registryUrl",))
    if got != want:
        errors.append(f"ansible manager: {text!r}: want {want}, got {got}")

# Every annotated version line in this repository's workflows still matches.
root = Path(os.environ["REPO_ROOT"])
annotation = re.compile(r"^\s*# renovate: datasource=\S+.*\n\s+[\w-]*version:.*$", re.M)
for path in sorted([*root.glob(".github/workflows/*.y*ml"), *root.glob("workflow-templates/*.y*ml")]):
    text = path.read_text(encoding="utf-8").replace("\r\n", "\n")
    for found in annotation.finditer(text):
        if not workflow.search(found.group(0)):
            errors.append(f"{path.relative_to(root)}: annotated line no longer matches: {found.group(0).strip()!r}")

if errors:
    print("error: Renovate annotation managers:\n  " + "\n  ".join(errors), file=sys.stderr)
    sys.exit(1)
print("Renovate annotation managers: OK")
PY

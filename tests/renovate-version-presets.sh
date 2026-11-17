#!/usr/bin/env bash
#
# Contract test for Renovate's first-party version presets in
# .renovate/default.json5:
#
# - githubActionsVersions, biomeVersions and makefileVersions are extended;
# - githubActionsVersions and customManagers.json5's workflow manager never
#   extract the same line: the preset takes upper-case `<NAME>_VERSION:` keys,
#   the central manager lower-case `…version:` keys (LF and CRLF);
# - no central custom manager also targets biome.json or Makefiles.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v pyjson5 >/dev/null 2>&1; then
    echo "error: 'pyjson5' not found on PATH. Run via 'mise run test'." >&2
    exit 1
fi

DEFAULT="$(pyjson5 --as-json "${repo_root}/.renovate/default.json5" | tr -d '\r')" \
MANAGERS="$(pyjson5 --as-json "${repo_root}/.renovate/customManagers.json5" | tr -d '\r')" \
    python3 - <<'PY'
import json
import os
import re
import sys

extends = json.loads(os.environ["DEFAULT"])["extends"]
managers = json.loads(os.environ["MANAGERS"])["customManagers"]
errors = []

for preset in ("customManagers:githubActionsVersions", "customManagers:biomeVersions", "customManagers:makefileVersions"):
    if preset not in extends:
        errors.append(f".renovate/default.json5 must extend {preset}")


def compile_js(pattern):
    return re.compile(pattern.replace("(?<", "(?P<"))


# matchStrings of customManagers:githubActionsVersions, copied from Renovate's
# lib/config/presets/internal/custom-managers.preset.ts. Update it if upstream
# changes the key rule; the overlap check below depends on it.
preset = compile_js(
    r"# renovate: datasource=(?<datasource>[a-zA-Z0-9-._]+?) depName=(?<depName>[^\s]+?)"
    r"(?: (?:lookupName|packageName)=(?<packageName>[^\s]+?))?(?: versioning=(?<versioning>[^\s]+?))?"
    r"(?: extractVersion=(?<extractVersion>[^\s]+?))?(?: registryUrl=(?<registryUrl>[^\s]+?))?"
    r"\s+[A-Za-z0-9_]+?_VERSION\s*:\s*[\"']?(?<currentValue>.+?)[\"']?\s"
)
workflow = [m for m in managers if m["description"] == "Process tool versions in GitHub Actions workflows"]
if len(workflow) != 1:
    print("error: workflow manager not found in customManagers.json5", file=sys.stderr)
    sys.exit(1)
central = compile_js(workflow[0]["matchStrings"][0])

ann = "        # renovate: datasource=github-releases depName=jdx/mise\n"
cases = {
    # DevSecNinja/dotfiles .github/workflows/ci.yaml
    ann + '        MISE_VERSION: "2026.5.15"\n': ("preset", "2026.5.15"),
    ann + '          version: "2026.10.19"\n': ("central", "2026.10.19"),
    ann + '          mise-version: "2026.10.19"\n': ("central", "2026.10.19"),
    "      # renovate: datasource=github-releases depName=microsoft/apm\n      apm_cli_version: \"0.35.0\"\n": ("central", "0.35.0"),
}
for text, (owner, value) in cases.items():
    # The central manager's CRLF handling is covered by
    # tests/renovate-shell-manager.sh; here CRLF only checks the preset side.
    variants = [(text, "LF")] + ([(text.replace("\n", "\r\n"), "CRLF")] if owner == "preset" else [])
    for variant, label in variants:
        hits = {name: m["currentValue"] for name, m in (("preset", preset.search(variant)), ("central", central.search(variant))) if m}
        if hits != {owner: value}:
            errors.append(f"{label} {text.strip()!r}: want only {owner} = {value}, got {hits}")

for path in ("biome.json", "frontend/biome.jsonc", "Makefile", "build/tools.mk"):
    for m in managers:
        if any(compile_js(p.strip("/")).search(path) for p in m["managerFilePatterns"]):
            errors.append(f"{m['description']} also targets {path}, which a first-party preset handles")

if errors:
    print("error: Renovate version presets:\n  " + "\n  ".join(errors), file=sys.stderr)
    sys.exit(1)
print("Renovate version presets: OK")
PY

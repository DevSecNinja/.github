#!/usr/bin/env bash
#
# Contract test for Renovate's first-party version presets
# (githubActionsVersions, biomeVersions, makefileVersions):
#
# - .renovate/customManagers.json5 extends them, once, so they reach every
#   repository: most fleet configs extend the individual presets rather than
#   default.json5. The extends chain of a legacy fleet config (snapshot of
#   DevSecNinja/config-sidecar's renovate.json5), the config-sync stub template
#   and this repository's renovate.json5 must each resolve to all three;
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

to_json() {
    pyjson5 --as-json "$1" | tr -d '\r'
}

presets="{"
for file in "${repo_root}"/.renovate/*.json5; do
    presets+="\"$(basename "${file}")\": $(to_json "${file}"),"
done
presets="${presets%,}}"

PRESETS="${presets}" \
    TEMPLATE="$(to_json "${repo_root}/config-sync/templates/renovate.json5")" \
    ROOT="$(to_json "${repo_root}/renovate.json5")" \
    python3 - <<'PY'
import json
import os
import re
import sys

presets = json.loads(os.environ["PRESETS"])
managers = presets["customManagers.json5"]["customManagers"]
errors = []
wanted = ("customManagers:githubActionsVersions", "customManagers:biomeVersions", "customManagers:makefileVersions")
local_prefix = "github>DevSecNinja/.github//.renovate/"

for preset in wanted:
    owners = [name for name, cfg in presets.items() if preset in cfg.get("extends", [])]
    if owners != ["customManagers.json5"]:
        errors.append(f"{preset} must be extended by customManagers.json5 only, found in {owners}")


def resolve(extends, seen=()):
    """Every preset name reachable from extends, following the central files."""
    found = []
    for name in extends:
        found.append(name)
        if name.startswith(local_prefix):
            file = name[len(local_prefix):]
            if file not in presets:
                errors.append(f"unknown central preset {name}")
            elif file not in seen:
                found += resolve(presets[file].get("extends", []), seen + (file,))
    return found


# Snapshot of DevSecNinja/config-sidecar's renovate.json5 (2026-11-18), the
# shape of 41 of the 43 fleet configs.
legacy = [
    "config:recommended",
    "helpers:pinGitHubActionDigests",
    ":dependencyDashboard",
    ":semanticCommits",
] + [local_prefix + f for f in ("autoMerge.json5", "base.json5", "customManagers.json5", "groups.json5", "labels.json5", "packageRules.json5", "semanticCommits.json5")]
configs = {
    "legacy fleet config (config-sidecar)": legacy,
    "config-sync stub template": json.loads(os.environ["TEMPLATE"])["extends"],
    "renovate.json5": json.loads(os.environ["ROOT"])["extends"],
}
for label, extends in configs.items():
    resolved = resolve(extends)
    for preset in wanted:
        if resolved.count(preset) != 1:
            errors.append(f"{label} resolves to {preset} {resolved.count(preset)} times, want 1")

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

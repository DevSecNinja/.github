#!/usr/bin/env bash
#
# Checks that `updateNotScheduled: true` (.renovate/base.json5) is what a
# typical fleet config resolves to: open Renovate PRs stay rebased and up to
# date between the weekly schedule windows. The extends chain of a legacy fleet
# config (snapshot of DevSecNinja/config-sidecar's renovate.json5), the
# config-sync stub template and this repository's renovate.json5 is resolved
# through the local .renovate/ presets, last value wins, and no later preset or
# the config itself may turn it off. The weekly schedule stays in place.

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
import sys

presets = json.loads(os.environ["PRESETS"])
local_prefix = "github>DevSecNinja/.github//.renovate/"
errors = []


def resolve(config, key, seen=()):
    """The value of a top-level option after Renovate's preset merge:
    extends in order, then the config's own value."""
    value = None
    for name in config.get("extends", []):
        if name.startswith(local_prefix) and name not in seen:
            found = resolve(presets[name[len(local_prefix):]], key, seen + (name,))
            if found is not None:
                value = found
    return config.get(key, value)


legacy = {
    "extends": [
        "config:recommended",
        "helpers:pinGitHubActionDigests",
        ":dependencyDashboard",
        ":semanticCommits",
    ] + [local_prefix + f for f in ("autoMerge.json5", "base.json5", "customManagers.json5", "groups.json5", "labels.json5", "packageRules.json5", "semanticCommits.json5")],
}
configs = {
    "legacy fleet config (config-sidecar)": legacy,
    "config-sync stub template": json.loads(os.environ["TEMPLATE"]),
    "renovate.json5": json.loads(os.environ["ROOT"]),
}
for label, config in configs.items():
    if resolve(config, "updateNotScheduled") is not True:
        errors.append(f"{label}: updateNotScheduled resolves to {resolve(config, 'updateNotScheduled')}, want true")
    if resolve(config, "schedule") != ["* 0-7 * * 6"]:
        errors.append(f"{label}: schedule resolves to {resolve(config, 'schedule')}, want the Saturday window")

if errors:
    print("error: Renovate updateNotScheduled:\n  " + "\n  ".join(errors), file=sys.stderr)
    sys.exit(1)
print("Renovate updateNotScheduled: OK")
PY

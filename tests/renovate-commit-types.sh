#!/usr/bin/env bash
#
# Contract test for the commit types Renovate gives dependency updates
# (.renovate/semanticCommits.json5). The type decides whether release-please
# releases: only feat, fix, perf and revert are visible by default.
#
# Real fleet config shapes are resolved through the local .renovate/ presets
# and copies of Renovate's internal commit-type presets, their packageRules are
# applied in Renovate's order (last match wins, vulnerabilityAlerts last), and
# the resulting type is checked per dependency:
#
# - runtime dependencies stay `fix` (Renovate's :semanticPrefixFixDepsChoreOthers);
# - development and build tooling is `build`, CI is `ci`, so neither releases;
# - published actions and DevSecNinja/.github's workflows stay `fix`;
# - vulnerability fixes are always `fix`;
# - a grouped PR takes its highest type;
# - no central config forces one type on everything (:semanticCommitTypeAll),
#   and this repository's release-please config hides build and ci.

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
    RELEASE_PLEASE="$(tr -d '\r' <"${repo_root}/release-please-config.json")" \
    python3 - <<'PY'
import json
import os
import re
import sys

presets = json.loads(os.environ["PRESETS"])
errors = []
local_prefix = "github>DevSecNinja/.github//.renovate/"

# Copies of Renovate's internal presets that set semanticCommitType
# (lib/config/presets/internal/default.preset.ts). config:recommended pulls in
# :semanticPrefixFixDepsChoreOthers; config:best-practices extends
# config:recommended. Other internal presets don't set commit types.
FIX_DEPS_CHORE_OTHERS = [
    {"matchPackageNames": ["*"], "semanticCommitType": "chore"},
    {"matchDepTypes": ["dependencies", "require"], "semanticCommitType": "fix"},
    {
        "matchDatasources": ["maven"],
        "matchDepTypes": ["compile", "provided", "runtime", "system", "import", "parent"],
        "semanticCommitType": "fix",
    },
    {
        "matchDepTypes": ["project.dependencies", "project.optional-dependencies"],
        "matchManagers": ["pep621", "poetry"],
        "semanticCommitType": "fix",
    },
    {"matchDepTypes": ["dependencies", "extras"], "matchManagers": ["poetry"], "semanticCommitType": "fix"},
    {"matchJsonata": ["isLockfileUpdate = true"], "semanticCommitType": "chore"},
]
INTERNAL = {
    "config:recommended": {"packageRules": FIX_DEPS_CHORE_OTHERS},
    "config:best-practices": {"extends": ["config:recommended"]},
}


def internal(name):
    m = re.fullmatch(r":semanticCommitTypeAll\((\w+)\)", name)
    if m:
        return {"packageRules": [{"matchFileNames": ["**/*"], "semanticCommitType": m[1]}]}
    return INTERNAL.get(name, {})


def resolve(config, seen=()):
    """packageRules in Renovate's merge order and the merged vulnerabilityAlerts."""
    rules, vuln = [], {}
    for name in config.get("extends", []):
        if name in seen:
            continue
        if name.startswith(local_prefix):
            sub = presets[name[len(local_prefix):]]
        else:
            sub = internal(name)
        sub_rules, sub_vuln = resolve(sub, seen + (name,))
        rules += sub_rules
        vuln.update(sub_vuln)
    rules += config.get("packageRules", [])
    vuln.update(config.get("vulnerabilityAlerts", {}))
    return rules, vuln


def glob(pattern):
    # minimatch with `dot: true`, as Renovate's matchFileNames and
    # matchRepositories use it.
    out, i = "", 0
    while i < len(pattern):
        if pattern.startswith("**/", i):
            out, i = out + "(?:.*/)?", i + 3
        elif pattern.startswith("**", i):
            out, i = out + ".*", i + 2
        elif pattern[i] == "*":
            out, i = out + "[^/]*", i + 1
        elif pattern[i] == "?":
            out, i = out + "[^/]", i + 1
        else:
            out, i = out + re.escape(pattern[i]), i + 1
    return re.compile(out + r"\Z")


def matches(rule, dep):
    checks = {
        "matchManagers": lambda v: dep["manager"] in v,
        "matchDepTypes": lambda v: dep.get("depType") in v,
        "matchDatasources": lambda v: dep.get("datasource") in v,
        "matchPackageNames": lambda v: "*" in v or dep.get("packageName") in v,
        "matchFileNames": lambda v: any(glob(p).match(dep["packageFile"]) for p in v),
        "matchRepositories": lambda v: any(glob(p).match(dep["repository"]) for p in v),
        "matchJsonata": lambda v: v == ["isLockfileUpdate = true"] and dep.get("isLockfileUpdate", False),
    }
    for key, value in rule.items():
        if key.startswith("match"):
            if key not in checks:
                errors.append(f"test model does not support {key} in {rule.get('description', rule)}")
                return False
            if not checks[key](value):
                return False
    return True


def commit_type(config, dep):
    rules, vuln = resolve(config)
    found = "chore"  # Renovate's semanticCommitType default
    for rule in rules:
        if "semanticCommitType" in rule and matches(rule, dep):
            found = rule["semanticCommitType"]
    if dep.get("vulnerability"):
        found = vuln.get("semanticCommitType", found)
    return found


PRIORITY = ["chore", "ci", "build", "fix", "feat"]


def group_type(types):
    # lib/workers/repository/updates/generate.ts semanticCommitTypeByPriority
    return max(types, key=PRIORITY.index)


# Snapshot of DevSecNinja/config-sidecar's and python-bandit-scan's
# renovate.json5 (2026-11-18), the shape of 41 of the 43 fleet configs.
legacy = {
    "extends": [
        "config:recommended",
        "helpers:pinGitHubActionDigests",
        ":dependencyDashboard",
        ":semanticCommits",
    ] + [local_prefix + f for f in ("autoMerge.json5", "base.json5", "customManagers.json5", "groups.json5", "labels.json5", "packageRules.json5", "semanticCommits.json5")],
}
# Snapshot of DevSecNinja/lovelace-ovapi's renovate.json5 (2026-11-18), one of
# 8 that still extend :semanticCommitTypeAll(build). base.json5's
# config:best-practices appends config:recommended's commit-type rules after
# it, so it only types updates without a package name (lock-file maintenance)
# and the central rules still apply.
legacy_build = {"extends": legacy["extends"][:4] + [":semanticCommitTypeAll(build)"] + legacy["extends"][4:]}
template = json.loads(os.environ["TEMPLATE"])
root = json.loads(os.environ["ROOT"])


def dep(manager, package_file, dep_type=None, **extra):
    return {"manager": manager, "packageFile": package_file, "depType": dep_type, **extra}


ordinary = [
    # runtime: unchanged, release-triggering
    (dep("npm", "package.json", "dependencies"), "fix"),
    (dep("npm", "frontend/package.json", "dependencies"), "fix"),
    (dep("pep621", "pyproject.toml", "project.dependencies"), "fix"),
    (dep("cargo", "crates/core/Cargo.toml", "dependencies"), "fix"),
    (dep("gomod", "go.mod", "require"), "fix"),
    (dep("npm", "package.json", "dependencies", isLockfileUpdate=True), "chore"),
    # not classified: unchanged chore
    (dep("docker-compose", "services/immich/compose.yaml"), "chore"),
    (dep("dockerfile", "backend/Dockerfile", "final"), "chore"),
    (dep("nuget", "src/App/App.csproj", "nuget"), "chore"),
    (dep("pip_requirements", "requirements.txt"), "chore"),
    # development and build tooling
    (dep("npm", "package.json", "devDependencies"), "build"),
    (dep("npm", "package.json", "packageManager"), "build"),
    (dep("pep621", "pyproject.toml", "dependency-groups"), "build"),
    (dep("cargo", "Cargo.toml", "dev-dependencies"), "build"),
    (dep("mise", ".mise.toml", "tools"), "build"),
    (dep("regex", ".mise.toml", datasource="github-releases"), "build"),
    (dep("devcontainer", ".devcontainer/devcontainer.json", "feature"), "build"),
    (dep("dockerfile", ".devcontainer/Dockerfile", "final"), "build"),
    (dep("pre-commit", ".pre-commit-config.yaml", "repository"), "build"),
    (dep("pep723", "tests/app-key-confinement.py", "project.dependencies"), "build"),
    (dep("regex", "dprint.json", "dprint-plugin"), "build"),
    (dep("regex", "tests/setup_libs.sh", datasource="github-releases"), "build"),
    (dep("regex", "tests/bash/run-tests.bats", datasource="github-releases"), "build"),
    (dep("regex", "scripts/gha-backup-restore-test.sh", datasource="docker"), "build"),
    (dep("pip_requirements", "tests/ha-requirements.txt"), "build"),
    (dep("nuget", "tests/App.Tests/App.Tests.csproj", "nuget"), "build"),
    (dep("nuget", "src/Functions.Tests/Functions.Tests.csproj", "nuget"), "build"),
    # CI
    (dep("github-actions", ".github/workflows/ci.yml", "action"), "ci"),
    (dep("github-actions", ".github/workflows/ci.yml", "github-runner"), "ci"),
    (dep("github-actions", ".github/actions/setup/action.yml", "action"), "ci"),
    (dep("regex", ".github/workflows/lint.yml", datasource="github-releases"), "ci"),
    # vulnerability fixes always release
    (dep("github-actions", ".github/workflows/ci.yml", "action", vulnerability=True), "fix"),
    (dep("npm", "package.json", "devDependencies", vulnerability=True), "fix"),
]
dotgithub = [
    (dep("github-actions", ".github/workflows/lint.yml", "action"), "fix"),
    (dep("github-actions", "actions/harden-runner/action.yml", "action"), "fix"),
    (dep("github-actions", ".github/actions/notify-irm/action.yml", "action"), "fix"),
    (dep("regex", "workflow-templates/lint.yml", datasource="github-releases"), "fix"),
    (dep("regex", "config-sync/files/dprint.json", "dprint-plugin"), "fix"),
    (dep("regex", "config-sync/templates/.mise.toml", datasource="github-releases"), "fix"),
    (dep("mise", ".mise.toml", "tools"), "build"),
    (dep("pep723", "tests/lint-include.py", "project.dependencies"), "build"),
    (dep("regex", ".mise.toml", datasource="github-releases"), "build"),
]
bandit = [
    (dep("github-actions", "action.yml", "action"), "fix"),
    (dep("github-actions", ".github/workflows/ci.yml", "action"), "ci"),
]
cases = [
    ("legacy fleet config", "DevSecNinja/config-sidecar", legacy, ordinary),
    ("config-sync stub template", "DevSecNinja/new-repo", template, ordinary),
    ("legacy config with :semanticCommitTypeAll(build)", "DevSecNinja/lovelace-ovapi", legacy_build, ordinary),
    ("legacy fleet config", "DevSecNinja/python-bandit-scan", legacy, bandit),
    ("renovate.json5", "DevSecNinja/.github", root, dotgithub),
]
for label, repository, config, samples in cases:
    for sample, want in samples:
        got = commit_type(config, {**sample, "repository": repository})
        if got != want:
            errors.append(f"{label} ({repository}): {sample}: want {want}, got {got}")

for types, want in ((["ci", "build"], "build"), (["ci", "build", "fix"], "fix"), (["chore", "ci"], "ci")):
    if group_type(types) != want:
        errors.append(f"group of {types}: want {want}, got {group_type(types)}")

for label, config in [(f, presets[f]) for f in presets] + [("renovate.json5", root), ("config-sync stub template", template)]:
    forced = [e for e in config.get("extends", []) if e.startswith(":semanticCommitTypeAll(")]
    if forced:
        errors.append(f"{label} extends {forced}: it overrides the central commit types for every dependency")

sections = {s["type"]: s for s in json.loads(os.environ["RELEASE_PLEASE"])["changelog-sections"]}
for kind in ("build", "ci"):
    if not sections.get(kind, {}).get("hidden"):
        errors.append(f"release-please-config.json: the {kind} section must be hidden, or tooling and CI updates release")
if sections.get("fix", {}).get("hidden", False):
    errors.append("release-please-config.json: the fix section must be visible")

if errors:
    print("error: Renovate commit types:\n  " + "\n  ".join(errors), file=sys.stderr)
    sys.exit(1)
print("Renovate commit types: OK")
PY

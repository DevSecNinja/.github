#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.9"
# dependencies = ["pyyaml==6.0.3"]
# ///
"""Keep the Automation App private key confined to the token step.

Every workflow under .github/workflows/ and workflow-templates/ is parsed as
YAML, and every string that references the App private key
(secrets.AUTOMATION_APP_PRIVATE_KEY, secrets.app-private-key,
secrets.RELEASE_PLEASE_APP_PRIVATE_KEY) or dumps the secrets context
(toJSON(secrets), secrets[<expression>]) must sit in one of these places:

- the `private-key:` input of an `actions/create-github-app-token` step pinned
  to a full commit SHA, in a job that declares `environment:`;
- the `env:` of an allowlisted step that only tests the key for emptiness
  (EMPTINESS_CHECKS), whose bash `run:` reads it in nothing but
  `[[ -n|-z "${VAR//[[:space:]]/}" ]]` and never dumps the environment;
- the `secrets:` mapping of a job calling an App-key reusable workflow of this
  repository (pinned by SHA, or local), under AUTOMATION_APP_PRIVATE_KEY or
  app-private-key.

`secrets: inherit` is only allowed towards those same reusable workflows.
Negative cases live in tests/fixtures/app-key-confinement-cases.yml. See
docs/automation-app.md ("The key only reaches the token step").
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
SCANNED_DIRS = (".github/workflows", "workflow-templates")
CASES = ROOT / "tests" / "fixtures" / "app-key-confinement-cases.yml"

KEY_NAMES = ("AUTOMATION_APP_PRIVATE_KEY", "app-private-key", "RELEASE_PLEASE_APP_PRIVATE_KEY")
_names = "|".join(re.escape(name) for name in KEY_NAMES)
# Contexts are case-insensitive in GitHub expressions.
KEY_REF = re.compile(rf"secrets\s*(?:\.\s*(?:{_names})(?![\w-])|\[\s*['\"](?:{_names})['\"]\s*\])", re.I)
SECRETS_DUMP = re.compile(r"toJSON\s*\(\s*secrets\s*\)|secrets\s*\[\s*(?!['\"])", re.I)

TOKEN_ACTION = "actions/create-github-app-token@"
TOKEN_PINNED = re.compile(r"^actions/create-github-app-token@[0-9a-f]{40}$")
_reusables = r"\.github/workflows/(?:config-sync|release-please|apm-sync)\.ya?ml"
KEY_REUSABLES = re.compile(rf"^(?:DevSecNinja/\.github/{_reusables}@[0-9a-f]{{40}}|\./{_reusables})$")
KEY_SECRET_INPUTS = {"AUTOMATION_APP_PRIVATE_KEY", "app-private-key"}

# (workflow, job id, step name, env var) of the steps that may receive the key
# to test it for emptiness and print a friendly error before the token step.
EMPTINESS_CHECKS = {
    (".github/workflows/release-please.yml", "release-please", "Validate GitHub App credentials", "APP_PRIVATE_KEY"),
    (".github/workflows/config-sync.yml", "sync", "Resolve GitHub App credentials", "APP_PRIVATE_KEY"),
    (".github/workflows/apm-sync.yml", "apm-sync", "Resolve GitHub App credentials", "APP_PRIVATE_KEY"),
}
# Workflows that must keep a confined token-step reference, so the test cannot
# pass vacuously after a rename or a parsing change.
EXPECTED_TOKEN_STEPS = {
    ".github/workflows/release-please.yml",
    ".github/workflows/config-sync.yml",
    ".github/workflows/apm-sync.yml",
    ".github/workflows/apm-materialize.yml",
}

ENV_DUMP = re.compile(
    r"\bprintenv\b|\b(?:declare|typeset|export|readonly)\s+-p\b|\bcompgen\s+-[A-Za-z]*[ve]"
    r"|\bset\s+(?:-[A-Za-z]*x|-o\s+xtrace)|\benviron\b|\$\{!"
    r"|(?:^|[;&|(]|\bthen|\bdo|\belse)\s*env\s*(?:$|[;&|>)])|^\s*set\s*(?:$|[;&|>])",
    re.M,
)


def walk(node, path=()):
    if isinstance(node, dict):
        for key, value in node.items():
            yield from walk(value, path + (key,))
    elif isinstance(node, list):
        for index, value in enumerate(node):
            yield from walk(value, path + (index,))
    elif isinstance(node, str):
        yield path, node


def location(doc, path) -> str:
    text, node = "", doc
    for part in path:
        if isinstance(node, list):
            node = node[part]
            label = node.get("name") or node.get("id") or part if isinstance(node, dict) else part
            text += f"[{label}]"
        else:
            node = node.get(part) if isinstance(node, dict) else None
            text += ("." if text else "") + str(part)
    return text


def has_environment(job: dict) -> bool:
    environment = job.get("environment")
    if isinstance(environment, dict):
        environment = environment.get("name")
    return isinstance(environment, str) and environment.strip() != ""


def emptiness_problem(step: dict, var: str) -> str | None:
    if step.get("uses"):
        return "an allowlisted emptiness check must be a run step"
    if step.get("shell") not in (None, "bash"):
        return "an allowlisted emptiness check must run in bash"
    run = step.get("run") or ""
    uses = len(re.findall(rf"(?<!\w){re.escape(var)}(?!\w)", run))
    tests = len(re.findall(rf'-[nz] "\$\{{{re.escape(var)}//\[\[:space:\]\]/\}}"', run))
    if uses != tests:
        return (f'the allowlisted emptiness check uses ${var} for more than an emptiness test '
                f'([[ -n|-z "${{{var}//[[:space:]]/}}" ]])')
    if ENV_DUMP.search(run):
        return "the allowlisted emptiness check dumps the environment"
    return None


def classify(doc: dict, rel: str, path: tuple, allowlist: set, used: set) -> str | None:
    """Return why a key reference at `path` is not allowed, or None."""
    if path[0] != "jobs" or len(path) < 3:
        if path[0] == "env":
            return "workflow-level env exposes the key to every step of every job"
        return "key referenced outside the jobs"
    job_id, field = path[1], path[2]
    job = doc["jobs"][job_id]
    if "uses" in job:
        if field == "secrets" and len(path) == 4:
            if not KEY_REUSABLES.match(str(job["uses"])):
                return f"passes the key to {job['uses']}, which is not an allowlisted App-key reusable workflow"
            if path[3] not in KEY_SECRET_INPUTS:
                return f"passes the key as secret {path[3]!r}; use AUTOMATION_APP_PRIVATE_KEY or app-private-key"
            return None
        return f"job-level '{field}' of a reusable-workflow call"
    if field == "env":
        return "job-level env exposes the key to every step of the job"
    if field != "steps" or len(path) < 5:
        return f"job-level '{field}'"
    step = job["steps"][path[3]]
    part, uses = path[4], str(step.get("uses") or "")
    if uses.startswith(TOKEN_ACTION):
        if path[4:] != ("with", "private-key"):
            return f"token step '{part}'; the key may only be its private-key input"
        if not TOKEN_PINNED.match(uses):
            return "actions/create-github-app-token is not pinned to a full commit SHA"
        return None
    if part == "with" and uses:
        return f"passed to {uses} via with:"
    if part == "env" and len(path) == 6:
        entry = (rel, job_id, step.get("name"), path[5])
        if entry not in allowlist:
            return "step env outside the emptiness-check allowlist"
        used.add(entry)
        return emptiness_problem(step, path[5])
    if part == "run":
        return "run script outside the emptiness-check allowlist"
    return f"step '{part}'"


def check(doc: dict, rel: str, allowlist: set = EMPTINESS_CHECKS) -> tuple[list[str], set, bool]:
    """Return (violations, allowlist entries used, has a confined token-step reference)."""
    violations: list[str] = []
    used: set = set()
    key_jobs: set = set()
    token_step = False
    for path, text in walk(doc):
        if SECRETS_DUMP.search(text):
            violations.append(f"{rel}: {location(doc, path)}: exposes every secret, including the App key")
            continue
        if not KEY_REF.search(text):
            continue
        reason = classify(doc, rel, path, allowlist, used)
        if reason:
            violations.append(f"{rel}: {location(doc, path)}: {reason}")
        elif path[2] == "steps":
            key_jobs.add(path[1])
            token_step = token_step or path[4:] == ("with", "private-key")
    jobs = doc.get("jobs") if isinstance(doc.get("jobs"), dict) else {}
    for job_id, job in jobs.items():
        if not isinstance(job, dict):
            continue
        if job_id in key_jobs and not has_environment(job):
            violations.append(f"{rel}: jobs.{job_id}: uses the App key but declares no environment:")
        if job.get("secrets") == "inherit" and not KEY_REUSABLES.match(str(job.get("uses") or "")):
            violations.append(f"{rel}: jobs.{job_id}: secrets: inherit hands the App key to {job.get('uses')}")
    return violations, used, token_step


def main() -> int:
    failures: list[str] = []
    used_entries: set = set()
    token_workflows: set = set()
    files = sorted(p for d in SCANNED_DIRS for p in (ROOT / d).iterdir() if p.suffix in (".yml", ".yaml"))
    for file in files:
        rel = file.relative_to(ROOT).as_posix()
        violations, used, token_step = check(yaml.safe_load(file.read_text(encoding="utf-8")) or {}, rel)
        failures += violations
        used_entries |= used
        if token_step:
            token_workflows.add(rel)
    for entry in sorted(EMPTINESS_CHECKS - used_entries):
        failures.append(f"stale EMPTINESS_CHECKS entry (no such step reads the key): {entry}")
    for rel in sorted(EXPECTED_TOKEN_STEPS - token_workflows):
        failures.append(f"{rel}: no confined create-github-app-token private-key reference found")

    cases = yaml.safe_load(CASES.read_text(encoding="utf-8"))
    for case in cases:
        violations, _, _ = check(case["workflow"], case.get("as-workflow", "fixture.yml"))
        expect = case.get("expect")
        if expect is None and violations:
            failures.append(f"case {case['name']!r} must pass, got: {violations}")
        elif expect is not None and (len(violations) != 1 or expect not in violations[0]):
            failures.append(f"case {case['name']!r} must fail once with {expect!r}, got: {violations}")

    if failures:
        print(f"✖ {len(failures)} App key confinement problem(s):", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        return 1
    print(f"✓ App key confinement: {len(files)} workflows keep the key in the token step "
          f"({len(token_workflows)} token steps, {len(used_entries)} emptiness checks); "
          f"{len(cases)} fixture cases behave.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.9"
# dependencies = ["pyyaml==6.0.3"]
# ///
"""Keep the Automation App private key confined to the token step.

Every workflow under .github/workflows/ and workflow-templates/ is parsed as
YAML. Every GitHub expression that reads the App private key
(secrets.AUTOMATION_APP_PRIVATE_KEY, secrets.app-private-key,
secrets.RELEASE_PLEASE_APP_PRIVATE_KEY, in dot or literal-index form) must sit
in one of these places:

- the `private-key:` input of an `actions/create-github-app-token` step pinned
  to a full commit SHA, in a job that declares `environment:`;
- the `env:` of an allowlisted step that only tests the key for emptiness
  (EMPTINESS_CHECKS). Its `run:` is pinned by SHA-256 so any edit needs a
  fresh review, runs in plain bash (no tracing via `shell:`, `defaults.run` or
  SHELLOPTS-style variables), and reads the variable only inside
  `[[ -n|-z "${VAR//[[:space:]]/}" ]]` conditions;
- the `secrets:` mapping of a job calling an App-key reusable workflow of this
  repository (pinned by SHA, or local), under AUTOMATION_APP_PRIVATE_KEY or
  app-private-key.

Any other use of the secrets context than `secrets.NAME` or `secrets['NAME']`
(toJSON(secrets), computed indexes) counts as exposing every secret.
`secrets: inherit` is only allowed towards the App-key reusable workflows.
Negative cases live in tests/fixtures/app-key-confinement-cases.yml. See
docs/automation-app.md ("The key only reaches the token step").
"""

from __future__ import annotations

import hashlib
import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
SCANNED_DIRS = (".github/workflows", "workflow-templates")
CASES = ROOT / "tests" / "fixtures" / "app-key-confinement-cases.yml"

# Contexts and secret names are case-insensitive in GitHub expressions.
KEY_NAMES = {"automation_app_private_key", "app-private-key", "release_please_app_private_key"}
EXPRESSION = re.compile(r"\$\{\{(.*?)\}\}", re.S)
# A string literal, or the `secrets` context outside one.
SECRETS_TOKEN = re.compile(r"'(?:[^']|'')*'|(?<![\w.-])(secrets)(?![\w-])", re.I)
SECRET_DOT = re.compile(r"\s*\.\s*([A-Za-z_][\w-]*)")
SECRET_INDEX = re.compile(r"\s*\[\s*'((?:[^']|'')*)'\s*\]")

TOKEN_ACTION = "actions/create-github-app-token@"
TOKEN_PINNED = re.compile(r"^actions/create-github-app-token@[0-9a-f]{40}$")
_reusables = r"\.github/workflows/(?:config-sync|release-please|apm-sync)\.ya?ml"
KEY_REUSABLES = re.compile(rf"^(?:DevSecNinja/\.github/{_reusables}@[0-9a-f]{{40}}|\./{_reusables})$")
KEY_SECRET_INPUTS = {"AUTOMATION_APP_PRIVATE_KEY", "app-private-key"}

# (workflow, job id, step name, env var) -> SHA-256 of the reviewed `run:` of
# the steps that may receive the key to test it for emptiness and print a
# friendly error before the token step. After editing one of these scripts,
# review that it still never prints, writes, traces or passes on the key or
# the environment, then update its hash (the failure message prints it).
EMPTINESS_CHECKS = {
    (".github/workflows/release-please.yml", "release-please", "Validate GitHub App credentials", "APP_PRIVATE_KEY"):
        "a7650154f6c1924cd8224a1b4df2c56a8be41677d1a5c5749e5e7d1cb3be3d49",
    (".github/workflows/config-sync.yml", "sync", "Resolve GitHub App credentials", "APP_PRIVATE_KEY"):
        "86bd10419e9a0c2b7773f77f881f1204596cfcba47a59e3790eb275371458f4a",
    (".github/workflows/apm-sync.yml", "apm-sync", "Resolve GitHub App credentials", "APP_PRIVATE_KEY"):
        "8a38cc5da27a7b24ffd18fdb6c53b2baf1926a2898cdb9f36555d6d0c0f2c5fa",
}
# Workflows that must keep a confined token-step reference, so the test cannot
# pass vacuously after a rename or a parsing change.
EXPECTED_TOKEN_STEPS = {
    ".github/workflows/release-please.yml",
    ".github/workflows/config-sync.yml",
    ".github/workflows/apm-sync.yml",
    ".github/workflows/apm-materialize.yml",
}
# Variables that make bash trace commands or run extra code before the script.
SHELL_BEHAVIOUR_VARS = {"SHELLOPTS", "BASHOPTS", "BASH_ENV", "ENV", "PS4", "BASH_XTRACEFD"}
_condition = r'-[nz]\s+"\$\{\w+//\[\[:space:\]\]/\}"'
EMPTINESS_LINE = re.compile(
    rf"^\s*(?:(?:el)?if\s+)?\[\[\s*{_condition}(?:\s*(?:\|\||&&)\s*{_condition})*\s*\]\]"
    r"(?:\s*;\s*then|\s*&&\s*\w+=true)?\s*$"
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


def secret_reads(path: tuple, text: str) -> tuple[bool, bool]:
    """Return (reads the App key, exposes the whole secrets context)."""
    expressions = EXPRESSION.findall(text)
    if path and path[-1] == "if" and "${{" not in text:
        expressions = [text]
    key = dump = False
    for expression in expressions:
        for match in SECRETS_TOKEN.finditer(expression):
            if not match.group(1):
                continue
            rest = expression[match.end():]
            access = SECRET_DOT.match(rest) or SECRET_INDEX.match(rest)
            if access is None:
                dump = True
            elif access.group(1).replace("''", "'").lower() in KEY_NAMES:
                key = True
    return key, dump


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


def run_shell(doc: dict, job: dict, step: dict):
    """The shell a run step uses: step, then job, then workflow defaults."""
    if "shell" in step:
        return step["shell"]
    for scope in (job, doc):
        shell = ((scope.get("defaults") or {}).get("run") or {}).get("shell")
        if shell is not None:
            return shell
    return None


def emptiness_problem(doc: dict, job: dict, step: dict, var: str, digest: str) -> str | None:
    if step.get("uses"):
        return "an allowlisted emptiness check must be a run step"
    shell = run_shell(doc, job, step)
    if shell not in (None, "bash"):
        return f"the allowlisted emptiness check must run in plain bash (effective shell: {shell!r})"
    for scope in (doc, job, step):
        risky = SHELL_BEHAVIOUR_VARS & set(scope.get("env") or {})
        if risky:
            return f"the allowlisted emptiness check inherits shell-behaviour variable(s) {sorted(risky)}"
    run = step.get("run") or ""
    for line in run.splitlines():
        if re.search(rf"(?<!\w){re.escape(var)}(?!\w)", line) and not EMPTINESS_LINE.match(line):
            return f"the allowlisted emptiness check reads ${var} outside an emptiness test: {line.strip()!r}"
    actual = hashlib.sha256(run.encode("utf-8")).hexdigest()
    if actual != digest:
        return (f"the allowlisted emptiness check changed since review (run: sha256 {actual}); confirm it never "
                f"prints, writes, traces or passes on the key or the environment, then update EMPTINESS_CHECKS")
    return None


def classify(doc: dict, rel: str, path: tuple, allowlist: dict, used: set) -> str | None:
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
        return emptiness_problem(doc, job, step, path[5], allowlist[entry])
    if part == "run":
        return "run script outside the emptiness-check allowlist"
    return f"step '{part}'"


def check(doc: dict, rel: str, allowlist: dict = EMPTINESS_CHECKS) -> tuple[list[str], set, bool]:
    """Return (violations, allowlist entries used, has a confined token-step reference)."""
    violations: list[str] = []
    used: set = set()
    key_jobs: set = set()
    token_step = False
    for path, text in walk(doc):
        key, dump = secret_reads(path, text)
        if dump:
            violations.append(f"{rel}: {location(doc, path)}: exposes every secret, including the App key")
            continue
        if not key:
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
    for entry in sorted(set(EMPTINESS_CHECKS) - used_entries):
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

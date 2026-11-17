#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.9"
# dependencies = ["pyyaml==6.0.3"]
# ///
"""Keep lint-include.yml a faithful include-mode front end for lint.yml.

lint-include.yml redeclares every input of lint.yml and passes it straight
through, with every `lint-<name>` linter defaulting to false, so callers run
only the linters they turn on and a linter added to lint.yml later stays off
for them. This test fails when:

- lint.yml has an input lint-include.yml doesn't declare, or the other way
  round;
- an input's type differs, a linter input isn't optional with default false,
  or another input's `required`/`default` differs from lint.yml;
- lint-include.yml isn't a single job calling `$/.github/workflows/lint.yml`
  that passes every input through as `${{ inputs.<name> }}`;
- that job grants fewer permissions than lint.yml's jobs use.

Broken copies are checked too, to prove the test bites.
"""

from __future__ import annotations

import copy
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
LINT = ROOT / ".github" / "workflows" / "lint.yml"
INCLUDE = ROOT / ".github" / "workflows" / "lint-include.yml"

LINT_REF = "$/.github/workflows/lint.yml"
# Boolean `lint-*` inputs of lint.yml that are options rather than linters.
NOT_LINTERS = {"lint-fail-on-error"}
LEVELS = {"none": 0, "read": 1, "write": 2}


def call_inputs(workflow: dict) -> dict:
    # PyYAML (YAML 1.1) reads the `on` key as True.
    triggers = workflow.get("on", workflow.get(True)) or {}
    return (triggers.get("workflow_call") or {}).get("inputs") or {}


def is_linter(name: str, spec: dict) -> bool:
    return name.startswith("lint-") and (spec or {}).get("type") == "boolean" and name not in NOT_LINTERS


def needed_permissions(lint: dict) -> dict:
    """The highest level lint.yml's jobs use per scope."""
    needed: dict = {}
    scopes = [lint.get("permissions")] + [(job or {}).get("permissions") for job in (lint.get("jobs") or {}).values()]
    for scope in scopes:
        for name, level in (scope or {}).items() if isinstance(scope, dict) else ():
            if LEVELS.get(level, 0) > LEVELS.get(needed.get(name, "none"), 0):
                needed[name] = level
    return needed


def check(lint: dict, include: dict) -> list[str]:
    problems: list[str] = []
    lint_inputs, include_inputs = call_inputs(lint), call_inputs(include)
    for name in sorted(set(lint_inputs) - set(include_inputs)):
        problems.append(f"lint-include.yml does not declare lint.yml input {name}")
    for name in sorted(set(include_inputs) - set(lint_inputs)):
        problems.append(f"lint-include.yml declares {name}, which lint.yml doesn't have")

    for name in sorted(set(lint_inputs) & set(include_inputs)):
        want, got = lint_inputs[name] or {}, include_inputs[name] or {}
        if got.get("type") != want.get("type"):
            problems.append(f"input {name} must be type {want.get('type')}, got {got.get('type')}")
        if is_linter(name, want):
            if got.get("required") is not False or got.get("default") is not False:
                problems.append(f"linter input {name} must be optional with default: false")
            continue
        for key in ("required", "default"):
            if got.get(key) != want.get(key):
                problems.append(f"input {name} must have {key}: {want.get(key)!r} like lint.yml, got {got.get(key)!r}")

    jobs = include.get("jobs") or {}
    if len(jobs) != 1:
        problems.append("lint-include.yml must have exactly one job")
        return problems
    job_id, job = next(iter(jobs.items()))
    job = job or {}
    if job.get("uses") != LINT_REF:
        problems.append(f"jobs.{job_id} must call {LINT_REF}, got {job.get('uses')!r}")
    given = job.get("with") or {}
    for name in sorted(lint_inputs):
        if given.get(name) != f"${{{{ inputs.{name} }}}}":
            problems.append(f"jobs.{job_id}.with.{name} must be ${{{{ inputs.{name} }}}}, got {given.get(name)!r}")
    for name in sorted(set(given) - set(lint_inputs)):
        problems.append(f"jobs.{job_id}.with.{name} is not an input of lint.yml")

    granted = job.get("permissions") or {}
    for name, level in sorted(needed_permissions(lint).items()):
        if LEVELS.get(granted.get(name, "none"), 0) < LEVELS[level]:
            problems.append(f"jobs.{job_id}.permissions must grant {name}: {level} (lint.yml uses it)")
    return problems


def broken_copies(lint: dict, include: dict):
    """Yield (description, lint.yml, lint-include.yml) triples that check() must reject."""

    def mutate(description, change, target="include"):
        broken_lint, broken_include = copy.deepcopy(lint), copy.deepcopy(include)
        change(broken_lint if target == "lint" else broken_include)
        return description, broken_lint, broken_include

    def job(workflow):
        return next(iter(workflow["jobs"].values()))

    yield mutate("a new lint.yml linter",
                 lambda w: call_inputs(w).update({"lint-newtool": {"type": "boolean", "default": True}}), "lint")
    yield mutate("a new lint.yml option",
                 lambda w: call_inputs(w).update({"lint-newtool-args": {"type": "string", "default": ""}}), "lint")
    yield mutate("a linter defaulting to true", lambda w: call_inputs(w)["lint-trivy"].update({"default": True}))
    yield mutate("a linter without a default", lambda w: call_inputs(w)["lint-trivy"].pop("default"))
    yield mutate("an option default that drifted", lambda w: call_inputs(w)["upload-sarif"].update({"default": False}))
    yield mutate("an optional mise-version", lambda w: call_inputs(w)["mise-version"].update({"required": False}))
    yield mutate("a retyped input", lambda w: call_inputs(w)["lint-job-mode"].update({"type": "boolean"}))
    yield mutate("an input not passed through", lambda w: job(w)["with"].pop("lint-shfmt-exclude"))
    yield mutate("a hard-coded value", lambda w: job(w)["with"].update({"lint-zizmor": False}))
    yield mutate("a value from another input",
                 lambda w: job(w)["with"].update({"lint-trivy": "${{ inputs.lint-checkov }}"}))
    yield mutate("a workspace-relative call", lambda w: job(w).update({"uses": "./.github/workflows/lint.yml"}))
    yield mutate("a missing permission", lambda w: job(w)["permissions"].pop("security-events"))
    yield mutate("a downgraded permission", lambda w: job(w)["permissions"].update({"security-events": "read"}))
    yield mutate("a permission lint.yml starts to need",
                 lambda w: w["jobs"]["trivy"]["permissions"].update({"actions": "read"}), "lint")


def main() -> int:
    lint = yaml.safe_load(LINT.read_text(encoding="utf-8"))
    include = yaml.safe_load(INCLUDE.read_text(encoding="utf-8"))
    failures = check(lint, include)
    cases = list(broken_copies(lint, include))
    for description, broken_lint, broken_include in cases:
        if not check(broken_lint, broken_include):
            failures.append(f"self-test: {description} was not caught")

    if failures:
        print(f"✖ {len(failures)} lint-include.yml problem(s):", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        return 1
    linters = sum(is_linter(name, spec) for name, spec in call_inputs(lint).items())
    print(f"✓ lint-include.yml forwards all {len(call_inputs(lint))} lint.yml inputs ({linters} linters off by "
          f"default); {len(cases)} broken variants are caught.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

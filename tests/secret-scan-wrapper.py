#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.9"
# dependencies = ["pyyaml==6.0.3"]
# ///
"""Keep the reusable secret-scan workflow down to gitleaks only.

.github/workflows/secret-scan.yml calls lint.yml with gitleaks on and every
other linter off, so secret-scan callers don't keep their own disable list.
lint.yml linters default to on, so a linter input added there without being
turned off in the wrapper would silently start running in every secret-scan
caller. This test fails when:

- lint.yml has a boolean `lint-*` linter input that the wrapper doesn't set to
  a literal `false` (or `lint-gitleaks` isn't a literal `true`);
- the wrapper passes an input lint.yml doesn't declare;
- the wrapper doesn't call this repository's lint.yml with `$/`, or doesn't
  pass its own inputs through.

The checks also run against broken copies of the wrapper to prove they bite.
"""

from __future__ import annotations

import copy
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
LINT = ROOT / ".github" / "workflows" / "lint.yml"
WRAPPER = ROOT / ".github" / "workflows" / "secret-scan.yml"

LINT_REF = "$/.github/workflows/lint.yml"
# Boolean `lint-*` inputs of lint.yml that aren't linters.
NOT_LINTERS = {"lint-fail-on-error"}
# Wrapper inputs passed through to lint.yml unchanged.
PASS_THROUGH = ("mise-version", "lint-config-dir", "lint-fail-on-error")


def call_inputs(workflow: dict) -> dict:
    # PyYAML (YAML 1.1) reads the `on` key as True.
    triggers = workflow.get("on", workflow.get(True)) or {}
    return (triggers.get("workflow_call") or {}).get("inputs") or {}


def check(lint: dict, wrapper: dict) -> list[str]:
    problems: list[str] = []
    lint_inputs = call_inputs(lint)
    linters = sorted(
        name for name, spec in lint_inputs.items()
        if name.startswith("lint-") and (spec or {}).get("type") == "boolean" and name not in NOT_LINTERS
    )
    if "lint-gitleaks" not in linters:
        problems.append("lint.yml has no boolean lint-gitleaks input")

    jobs = wrapper.get("jobs") or {}
    calls = {job_id: job for job_id, job in jobs.items() if isinstance(job, dict) and job.get("uses") == LINT_REF}
    if len(jobs) != 1 or len(calls) != 1:
        problems.append(f"secret-scan.yml must have exactly one job, calling {LINT_REF}")
        return problems
    job_id, job = next(iter(calls.items()))
    given = job.get("with") or {}

    for name in linters:
        want = name == "lint-gitleaks"
        if given.get(name) is not want:
            problems.append(f"jobs.{job_id}.with.{name} must be {str(want).lower()}, got {given.get(name)!r}")
    for name in sorted(set(given) - set(lint_inputs)):
        problems.append(f"jobs.{job_id}.with.{name} is not an input of lint.yml")

    wrapper_inputs = call_inputs(wrapper)
    for name in PASS_THROUGH:
        if name not in wrapper_inputs:
            problems.append(f"secret-scan.yml has no {name} input")
        if given.get(name) != f"${{{{ inputs.{name} }}}}":
            problems.append(f"jobs.{job_id}.with.{name} must pass through ${{{{ inputs.{name} }}}}")
    if (wrapper_inputs.get("mise-version") or {}).get("required") is not True:
        problems.append("secret-scan.yml must require mise-version (ADR 0001: callers own tool versions)")
    return problems


def broken_copies(wrapper: dict):
    """Yield (description, mutated wrapper) pairs that check() must reject."""
    job = next(iter(wrapper["jobs"]))

    def mutate(description, change):
        broken = copy.deepcopy(wrapper)
        change(broken["jobs"][job])
        return description, broken

    yield mutate("a linter left on", lambda j: j["with"].pop("lint-zizmor"))
    yield mutate("a linter set by expression", lambda j: j["with"].update({"lint-trivy": "${{ false }}"}))
    yield mutate("gitleaks off", lambda j: j["with"].update({"lint-gitleaks": False}))
    yield mutate("gitleaks left to the default", lambda j: j["with"].pop("lint-gitleaks"))
    yield mutate("an unknown input", lambda j: j["with"].update({"lint-typo": False}))
    yield mutate("a workspace-relative call", lambda j: j.update({"uses": "./.github/workflows/lint.yml"}))
    yield mutate("a hard-coded fail-on-error", lambda j: j["with"].update({"lint-fail-on-error": True}))


def main() -> int:
    lint = yaml.safe_load(LINT.read_text(encoding="utf-8"))
    wrapper = yaml.safe_load(WRAPPER.read_text(encoding="utf-8"))
    failures = check(lint, wrapper)

    new_linter = copy.deepcopy(lint)
    call_inputs(new_linter)["lint-newtool"] = {"type": "boolean", "default": True}
    if not any("lint-newtool" in problem for problem in check(new_linter, wrapper)):
        failures.append("self-test: a new lint.yml linter the wrapper doesn't turn off was not caught")
    cases = list(broken_copies(wrapper))
    for description, broken in cases:
        if not check(lint, broken):
            failures.append(f"self-test: {description} was not caught")

    if failures:
        print(f"✖ {len(failures)} secret-scan wrapper problem(s):", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        return 1
    print(f"✓ secret-scan.yml runs only gitleaks and turns off every other lint.yml linter; "
          f"{len(cases) + 1} broken variants are caught.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

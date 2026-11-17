#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.9"
# dependencies = ["pyyaml==6.0.3"]
# ///
"""Make every linter of lint.yml honour the `lint-only` input.

`lint-only: gitleaks` runs gitleaks and skips every other linter, so
secret-scan callers keep no list of linters to turn off. A linter added to
lint.yml later must honour the list too, or it silently starts running in all
of them. Jobs and steps are read from lint.yml, so new ones are checked
without editing this test:

- every linter job (all jobs except `all-linters` and the `lint-only`
  validation job) needs a boolean `lint-<job>` input, and its `if:` needs
  `inputs.lint-<job>` and the generated match for its own name (MATCH) as
  top-level `&&` terms;
- in the single-job `all-linters`, every step with an `id:` or whose `if:`
  reads a linter input needs both terms for one linter, or a top-level term
  that is false whenever an allowed predecessor step was skipped
  (`steps.<id>.outputs.<name> == '<non-empty>'` or
  `steps.<id>.outcome == 'success'`); SHARED_STEPS are exempt;
- the `lint-only` job runs whenever the input is set, can't be ignored by
  `continue-on-error`, and its `known` names equal the linter jobs.

The validation script is also run with bash against sample lists, and the
match expression is checked to agree with it. Broken copies of lint.yml are
checked too, to prove the test bites.
"""

from __future__ import annotations

import copy
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
LINT = ROOT / ".github" / "workflows" / "lint.yml"

INPUT = "lint-only"
VALIDATOR = "lint-only"
NOT_LINTERS = {"all-linters", VALIDATOR}
# Steps every enabled linter needs.
SHARED_STEPS = {"Install mise"}
TOKEN = re.compile(r"'(?:[^']|'')*'|&&|\|\||[()]|[^'()&|]+|.")
# A whole `&&` term that is false whenever step <id> was skipped.
SKIPS_WITH = re.compile(
    r"^steps\.([A-Za-z_][\w-]*)\.(?:outputs\.[\w-]+=='(?:[^']|'')+'|(?:outcome|conclusion)=='success')$")
KNOWN = re.compile(r'^known="([^"]*)"$', re.M)
BORDERS = ((",", ","), (",", " "), (" ", ","), (" ", " "))


def match(name: str) -> str:
    """The condition that is true when `lint-only` is empty or lists `name`.

    Expressions have no split or trim, so the list is padded with commas and
    the name matched with a comma or space on either side."""
    hay = "format(',{0},', inputs.lint-only)"
    return ("(inputs.lint-only == '' || "
            + " || ".join(f"contains({hay}, '{a}{name}{b}')" for a, b in BORDERS) + ")")


def match_value(name: str, value: str) -> bool:
    """What match(name) evaluates to (contains() is case-insensitive)."""
    hay = f",{value},".lower()
    return value == "" or any(f"{a}{name}{b}" in hay for a, b in BORDERS)


def squash(text: str) -> str:
    return re.sub(r"\s+", "", text)


def call_inputs(workflow: dict) -> dict:
    # PyYAML (YAML 1.1) reads the `on` key as True.
    triggers = workflow.get("on", workflow.get(True)) or {}
    return (triggers.get("workflow_call") or {}).get("inputs") or {}


def terms(condition) -> list[str]:
    """Top-level `&&` terms of an `if:`, whitespace removed; one term when `||` is top-level."""
    text = str(condition or "").strip()
    if text.startswith("${{") and text.endswith("}}"):
        text = text[3:-2]
    parts, current, depth, has_or = [], "", 0, False
    for token in TOKEN.findall(text):
        if token == "(":
            depth += 1
        elif token == ")":
            depth -= 1
        if depth == 0 and token == "&&":
            parts.append(current)
            current = ""
            continue
        has_or = has_or or (depth == 0 and token == "||")
        current += token
    parts.append(current)
    if has_or:
        parts = ["&&".join(parts)]
    return [squash(part) for part in parts]


def honours(step_terms: list[str], name: str) -> bool:
    return f"inputs.lint-{name}" in step_terms and squash(match(name)) in step_terms


def check(lint: dict) -> list[str]:
    problems: list[str] = []
    inputs = call_inputs(lint)
    spec = inputs.get(INPUT) or {}
    if spec.get("type") != "string" or spec.get("default") != "":
        problems.append(f"lint.yml must declare a string {INPUT} input defaulting to ''")

    jobs = lint.get("jobs") or {}
    for job_id in sorted(NOT_LINTERS - set(jobs)):
        problems.append(f"lint.yml has no {job_id} job")
    linters = sorted(set(jobs) - NOT_LINTERS)
    for name in linters:
        if (inputs.get(f"lint-{name}") or {}).get("type") != "boolean":
            problems.append(f"jobs.{name} has no boolean lint-{name} input")
        if not honours(terms((jobs[name] or {}).get("if")), name):
            problems.append(f"jobs.{name}.if must include `inputs.lint-{name} && {match(name)}` at its top level")

    validator = jobs.get(VALIDATOR) or {}
    if squash(str(validator.get("if"))) != squash("${{ inputs.lint-only != '' }}"):
        problems.append(f"jobs.{VALIDATOR}.if must be ${{{{ inputs.lint-only != '' }}}}")
    if "continue-on-error" in validator:
        problems.append(f"jobs.{VALIDATOR} must not set continue-on-error")
    known = KNOWN.search(validator_script(lint) or "")
    if not known:
        problems.append(f"jobs.{VALIDATOR} must define known=\"...\" in its script")
    elif sorted(known.group(1).split()) != linters:
        problems.append(f"jobs.{VALIDATOR} known names {sorted(known.group(1).split())} must equal the "
                        f"linter jobs {linters}")

    allowed: set[str] = set()
    for step in (jobs.get("all-linters") or {}).get("steps") or []:
        name, step_id = step.get("name"), step.get("id")
        condition = str(step.get("if") or "")
        reads_linter = any(re.search(rf"\binputs\.lint-{re.escape(n)}\b", condition) for n in linters)
        if name in SHARED_STEPS or not (step_id or reads_linter):
            continue
        step_terms = terms(condition)
        ok = (any(honours(step_terms, n) for n in linters)
              or any((m := SKIPS_WITH.match(term)) and m.group(1) in allowed for term in step_terms))
        if ok:
            allowed.add(step_id)
        else:
            problems.append(f"jobs.all-linters step {name!r} must include `inputs.lint-<linter> && "
                            f"<match for that linter>` at the top level of its if:")
    return problems


def validator_script(lint: dict) -> str | None:
    steps = ((lint.get("jobs") or {}).get(VALIDATOR) or {}).get("steps") or []
    return next((s.get("run") for s in steps if s.get("run")), None)


# (lint-only value, input overrides, accepted)
VALIDATION_CASES = [
    ("gitleaks", {}, True),
    (" gitleaks , trivy ", {}, True),
    ("gitleaks,trivy,", {}, True),
    ("gitleaks,  zizmor", {}, True),
    ("config-drift", {"lint-config-drift": True}, True),
    ("gitleak", {}, False),
    ("gitleaks trivy", {}, False),
    ("GitLeaks", {}, False),
    ("gitleaks\ntrivy", {}, False),
    ("gitleaks;trivy", {}, False),
    (",", {}, False),
    (" ", {}, False),
    ("config-drift", {}, False),
    ("trivy", {"lint-trivy": False}, False),
]


def check_validator(lint: dict) -> list[str]:
    bash = shutil.which("bash")
    script = validator_script(lint)
    if not script:
        return [f"jobs.{VALIDATOR} has no run script"]
    if not bash or not shutil.which("jq"):
        return ["bash and jq are needed to run the validator"] if os.environ.get("CI") else []
    defaults = {name: spec.get("default") for name, spec in call_inputs(lint).items()}
    linters = sorted(set(lint.get("jobs") or {}) - NOT_LINTERS)
    problems = []
    for value, overrides, accepted in VALIDATION_CASES:
        env = {**os.environ, "LINT_ONLY": value, "INPUTS": json.dumps({**defaults, INPUT: value, **overrides})}
        result = subprocess.run([bash, "-c", script], env=env, capture_output=True, text=True)
        if (result.returncode == 0) != accepted:
            problems.append(f"validator {'rejects' if accepted else 'accepts'} lint-only {value!r}: "
                            f"{result.stdout.strip() or result.stderr.strip()}")
        if accepted:
            names = {part.strip() for part in value.split(",")} - {""}
            for name in linters:
                if match_value(name, value) != (name in names):
                    problems.append(f"the job condition for {name} disagrees with the validator on {value!r}")
    return problems


def broken_copies(lint: dict):
    """Yield (description, mutated lint.yml) pairs that check() must reject."""

    def mutate(description, change):
        broken = copy.deepcopy(lint)
        change(broken["jobs"])
        return description, broken

    def step(jobs, step_id):
        return next(s for s in jobs["all-linters"]["steps"] if s.get("id") == step_id)

    def set_known(jobs, names):
        run = jobs[VALIDATOR]["steps"][0]["run"]
        jobs[VALIDATOR]["steps"][0]["run"] = KNOWN.sub(f'known="{names}"', run, count=1)

    yield mutate("a job without the match", lambda j: j["dprint"].update({"if": "${{ inputs.lint-dprint }}"}))
    yield mutate("a job matching another linter's name",
                 lambda j: j["dprint"].update({"if": f"${{{{ inputs.lint-dprint && {match('trivy')} }}}}"}))
    yield mutate("a new job without the match",
                 lambda j: j.update({"newtool": {"if": "${{ inputs.lint-newtool }}", "runs-on": "ubuntu-24.04"}}))
    yield mutate("a new job without any if", lambda j: j.update({"newtool": {"runs-on": "ubuntu-24.04"}}))
    yield mutate("the match only inside an || term",
                 lambda j: j["trivy"].update({"if": f"${{{{ inputs.lint-trivy || {match('trivy')} }}}}"}))
    yield mutate("a single-job step without the match",
                 lambda j: step(j, "zizmor").update({"if": "${{ inputs.lint-zizmor }}"}))
    yield mutate("a SARIF step without the match",
                 lambda j: step(j, "trivy-sarif").update({"if": "${{ inputs.lint-trivy && inputs.upload-sarif }}"}))
    yield mutate("a new single-job step without any if",
                 lambda j: j["all-linters"]["steps"].insert(-1, {"name": "Run newtool", "id": "newtool", "run": "x"}))
    yield mutate("a validator that can be ignored", lambda j: j[VALIDATOR].update({"continue-on-error": True}))
    yield mutate("a validator that doesn't always run",
                 lambda j: j[VALIDATOR].update({"if": "${{ inputs.lint-only != '' && inputs.lint-fail-on-error }}"}))
    yield mutate("a known list missing a linter", lambda j: set_known(j, "gitleaks trivy"))
    for description, condition in (
        ("a step running when its predecessor was skipped", "${{ steps.setup-go.outcome == 'skipped' }}"),
        ("a step on a negative output comparison", "${{ steps.go-version-file.outputs.exists != 'false' }}"),
        ("a step on an empty-output comparison", "${{ steps.go-version-file.outputs.exists == '' }}"),
        ("a predecessor reference inside ||", "${{ steps.setup-go.outcome == 'success' || inputs.lint-go }}"),
        ("a predecessor reference inside a parenthesised ||",
         "${{ (steps.setup-go.outcome == 'success' || always()) && inputs.golangci-lint-version != '' }}"),
    ):
        yield mutate(description, lambda j, c=condition: step(j, "go").update({"if": c}))


def main() -> int:
    lint = yaml.safe_load(LINT.read_text(encoding="utf-8"))
    failures = check(lint) + check_validator(lint)

    no_input = copy.deepcopy(lint)
    call_inputs(no_input).pop(INPUT, None)
    if not any(f"declare a string {INPUT}" in problem for problem in check(no_input)):
        failures.append(f"self-test: a missing {INPUT} input was not caught")
    cases = list(broken_copies(lint))
    for description, broken in cases:
        if not check(broken):
            failures.append(f"self-test: {description} was not caught")

    if failures:
        print(f"✖ {len(failures)} {INPUT} problem(s):", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        return 1
    ran = f"{len(VALIDATION_CASES)} lists validated" if shutil.which("bash") and shutil.which("jq") else \
        "validator not run (no bash/jq)"
    print(f"✓ {INPUT}: every lint.yml linter job and single-job step honours the list; {ran}; "
          f"{len(cases) + 1} broken variants are caught.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

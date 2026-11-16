#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.9"
# dependencies = ["pyyaml==6.0.3"]
# ///
"""Make `lint-gitleaks-only` skip every linter of lint.yml except gitleaks.

Secret-scan callers set `lint-gitleaks-only: true` instead of turning each
other linter off, so a linter added to lint.yml later must honour the flag or
it silently starts running in all of them. Jobs and steps are read from
lint.yml, so new ones are checked without editing this test:

- every job except `gitleaks` and the single-job `all-linters` must have
  `!inputs.lint-gitleaks-only` as a top-level `&&` term of its `if:`;
- in `all-linters` (which also hosts gitleaks), every step with an `id:` or
  whose `if:` reads a linter input must be a gitleaks step (top-level
  `inputs.lint-gitleaks`), honour the flag the same way, or have a top-level
  term that is false whenever an allowed predecessor step was skipped
  (`steps.<id>.outputs.<name> == '<non-empty>'` or
  `steps.<id>.outcome == 'success'`). Shared setup steps are listed in
  SHARED_STEPS.

Broken copies of lint.yml are checked too, to prove the test bites.
"""

from __future__ import annotations

import copy
import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
LINT = ROOT / ".github" / "workflows" / "lint.yml"

FLAG = "lint-gitleaks-only"
HONOURS = f"!inputs.{FLAG}"
GITLEAKS = "inputs.lint-gitleaks"
EXEMPT_JOBS = {"gitleaks", "all-linters"}
# Steps every enabled linter needs, gitleaks included.
SHARED_STEPS = {"Install mise"}
# Boolean `lint-*` inputs that are options rather than linters.
NOT_LINTERS = {"lint-fail-on-error", FLAG}
TOKEN = re.compile(r"'(?:[^']|'')*'|&&|\|\||[()]|[^'()&|]+|.")
# A whole `&&` term that is false whenever step <id> was skipped: one of its
# outputs equals a non-empty literal, or it succeeded.
SKIPS_WITH = re.compile(r"^steps\.([A-Za-z_][\w-]*)\.(?:outputs\.[\w-]+=='(?:[^']|'')+'|(?:outcome|conclusion)=='success')$")


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
    return [re.sub(r"\s+", "", part) for part in parts]


def check(lint: dict) -> list[str]:
    problems: list[str] = []
    inputs = call_inputs(lint)
    spec = inputs.get(FLAG) or {}
    if spec.get("type") != "boolean" or spec.get("default") is not False:
        problems.append(f"lint.yml must declare a boolean {FLAG} input defaulting to false")
    linters = {name for name, s in inputs.items()
               if name.startswith("lint-") and (s or {}).get("type") == "boolean" and name not in NOT_LINTERS}
    other_linters = linters - {"lint-gitleaks"}

    jobs = lint.get("jobs") or {}
    for job_id in sorted(set(EXEMPT_JOBS) - set(jobs)):
        problems.append(f"lint.yml has no {job_id} job")
    for job_id, job in jobs.items():
        if job_id not in EXEMPT_JOBS and HONOURS not in terms(job.get("if")):
            problems.append(f"jobs.{job_id}.if must include `&& {HONOURS}` at its top level")

    allowed: set[str] = set()
    for step in (jobs.get("all-linters") or {}).get("steps") or []:
        name, step_id = step.get("name"), step.get("id")
        condition = str(step.get("if") or "")
        reads_linter = any(re.search(rf"\binputs\.{re.escape(n)}\b", condition) for n in other_linters)
        if name in SHARED_STEPS or not (step_id or reads_linter):
            continue
        step_terms = terms(condition)
        ok = (HONOURS in step_terms or GITLEAKS in step_terms
              or any((m := SKIPS_WITH.match(term)) and m.group(1) in allowed for term in step_terms))
        if ok:
            allowed.add(step_id)
        else:
            problems.append(f"jobs.all-linters step {name!r} must include `&& {HONOURS}` at the top level of its if:")
    return problems


def broken_copies(lint: dict):
    """Yield (description, mutated lint.yml) pairs that check() must reject."""

    def mutate(description, change):
        broken = copy.deepcopy(lint)
        change(broken["jobs"])
        return description, broken

    def step(jobs, step_id):
        return next(s for s in jobs["all-linters"]["steps"] if s.get("id") == step_id)

    yield mutate("a job without the flag",
                 lambda j: j["dprint"].update({"if": "${{ inputs.lint-dprint }}"}))
    yield mutate("a new job without the flag",
                 lambda j: j.update({"newtool": {"if": "${{ inputs.lint-newtool }}", "runs-on": "ubuntu-24.04"}}))
    yield mutate("a new job without any if",
                 lambda j: j.update({"newtool": {"runs-on": "ubuntu-24.04"}}))
    yield mutate("the flag only inside an || term",
                 lambda j: j["trivy"].update({"if": f"${{{{ inputs.lint-trivy || {HONOURS} }}}}"}))
    yield mutate("a single-job step without the flag",
                 lambda j: step(j, "zizmor").update({"if": "${{ inputs.lint-zizmor }}"}))
    yield mutate("a SARIF step without the flag",
                 lambda j: step(j, "trivy-sarif").update({"if": "${{ inputs.lint-trivy && inputs.upload-sarif }}"}))
    yield mutate("a new single-job step without any if",
                 lambda j: j["all-linters"]["steps"].insert(-1, {"name": "Run newtool", "id": "newtool", "run": "x"}))
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
    failures = check(lint)

    no_flag = copy.deepcopy(lint)
    call_inputs(no_flag).pop(FLAG, None)
    if not any(f"declare a boolean {FLAG}" in problem for problem in check(no_flag)):
        failures.append(f"self-test: a missing {FLAG} input was not caught")
    cases = list(broken_copies(lint))
    for description, broken in cases:
        if not check(broken):
            failures.append(f"self-test: {description} was not caught")

    if failures:
        print(f"✖ {len(failures)} {FLAG} problem(s):", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        return 1
    print(f"✓ {FLAG}: every lint.yml job and single-job step except gitleaks honours the flag; "
          f"{len(cases) + 1} broken variants are caught.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

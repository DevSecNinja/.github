#!/usr/bin/env python3
"""Pin down which jobs of the reusable workflows run for representative events.

Every job that runs is billed at least one full minute, so the job-level `if:`
conditions in pages.yml and lint.yml are part of the cost contract (ADR 0010).
This script reads those conditions straight from the workflow files, evaluates
them with a small evaluator for the subset of the GitHub Actions expression
language they use, propagates `needs:` the way Actions does (an unmet need
skips a job unless its condition calls a status function), and compares the
resulting set of running jobs with the expectations below.

Standard library only, so it runs anywhere `python3` exists.
"""

from __future__ import annotations

import math
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WORKFLOWS = ROOT / ".github" / "workflows"


# --------------------------------------------------------------------------
# Workflow parsing (just job ids, `needs:`, and job-level `if:`).
# --------------------------------------------------------------------------


def parse_jobs(path: Path) -> dict[str, dict]:
    lines = path.read_text(encoding="utf-8").splitlines()
    jobs: dict[str, dict] = {}
    in_jobs = False
    current = None
    i = 0
    while i < len(lines):
        line = lines[i]
        if line.rstrip() == "jobs:":
            in_jobs = True
            i += 1
            continue
        if in_jobs and re.match(r"^\S", line):
            in_jobs = False
        if not in_jobs:
            i += 1
            continue
        match = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line)
        if match:
            current = match.group(1)
            jobs[current] = {"if": None, "needs": []}
            i += 1
            continue
        if current is None:
            i += 1
            continue
        match = re.match(r"^    if:\s*(.*)$", line)
        if match:
            value = match.group(1).strip()
            # Block scalars (`>-`) and wrapped plain scalars both continue on
            # deeper-indented lines; YAML folds either into one line.
            parts = [] if value in (">-", ">", "|-", "|") else [value]
            j = i + 1
            while j < len(lines) and lines[j].startswith("      ") and lines[j].strip():
                parts.append(lines[j].strip())
                j += 1
            jobs[current]["if"] = " ".join(parts)
            i = j
            continue
        match = re.match(r"^    needs:\s*(.*)$", line)
        if match:
            value = match.group(1).strip()
            if value.startswith("["):
                jobs[current]["needs"] = [v.strip() for v in value.strip("[]").split(",") if v.strip()]
            elif value:
                jobs[current]["needs"] = [value]
            else:
                j = i + 1
                while j < len(lines) and re.match(r"^      - ", lines[j]):
                    jobs[current]["needs"].append(lines[j].strip()[2:].strip())
                    j += 1
                i = j
                continue
        i += 1
    return jobs


# --------------------------------------------------------------------------
# Expression evaluator (GitHub Actions semantics for the subset in use).
# --------------------------------------------------------------------------

TOKEN = re.compile(
    r"""\s*(?:
        (?P<str>'(?:[^']|'')*')
      | (?P<num>\d+(?:\.\d+)?)
      | (?P<op>==|!=|&&|\|\||!|\(|\)|,)
      | (?P<ident>[A-Za-z_][A-Za-z0-9_.\-]*)
    )""",
    re.X,
)
STATUS_FUNCTIONS = re.compile(r"\b(success|always|cancelled|failure)\(")


def tokenize(text: str) -> list[tuple[str, str]]:
    tokens = []
    pos = 0
    text = text.strip()
    while pos < len(text):
        match = TOKEN.match(text, pos)
        if not match or match.end() == pos:
            raise ValueError(f"cannot tokenize at {text[pos:pos + 30]!r}")
        kind = match.lastgroup
        tokens.append((kind, match.group(kind)))
        pos = match.end()
        while pos < len(text) and text[pos].isspace():
            pos += 1
    return tokens


def kind_of(value) -> str:
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "bool"
    if isinstance(value, (int, float)):
        return "number"
    if isinstance(value, str):
        return "string"
    return "object"


def to_number(value) -> float:
    kind = kind_of(value)
    if kind == "null":
        return 0.0
    if kind == "bool":
        return 1.0 if value else 0.0
    if kind == "number":
        return float(value)
    if kind == "string":
        stripped = value.strip()
        if not stripped:
            return 0.0
        try:
            return float(stripped)
        except ValueError:
            return math.nan
    return math.nan


def loose_equal(left, right) -> bool:
    left_kind, right_kind = kind_of(left), kind_of(right)
    if left_kind == right_kind:
        if left_kind == "string":
            return left.lower() == right.lower()
        if left_kind == "object":
            return left is right
        return left == right
    return to_number(left) == to_number(right)


def truthy(value) -> bool:
    if value is None or value is False or value == "":
        return False
    if kind_of(value) == "number":
        return not (value == 0 or math.isnan(value))
    return True


class Evaluator:
    def __init__(self, context: dict, needs_ok: bool):
        self.context = context
        self.needs_ok = needs_ok

    def evaluate(self, expression: str):
        expression = expression.strip()
        if expression.startswith("${{") and expression.endswith("}}"):
            expression = expression[3:-2]
        self.tokens = tokenize(expression)
        self.pos = 0
        value = self.parse_or()
        if self.pos != len(self.tokens):
            raise ValueError(f"unexpected token {self.tokens[self.pos]} in {expression!r}")
        return value

    def peek(self):
        return self.tokens[self.pos] if self.pos < len(self.tokens) else (None, None)

    def take(self, op=None):
        token = self.peek()
        if op is not None and token[1] != op:
            raise ValueError(f"expected {op!r}, got {token}")
        self.pos += 1
        return token

    def parse_or(self):
        left = self.parse_and()
        while self.peek()[1] == "||":
            self.take()
            right = self.parse_and()
            left = left if truthy(left) else right
        return left

    def parse_and(self):
        left = self.parse_comparison()
        while self.peek()[1] == "&&":
            self.take()
            right = self.parse_comparison()
            left = right if truthy(left) else left
        return left

    def parse_comparison(self):
        left = self.parse_unary()
        while self.peek()[1] in ("==", "!="):
            op = self.take()[1]
            right = self.parse_unary()
            equal = loose_equal(left, right)
            left = equal if op == "==" else not equal
        return left

    def parse_unary(self):
        if self.peek()[1] == "!":
            self.take()
            return not truthy(self.parse_unary())
        return self.parse_primary()

    def parse_primary(self):
        kind, text = self.take()
        if text == "(":
            value = self.parse_or()
            self.take(")")
            return value
        if kind == "str":
            return text[1:-1].replace("''", "'")
        if kind == "num":
            return float(text)
        if kind != "ident":
            raise ValueError(f"unexpected token {text!r}")
        if text in ("true", "false"):
            return text == "true"
        if text == "null":
            return None
        if self.peek()[1] == "(":
            self.take()
            args = []
            while self.peek()[1] != ")":
                args.append(self.parse_or())
                if self.peek()[1] == ",":
                    self.take()
            self.take(")")
            return self.call(text, args)
        value = self.context
        for part in text.split("."):
            value = value.get(part) if isinstance(value, dict) else None
        return value

    def call(self, name, args):
        if name == "success":
            return self.needs_ok
        if name == "always":
            return True
        if name in ("cancelled", "failure"):
            return False
        if name == "format":
            result = str(args[0])
            for index, arg in enumerate(args[1:]):
                result = result.replace("{" + str(index) + "}", "" if arg is None else str(arg))
            return result
        raise ValueError(f"unsupported function {name}()")


def running_jobs(jobs: dict[str, dict], context: dict, outputs: dict | None = None) -> set[str]:
    """Simulate the run, assuming every job that starts succeeds."""
    results: dict[str, str] = {}
    outputs = outputs or {}
    pending = list(jobs)
    while pending:
        progressed = False
        for job in list(pending):
            needs = jobs[job]["needs"]
            if any(need not in results for need in needs):
                continue
            needs_ok = all(results[need] == "success" for need in needs)
            ctx = dict(context)
            ctx["needs"] = {
                need: {"result": results[need], "outputs": outputs.get(need, {}) if results[need] == "success" else {}}
                for need in needs
            }
            condition = jobs[job]["if"]
            if condition is None:
                runs = needs_ok
            else:
                value = truthy(Evaluator(ctx, needs_ok).evaluate(condition))
                runs = value if STATUS_FUNCTIONS.search(condition) else needs_ok and value
            results[job] = "success" if runs else "skipped"
            pending.remove(job)
            progressed = True
        if not progressed:
            raise ValueError(f"unresolvable needs among {pending}")
    return {job for job, result in results.items() if result == "success"}


# --------------------------------------------------------------------------
# Scenarios.
# --------------------------------------------------------------------------

failures: list[str] = []


def check(workflow: str, name: str, actual: set[str], expected: set[str]) -> None:
    if actual != expected:
        failures.append(
            f"{workflow}: {name}\n    expected: {sorted(expected)}\n    actual:   {sorted(actual)}"
        )


def pages_context(event_name, *, action=None, actor="DevSecNinja", author=None, ref="refs/heads/main",
                  changes=None, fork=False, preview=True):
    event: dict = {"repository": {"name": "site", "private": True}}
    if event_name == "pull_request":
        event.update(
            action=action,
            pull_request={
                "user": {"login": author or actor},
                "head": {"repo": {"full_name": "someone/site" if fork else "DevSecNinja/site"}, "sha": "abc"},
            },
        )
        if changes is not None:
            event["changes"] = changes
    return {
        "github": {"event_name": event_name, "event": event, "actor": actor, "ref": ref,
                   "repository": "DevSecNinja/site"},
        "inputs": {"cloudflare-preview": preview, "github-pages": True, "production-branch": "main",
                   "cloudflare-custom-domain": ""},
    }


PAGES_OUTPUTS = {"detect-cloudflare": {"enabled": "true", "targets": "[]", "deploy-production": "false",
                                       "project-name": "site"}}
PRODUCTION = {"validate-inputs", "detect-cloudflare", "test", "deploy"}
PREVIEW = {"validate-inputs", "detect-cloudflare", "test", "deploy-preview"}
TEST_ONLY = {"validate-inputs", "test"}
CLOSE = {"validate-inputs", "detect-cloudflare", "close-preview"}
NOTHING: set[str] = set()

pages = parse_jobs(WORKFLOWS / "pages.yml")
pages_scenarios = [
    ("push to main", pages_context("push"), PRODUCTION),
    ("push to main by renovate[bot] (branch automerge)", pages_context("push", actor="renovate[bot]"), PRODUCTION),
    ("workflow_dispatch on main", pages_context("workflow_dispatch"), PRODUCTION),
    ("human PR opened", pages_context("pull_request", action="opened"), PREVIEW),
    ("human PR synchronize", pages_context("pull_request", action="synchronize"), PREVIEW),
    ("human PR, previews disabled", pages_context("pull_request", action="opened", preview=False),
     {"validate-inputs", "detect-cloudflare", "test"}),
    ("fork PR opened", pages_context("pull_request", action="opened", fork=True),
     {"validate-inputs", "detect-cloudflare", "test"}),
    ("Renovate PR synchronize", pages_context("pull_request", action="synchronize", actor="renovate[bot]"), TEST_ONLY),
    ("Renovate PR updated by a human", pages_context("pull_request", action="synchronize", author="renovate[bot]"),
     TEST_ONLY),
    ("Dependabot PR opened", pages_context("pull_request", action="opened", actor="dependabot[bot]"), TEST_ONLY),
    ("Renovate edits its PR body", pages_context("pull_request", action="edited", actor="renovate[bot]",
                                                  changes={"body": {"from": "old"}}), NOTHING),
    ("human edits PR title", pages_context("pull_request", action="edited", changes={"title": {"from": "x"}}),
     NOTHING),
    ("human changes PR base branch", pages_context("pull_request", action="edited",
                                                    changes={"base": {"ref": {"from": "develop"}}}), PREVIEW),
    ("human PR closed", pages_context("pull_request", action="closed"), CLOSE),
    ("human PR closed, previews disabled", pages_context("pull_request", action="closed", preview=False), NOTHING),
    ("fork PR closed", pages_context("pull_request", action="closed", fork=True), NOTHING),
    ("Renovate PR automerged", pages_context("pull_request", action="closed", actor="renovate[bot]"), NOTHING),
    ("Renovate PR merged by a human", pages_context("pull_request", action="closed", author="renovate[bot]"),
     NOTHING),
]
for name, context, expected in pages_scenarios:
    check("pages.yml", name, running_jobs(pages, context, PAGES_OUTPUTS), expected)


def lint_context(*, mode="auto", private=False, has_repository=True, event_name="pull_request", **toggles):
    inputs = {f"lint-{name}": True for name in ("dprint", "yamlfmt", "yamllint", "actionlint", "gitleaks", "go",
                                                "shellcheck", "shfmt", "checkov", "trivy", "zizmor")}
    inputs["lint-config-drift"] = False
    inputs["lint-job-mode"] = mode
    inputs.update({f"lint-{k.replace('_', '-')}": v for k, v in toggles.items()})
    event = {"repository": {"private": private}} if has_repository else {"schedule": "0 0 * * 1"}
    return {"github": {"event_name": event_name, "event": event}, "inputs": inputs}


lint = parse_jobs(WORKFLOWS / "lint.yml")
PER_LINTER = {"dprint", "yamlfmt", "yamllint", "actionlint", "gitleaks", "go", "shellcheck", "shfmt", "checkov",
              "trivy", "zizmor"}
SINGLE = {"all-linters"}
lint_scenarios = [
    ("public repo, auto", lint_context(), PER_LINTER),
    ("private repo, auto", lint_context(private=True), SINGLE),
    ("schedule event without repository payload, auto", lint_context(has_repository=False, event_name="schedule"),
     PER_LINTER),
    ("public repo, single", lint_context(mode="single"), SINGLE),
    ("private repo, parallel", lint_context(mode="parallel", private=True), PER_LINTER),
    ("private repo, parallel, go and trivy off", lint_context(mode="parallel", private=True, go=False, trivy=False),
     PER_LINTER - {"go", "trivy"}),
    ("public repo, config drift on", lint_context(config_drift=True), PER_LINTER | {"config-drift"}),
    ("invalid mode fails loudly in the single job", lint_context(mode="bogus"), SINGLE),
]
for name, context, expected in lint_scenarios:
    check("lint.yml", name, running_jobs(lint, context), expected)


def labeler_context(event_name, *, author="DevSecNinja", fork=False):
    event: dict = {}
    if event_name == "issues":
        event["issue"] = {"user": {"login": author}}
    else:
        event["pull_request"] = {"user": {"login": author},
                                 "head": {"repo": {"full_name": "someone/repo" if fork else "DevSecNinja/repo"}}}
    return {"github": {"event_name": event_name, "event": event, "repository": "DevSecNinja/repo"}}


labeler = parse_jobs(WORKFLOWS / "labeler.yml")
labeler_scenarios = [
    ("human opens or edits an issue", labeler_context("issues"), {"issue-labeler"}),
    ("Renovate edits its Dependency Dashboard", labeler_context("issues", author="renovate[bot]"), NOTHING),
    ("same-repository PR", labeler_context("pull_request"), {"pr-labeler"}),
    ("fork PR", labeler_context("pull_request", fork=True), NOTHING),
]
for name, context, expected in labeler_scenarios:
    check("labeler.yml", name, running_jobs(labeler, context), expected)

if failures:
    print(f"✖ {len(failures)} job-condition scenario(s) failed:", file=sys.stderr)
    for failure in failures:
        print(f"  - {failure}", file=sys.stderr)
    sys.exit(1)

print(f"✓ Job conditions: {len(pages_scenarios)} pages.yml, {len(lint_scenarios)} lint.yml and "
      f"{len(labeler_scenarios)} labeler.yml scenarios run exactly the expected jobs.")

#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.9"
# dependencies = ["pyyaml==6.0.3"]
# ///
"""Every reusable-workflow job that runs a script from scripts/ fetches it first.

The reusable workflows run in the caller's checkout, so their scripts (#537)
come from the DevSecNinja/.github commit the caller pinned. A job whose run
steps call "${RUNNER_TEMP}/devsecninja-<kind>/<path>" must start with:

1. an actions/checkout step, pinned to a full SHA, of job.workflow_repository at
   job.workflow_sha into .devsecninja-<kind>, without persisted credentials,
   whose sparse checkout includes <path>;
2. `mv .devsecninja-<kind> "${RUNNER_TEMP}/devsecninja-<kind>"`, so the code
   checkout doesn't delete the scripts and the caller's linters don't scan them.

When the fetch steps are conditional, every step that runs a script must carry
the same condition, so a script never runs without having been fetched. Every
script must exist in this repository.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
WORKFLOWS = ROOT / ".github" / "workflows"
SCRIPT_REF = re.compile(r"\$\{RUNNER_TEMP\}/devsecninja-([\w-]+)/([^\"\s]+)")
CHECKOUT = re.compile(r"^actions/checkout@[0-9a-f]{40}$")
# Workflows that must keep fetching scripts, so the test cannot pass vacuously.
EXPECTED = {"label-sync.yml", "lint.yml", "pages.yml"}


def check_job(name: str, job: dict) -> tuple[list[str], int]:
    steps = job.get("steps") or []
    uses: dict[str, list[tuple[dict, str]]] = {}
    for step in steps:
        for kind, path in SCRIPT_REF.findall(str(step.get("run") or "")):
            uses.setdefault(kind, []).append((step, path))
    if not uses:
        return [], 0
    if len(uses) > 1:
        return [f"{name}: runs scripts of several kinds {sorted(uses)}; fetch one kind per job"], 0
    (kind, used), = uses.items()
    if len(steps) < 2:
        return [f"{name}: runs scripts but has no fetch steps"], 0
    fetch, move = steps[0], steps[1]
    errors = []
    expected_with = {
        "repository": "${{ job.workflow_repository }}",
        "ref": "${{ job.workflow_sha }}",
        "path": f".devsecninja-{kind}",
        "sparse-checkout-cone-mode": False,
        "persist-credentials": False,
    }
    if not CHECKOUT.match(str(fetch.get("uses") or "")):
        errors.append(f"{name}: the first step must be actions/checkout pinned to a full SHA")
    with_ = fetch.get("with") or {}
    for key, value in expected_with.items():
        if with_.get(key) != value:
            errors.append(f"{name}: the fetch step must set {key}: {value!r} (found {with_.get(key)!r})")
    expected_move = f'mv .devsecninja-{kind} "${{RUNNER_TEMP}}/devsecninja-{kind}"'
    if str(move.get("run") or "").strip() != expected_move:
        errors.append(f"{name}: the second step must run `{expected_move}`")
    if fetch.get("if") != move.get("if"):
        errors.append(f"{name}: the fetch and move steps must share one condition")
    sparse = str(with_.get("sparse-checkout") or "").split()
    for step, path in used:
        label = f"{name}: step {step.get('name')!r}"
        if not (ROOT / path).is_file():
            errors.append(f"{label} runs {path}, which does not exist")
        if not any(path == entry or (entry.endswith("/") and path.startswith(entry)) for entry in sparse):
            errors.append(f"{label} runs {path}, which the fetch step's sparse checkout leaves out")
        if "if" in fetch and step.get("if") != fetch["if"]:
            errors.append(f"{label} must share the fetch condition {fetch['if']!r} (found {step.get('if')!r})")
    return errors, len(used)


def main() -> int:
    errors: list[str] = []
    fetching: dict[str, int] = {}
    for file in sorted(WORKFLOWS.glob("*.y*ml")):
        doc = yaml.safe_load(file.read_text(encoding="utf-8")) or {}
        for job_id, job in (doc.get("jobs") or {}).items():
            if not isinstance(job, dict):
                continue
            job_errors, count = check_job(f"{file.name} job {job_id}", job)
            errors += job_errors
            if count:
                fetching[file.name] = fetching.get(file.name, 0) + count
    for name in sorted(EXPECTED - set(fetching)):
        errors.append(f"{name}: expected jobs that run fetched scripts, found none")
    if errors:
        print(f"✖ {len(errors)} script fetch problem(s):", file=sys.stderr)
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
        return 1
    summary = ", ".join(f"{name} ({count})" for name, count in sorted(fetching.items()))
    print(f"✓ Workflow scripts: every script step fetches its script at job.workflow_sha first: {summary}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

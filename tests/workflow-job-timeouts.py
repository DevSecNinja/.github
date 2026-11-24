# /// script
# requires-python = ">=3.9"
# dependencies = ["pyyaml==6.0.3"]
# ///
"""Every job that runs steps sets `timeout-minutes`.

Without one, a hung job keeps its runner for GitHub's default of 360 minutes
and bills every one of them. Jobs that call a reusable workflow (`uses:`)
can't set `timeout-minutes`; the called workflow's jobs carry their own.

The test fails when a job with `steps` has no `timeout-minutes`, or sets one
that isn't a whole number from 1 to 60 (pick a value from the job's recent run
durations, roughly 3x the p95 and at least 5). Broken copies are checked too,
to prove the test bites.
"""

from __future__ import annotations

import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
WORKFLOWS = ROOT / ".github" / "workflows"
MAX_MINUTES = 60


def problems(name: str, workflow: dict) -> list[str]:
    found = []
    for job_id, job in (workflow.get("jobs") or {}).items():
        if "uses" in job:
            continue
        timeout = job.get("timeout-minutes")
        if timeout is None:
            found.append(f"{name}: job '{job_id}' has no timeout-minutes")
        elif isinstance(timeout, bool) or not isinstance(timeout, int) or not 1 <= timeout <= MAX_MINUTES:
            found.append(
                f"{name}: job '{job_id}' timeout-minutes {timeout!r} isn't a whole number from 1 to {MAX_MINUTES}"
            )
    return found


failures: list[str] = []
paths = sorted(WORKFLOWS.glob("*.yml")) + sorted(WORKFLOWS.glob("*.yaml"))
for path in paths:
    failures += problems(path.name, yaml.safe_load(path.read_text(encoding="utf-8")))

negative = {
    "missing": {"jobs": {"a": {"runs-on": "ubuntu-24.04", "steps": [{"run": "true"}]}}},
    "zero": {"jobs": {"a": {"runs-on": "ubuntu-24.04", "timeout-minutes": 0, "steps": []}}},
    "too long": {"jobs": {"a": {"runs-on": "ubuntu-24.04", "timeout-minutes": 360, "steps": []}}},
    "expression": {"jobs": {"a": {"runs-on": "ubuntu-24.04", "timeout-minutes": "${{ inputs.t }}", "steps": []}}},
}
for case, workflow in negative.items():
    if not problems(case, workflow):
        failures.append(f"self-test: the '{case}' copy should fail")
if problems("reusable call", {"jobs": {"a": {"uses": "./.github/workflows/x.yml"}}}):
    failures.append("self-test: a job that calls a reusable workflow must pass without timeout-minutes")

if failures:
    print(f"✖ {len(failures)} job timeout problem(s):", file=sys.stderr)
    for failure in failures:
        print(f"  - {failure}", file=sys.stderr)
    sys.exit(1)

print(f"✓ Job timeouts: every step-running job in {len(paths)} workflows sets timeout-minutes (1-{MAX_MINUTES}).")

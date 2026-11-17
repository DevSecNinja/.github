#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.9"
# dependencies = ["pyyaml==6.0.3"]
# ///
"""Every reusable-workflow job that runs a script from scripts/ fetches it first.

The reusable workflows run in the caller's checkout, so their scripts (#537)
come from the DevSecNinja/.github commit the caller pinned. A job whose run
steps call "${RUNNER_TEMP}/devsecninja-<kind>/<path>" must start with these two
steps (only harden-runner and the App-key preflights that
tests/app-key-confinement.py pins may run before them, since that test lets no
other step run before a preflight):

1. an actions/checkout step, pinned to a full SHA, of job.workflow_repository at
   job.workflow_sha into .devsecninja-<kind>, without persisted credentials,
   whose sparse checkout includes <path>;
2. `mv .devsecninja-<kind> "${RUNNER_TEMP}/devsecninja-<kind>"`, so the code
   checkout doesn't delete the scripts and the caller's linters don't scan them.

When the fetch steps are conditional, every step that runs a script must carry
the same condition, so a script never runs without having been fetched. Every
script must exist in this repository, including the ones that workflows running
in this repository (apm-materialize.yml) call from their own checkout.
"""

from __future__ import annotations

import importlib.util
import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
WORKFLOWS = ROOT / ".github" / "workflows"
SCRIPT_REF = re.compile(r"\$\{RUNNER_TEMP\}/devsecninja-([\w-]+)/([^\"\s]+)")
LOCAL_SCRIPT_REF = re.compile(r"^bash ((?:scripts|config-sync)/[\w./-]+\.sh)$")
CHECKOUT = re.compile(r"^actions/checkout@[0-9a-f]{40}$")
HARDEN_RUNNER = re.compile(r"^DevSecNinja/\.github/actions/harden-runner@[0-9a-f]{40}$")
# Workflows that must keep fetching scripts, so the test cannot pass vacuously.
EXPECTED = {
    "apm-sync.yml",
    "autofix.yml",
    "config-sync.yml",
    "label-sync.yml",
    "lint.yml",
    "pages.yml",
    "vendored-file-sync.yml",
}


def key_preflights() -> set:
    """(workflow, job id, step name) of the App-key preflights app-key-confinement.py pins."""
    sys.dont_write_bytecode = True  # no __pycache__ in tests/
    spec = importlib.util.spec_from_file_location("app_key_confinement", ROOT / "tests" / "app-key-confinement.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return {(Path(workflow).name, job, step) for workflow, job, step, _ in module.EMPTINESS_CHECKS}


PREFLIGHTS = key_preflights()


def preamble(file: str, job_id: str, step: dict) -> bool:
    """Whether `step` may run before the fetch steps."""
    if HARDEN_RUNNER.match(str(step.get("uses") or "")):
        return not set(step) - {"name", "uses", "with"}
    return (file, job_id, step.get("name")) in PREFLIGHTS


def check_job(file: str, job_id: str, job: dict) -> tuple[list[str], int]:
    name = f"{file} job {job_id}"
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
    start = 0
    while start < len(steps) and preamble(file, job_id, steps[start]):
        start += 1
    if len(steps) - start < 2:
        return [f"{name}: runs scripts but has no fetch steps"], 0
    fetch, move = steps[start], steps[start + 1]
    errors = []
    expected_with = {
        "repository": "${{ job.workflow_repository }}",
        "ref": "${{ job.workflow_sha }}",
        "path": f".devsecninja-{kind}",
        "sparse-checkout-cone-mode": False,
        "persist-credentials": False,
    }
    if not CHECKOUT.match(str(fetch.get("uses") or "")):
        errors.append(f"{name}: the first step (after harden-runner and App-key preflights) must be "
                      f"actions/checkout pinned to a full SHA")
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
        if steps.index(step) <= start + 1:
            errors.append(f"{label} runs before its script is fetched")
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
            job_errors, count = check_job(file.name, job_id, job)
            errors += job_errors
            if count:
                fetching[file.name] = fetching.get(file.name, 0) + count
            for step in job.get("steps") or []:
                local = LOCAL_SCRIPT_REF.match(str(step.get("run") or "").strip())
                if local and not (ROOT / local.group(1)).is_file():
                    errors.append(f"{file.name} job {job_id}: step {step.get('name')!r} runs {local.group(1)}, "
                                  f"which does not exist")
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

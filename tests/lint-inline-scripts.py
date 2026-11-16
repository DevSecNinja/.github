#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.9"
# dependencies = ["pyyaml==6.0.3"]
# ///
"""Tests for scripts/lint-inline-scripts.py (#537).

Every case in tests/fixtures/lint-inline-scripts-cases.yml is written into a
temporary repository and checked. The case passes when the annotations match
`expect` one to one and in order, the opt-out count matches `opt-outs`, and the
exit code is 1 only for a blocking run with findings. A final blocking run
checks this repository itself, which must have no inline scripts; its only
opt-outs are the App-key preflights that tests/app-key-confinement.py pins.
"""

from __future__ import annotations

import importlib.util
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
CHECKER = ROOT / "scripts" / "lint-inline-scripts.py"
CASES = ROOT / "tests" / "fixtures" / "lint-inline-scripts-cases.yml"
SUMMARY = re.compile(r"; (\d+) to move into a script, (\d+) opted out\.$", re.MULTILINE)
# A row of the opt-out table in the step summary: file, job (empty for a
# composite action) and step.
OPT_OUT = re.compile(r"^\| (\S+):\d+ \| (?:job '([^']+)'|[Cc]omposite action), step '([^']+)' \|", re.MULTILINE)


def key_preflights() -> set:
    """(workflow, job id, step name) of the App-key preflights app-key-confinement.py pins."""
    sys.dont_write_bytecode = True  # no __pycache__ in tests/
    spec = importlib.util.spec_from_file_location("app_key_confinement", ROOT / "tests" / "app-key-confinement.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return {(workflow, job, step) for workflow, job, step, _ in module.EMPTINESS_CHECKS}


def run(args: list[str], cwd: Path, summary: Path) -> subprocess.CompletedProcess[str]:
    env = {k: v for k, v in os.environ.items() if k != "LINT_INLINE_SCRIPTS_BLOCKING"}
    env["GITHUB_STEP_SUMMARY"] = str(summary)
    return subprocess.run(
        [sys.executable, str(CHECKER), *args],
        cwd=cwd,
        env=env,
        capture_output=True,
        text=True,
        encoding="utf-8",
        check=False,
    )


def check_case(case: dict) -> list[str]:
    errors = []
    with tempfile.TemporaryDirectory() as tmp:
        repo = Path(tmp) / "repo"
        for name, content in case["files"].items():
            path = repo / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content + "\n", encoding="utf-8")
        summary = Path(tmp) / "summary.md"
        result = run(["--blocking"] if case.get("blocking") else [], repo, summary)
        annotations = [line for line in result.stdout.splitlines() if line.startswith("::")]
        expect = case["expect"]
        if len(annotations) != len(expect):
            errors.append(f"expected {len(expect)} annotation(s), got {len(annotations)}")
        for wanted, got in zip(expect, annotations):
            if wanted not in got:
                errors.append(f"expected {wanted!r} in {got!r}")
        level = "::error " if case.get("blocking") else "::warning "
        errors += [f"expected level {level.strip()} in {got!r}" for got in annotations if not got.startswith(level)]
        counts = SUMMARY.search(result.stdout)
        if not counts:
            errors.append("missing the summary line")
        elif int(counts.group(2)) != case.get("opt-outs", 0):
            errors.append(f"expected {case.get('opt-outs', 0)} opt-out(s), got {counts.group(2)}")
        code = 1 if case.get("blocking") and expect else 0
        if result.returncode != code:
            errors.append(f"expected exit code {code}, got {result.returncode}")
        if (expect or case.get("opt-outs")) and not summary.is_file():
            errors.append("no step summary was written")
        if errors:
            errors.append(f"output:\n{result.stdout}{result.stderr}")
    return errors


def main() -> int:
    cases = yaml.safe_load(CASES.read_text(encoding="utf-8"))
    failed = 0
    for case in cases:
        errors = check_case(case)
        if errors:
            failed += 1
            print(f"✗ {case['name']}")
            for error in errors:
                print(f"    {error}")
    with tempfile.TemporaryDirectory() as tmp:
        summary = Path(tmp) / "summary.md"
        result = run(["--blocking", str(ROOT)], ROOT, summary)
        rows = OPT_OUT.findall(summary.read_text(encoding="utf-8")) if summary.is_file() else []
    counts = SUMMARY.search(result.stdout)
    if result.returncode != 0 or not counts:
        failed += 1
        print(f"✗ this repository must have no inline scripts:\n{result.stdout}{result.stderr}")
    opt_outs = set(rows)
    preflights = key_preflights()
    if counts and int(counts.group(2)) != len(rows):
        failed += 1
        print(f"✗ {counts.group(2)} opt-out(s) reported, but {len(rows)} parsed from the step summary")
    if opt_outs != preflights:
        failed += 1
        print(f"✗ only the App-key preflights may opt out: unexpected {sorted(opt_outs - preflights)}, "
              f"missing {sorted(preflights - opt_outs)}")
    if failed:
        print(f"{failed} lint-inline-scripts case(s) failed.")
        return 1
    print(
        f"✓ lint-inline-scripts: {len(cases)} cases pass, and this repository has no inline scripts "
        f"apart from {len(preflights)} App-key preflight(s)."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())

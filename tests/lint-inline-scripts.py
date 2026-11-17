#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.9"
# dependencies = ["pyyaml==6.0.3"]
# ///
"""Tests for scripts/lint-inline-scripts.py (#537).

Every case in tests/fixtures/lint-inline-scripts-cases.yml is written into a
temporary repository and checked. The case passes when the annotations match
`expect` one to one and in order, the opt-out count matches `opt-outs`, and the
exit code is 1 only for a blocking run with findings. A final run checks this
repository itself, which must parse cleanly in warning mode, and the files in
CLEAN, whose inline scripts have moved into scripts/, must pass a blocking run.
"""

from __future__ import annotations

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
# Files of this repository without inline scripts; each layer of #537 adds the
# ones it cleans up, until the whole repository passes.
CLEAN = [".github/workflows/lint.yml"]
SUMMARY = re.compile(r"; (\d+) to move into a script, (\d+) opted out\.$", re.MULTILINE)


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
        result = run([str(ROOT)], ROOT, Path(tmp) / "summary.md")
    if result.returncode != 0 or "Could not parse" in result.stdout or not SUMMARY.search(result.stdout):
        failed += 1
        print(f"✗ this repository must parse cleanly in warning mode:\n{result.stdout}{result.stderr}")
    with tempfile.TemporaryDirectory() as tmp:
        result = run(["--blocking", *(str(ROOT / path) for path in CLEAN)], ROOT, Path(tmp) / "summary.md")
    if result.returncode != 0:
        failed += 1
        print(f"✗ {', '.join(CLEAN)} must have no inline scripts:\n{result.stdout}{result.stderr}")
    if failed:
        print(f"{failed} lint-inline-scripts case(s) failed.")
        return 1
    print(
        f"✓ lint-inline-scripts: {len(cases)} cases pass, this repository parses in warning mode, "
        f"and {len(CLEAN)} file(s) have no inline scripts."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())

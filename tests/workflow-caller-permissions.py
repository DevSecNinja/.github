# /// script
# requires-python = ">=3.9"
# dependencies = ["pyyaml==6.0.3"]
# ///
"""Every caller grants the permissions the reusable workflow it calls requests.

GitHub refuses to start a run whose reusable workflow requests more than its
calling job grants: the whole run ends in `startup_failure` ("The workflow is
requesting 'contents: read', but is only allowed 'contents: none'"), before
any job or step, so no lint, test or log of the workflow itself shows it. The
reusable workflow's top-level `permissions` count as requested even when each
of its jobs sets its own.

For each job in .github/workflows/ that calls a reusable workflow of this
repository by local reference (`./.github/workflows/x.yml` or
`$/.github/workflows/x.yml`, which run at the same commit), this compares what
the job grants (its `permissions`, else the workflow's) with the most the
called workflow requests (its top-level `permissions` and every job's). A
caller that sets no permissions anywhere gets the repository's default token
and is skipped. Calls pinned to another revision
(`DevSecNinja/.github/.github/workflows/x.yml@<ref>`) are left out: this
checkout may not match what they run.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
WORKFLOWS = ROOT / ".github" / "workflows"
USES = re.compile(r"^(?:\./|\$/)\.github/workflows/([\w.-]+\.ya?ml)$")
LEVELS = {"none": 0, "read": 1, "write": 2}
NAMES = {level: name for name, level in LEVELS.items()}
# The level a `read-all`/`write-all` grants every scope not listed, so new scopes need no list here.
ANY = "*"
# Callers that must keep being checked, so the test cannot pass vacuously.
EXPECTED = {"ci-failure-issue-caller.yml", "lint-caller.yml", "renovate-pr-cooldown-caller.yml"}


def levels(value) -> dict[str, int]:
    """A `permissions` value as scope -> level; ANY holds the level of unlisted scopes (none for a mapping)."""
    if value == "read-all":
        return {ANY: LEVELS["read"], "id-token": LEVELS["none"]}  # id-token has no read level
    if value == "write-all":
        return {ANY: LEVELS["write"]}
    if not isinstance(value, dict):
        raise TypeError(f"unexpected permissions value {value!r}")
    return {scope: LEVELS[str(level)] for scope, level in value.items()}


def grant(block: dict[str, int], scope: str) -> int:
    return block.get(scope, block.get(ANY, 0))


def load(path: Path) -> dict:
    return yaml.safe_load(path.read_text(encoding="utf-8")) or {}


def requested(doc: dict) -> dict[str, int]:
    """The most the reusable workflow asks for, top level and per job (ANY: what every other scope needs)."""
    blocks = [levels(doc["permissions"])] if "permissions" in doc else []
    blocks += [
        levels(job["permissions"])
        for job in (doc.get("jobs") or {}).values()
        if isinstance(job, dict) and "permissions" in job
    ]
    scopes = {scope for block in blocks for scope in block}
    return {scope: max(grant(block, scope) for block in blocks) for scope in scopes}


def main() -> int:
    errors: list[str] = []
    checked: set[str] = set()
    for file in sorted(WORKFLOWS.glob("*.y*ml")):
        doc = load(file)
        for job_id, job in (doc.get("jobs") or {}).items():
            match = USES.match(str(job.get("uses") or "")) if isinstance(job, dict) else None
            if not match:
                continue
            target = WORKFLOWS / match.group(1)
            if not target.is_file():
                errors.append(f"{file.name} job {job_id}: calls {match.group(1)}, which does not exist")
                continue
            if "permissions" in job:
                granted = levels(job["permissions"])
            elif "permissions" in doc:
                granted = levels(doc["permissions"])
            else:
                continue  # the repository's default token
            checked.add(file.name)
            for scope, level in sorted(requested(load(target)).items()):
                have = grant(granted, scope)
                if have < level:
                    what = "every scope" if scope == ANY else f"'{scope}"
                    errors.append(
                        f"{file.name} job {job_id}: {target.name} requests {what}: {NAMES[level]}', but the "
                        f"job grants {what}: {NAMES[have]}' (the run would end in startup_failure)"
                    )
    for name in sorted(EXPECTED - checked):
        errors.append(f"{name}: expected a caller with permissions to check, found none")
    if errors:
        print(f"✖ {len(errors)} caller permission problem(s):", file=sys.stderr)
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
        return 1
    print(f"✓ Caller permissions: {len(checked)} workflows grant what the reusable workflows they call request.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

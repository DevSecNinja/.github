#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.9"
# dependencies = ["pyyaml==6.0.3"]
# ///
"""The pr-cooldown clock starts when a PR began proposing its current change.

Runs the github-script of .github/workflows/renovate-pr-cooldown.yml under Node
against a mocked GitHub client. A rebase, retitle or autoclose/reopen that keeps
the head commit's changed lines must not restart the 14-day clock; a new version
must, and anything the script cannot compare falls back to the head commit date.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
WORKFLOW = ROOT / ".github" / "workflows" / "renovate-pr-cooldown.yml"
GATED = "renovate/docker-gated-ghcr.io-example-app-1.x"
OLD = "@@ -1 +1 @@\n-image: ghcr.io/example/app:1.0.0\n+image: ghcr.io/example/app:1.1.0"
NEW = "@@ -1 +1 @@\n-image: ghcr.io/example/app:1.0.0\n+image: ghcr.io/example/app:1.2.0"
# A rebase onto a moved base: other context and hunk offsets, same change.
REBASED = "@@ -3 +3 @@ services:\n-image: ghcr.io/example/app:1.0.0\n+image: ghcr.io/example/app:1.1.0"


def commit(sha: str, days_ago: float, patch: str | None = OLD, parents: int = 1) -> dict:
    file = {"filename": "apps/app/compose.yaml", "status": "modified"}
    if patch is not None:
        file["patch"] = patch
    return {"sha": sha, "days_ago": days_ago, "parents": parents, "files": [file]}


def push(before: str, after: str) -> dict:
    return {"beforeCommit": {"oid": before}, "afterCommit": {"oid": after}}


# name, PR author, branch, commits (oldest first, head last), force pushes, commit count, expected state
CASES = [
    (
        "same-version rebase keeps the clock",
        "renovate[bot]",
        GATED,
        [commit("c1", 20), commit("c2", 5, REBASED)],
        [push("c1", "c2")],
        1,
        "success",
    ),
    (
        "retitle, autoclose and reopen keep the clock",
        "renovate[bot]",
        GATED,
        [commit("c1", 16), commit("c2", 9), commit("c3", 9), commit("c4", 1)],
        [push("c1", "c2"), push("c2", "c3"), push("c3", "c4")],
        1,
        "success",
    ),
    (
        "new version restarts the clock",
        "renovate[bot]",
        GATED,
        [commit("c1", 30), commit("c2", 5, NEW)],
        [push("c1", "c2")],
        1,
        "pending",
    ),
    (
        "rebase after a new version counts from the new version",
        "renovate[bot]",
        GATED,
        [commit("c1", 30), commit("c2", 10, NEW), commit("c3", 1, NEW)],
        [push("c1", "c2"), push("c2", "c3")],
        1,
        "pending",
    ),
    ("never pushed again", "renovate[bot]", GATED, [commit("c1", 15)], [], 1, "success"),
    ("unsoaked first commit", "renovate[bot]", GATED, [commit("c1", 3)], [], 1, "pending"),
    (
        "extra commits fall back to the head date",
        "renovate[bot]",
        GATED,
        [commit("c1", 20), commit("c2", 5)],
        [push("c1", "c2")],
        2,
        "pending",
    ),
    (
        "head not from the last force push falls back",
        "renovate[bot]",
        GATED,
        [commit("c1", 20), commit("c2", 5)],
        [push("c1", "cX")],
        1,
        "pending",
    ),
    (
        "missing patch falls back",
        "renovate[bot]",
        GATED,
        [commit("c1", 20, None), commit("c2", 5, None)],
        [push("c1", "c2")],
        1,
        "pending",
    ),
    (
        "merge commit falls back",
        "renovate[bot]",
        GATED,
        [commit("c1", 20), commit("c2", 5, OLD, 2)],
        [push("c1", "c2")],
        1,
        "pending",
    ),
    (
        "unreachable earlier commit falls back",
        "renovate[bot]",
        GATED,
        [commit("c2", 5)],
        [push("c1", "c2")],
        1,
        "pending",
    ),
    ("human PR is not gated", "someone", GATED, [commit("c1", 0)], [], 1, "success"),
    ("non-gated Renovate branch", "renovate[bot]", "renovate/all-non-major", [commit("c1", 0)], [], 1, "success"),
]

HARNESS = r"""
const fs = require('fs');
const script = fs.readFileSync(process.argv[2], 'utf8');
const fixture = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
const dayMs = 24 * 60 * 60 * 1000;
const commits = Object.fromEntries(fixture.commits.map((c) => [c.sha, {
  sha: c.sha,
  parents: Array.from({ length: c.parents }, (_, i) => ({ sha: `p${i}` })),
  files: c.files,
  commit: { committer: { date: new Date(Date.now() - c.days_ago * dayMs).toISOString() } },
}]));
const head = fixture.commits[fixture.commits.length - 1].sha;
const statuses = [];
const github = {
  rest: {
    repos: {
      getCommit: async ({ ref }) => {
        if (!commits[ref]) throw new Error(`No commit found for SHA: ${ref}`);
        return { data: commits[ref] };
      },
      createCommitStatus: async (s) => statuses.push(s),
    },
    pulls: { list: () => { throw new Error('not used'); } },
  },
  paginate: () => { throw new Error('not used'); },
  graphql: async () => ({ repository: { pullRequest: {
    commits: { totalCount: fixture.count },
    timelineItems: { nodes: fixture.pushes },
  } } }),
};
const context = {
  eventName: 'pull_request',
  repo: { owner: 'DevSecNinja', repo: 'example' },
  payload: { pull_request: {
    number: 1, head: { sha: head, ref: fixture.branch }, user: { login: fixture.author },
  } },
};
const core = { info: () => {}, warning: () => {} };
const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor;
new AsyncFunction('github', 'context', 'core', script)(github, context, core)
  .then(() => console.log(JSON.stringify(statuses)))
  .catch((error) => { console.error(error); process.exit(1); });
"""


def main() -> int:
    node = shutil.which("node")
    if not node:
        print("✖ node is required to run the pr-cooldown script", file=sys.stderr)
        return 1
    doc = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    (step,) = [s for s in doc["jobs"]["cooldown"]["steps"] if "github-script" in str(s.get("uses"))]
    env = {
        "PATH": str(Path(node).parent),
        "COOLDOWN_DAYS": "14",
        "GATED_PREFIXES": "renovate/docker-gated-",
        "BOT_LOGIN": "renovate[bot]",
        "STATUS_CONTEXT": "pr-cooldown",
    }
    errors = []
    with tempfile.TemporaryDirectory() as tmp:
        harness, script, fixture_file = (Path(tmp) / n for n in ("harness.js", "script.js", "fixture.json"))
        harness.write_text(HARNESS, encoding="utf-8")
        script.write_text(step["with"]["script"], encoding="utf-8")
        for name, author, branch, commits, pushes, count, expected in CASES:
            fixture = {"author": author, "branch": branch, "commits": commits, "pushes": pushes, "count": count}
            fixture_file.write_text(json.dumps(fixture), encoding="utf-8")
            result = subprocess.run(
                [node, str(harness), str(script), str(fixture_file)],
                env=env,
                capture_output=True,
                text=True,
                encoding="utf-8",
                check=False,
            )
            if result.returncode != 0:
                errors.append(f"{name}: script failed: {result.stderr.strip()}")
                continue
            states = [s["state"] for s in json.loads(result.stdout)]
            if states != [expected]:
                errors.append(f"{name}: expected status {expected!r}, got {states}")
    if errors:
        print(f"✖ {len(errors)} pr-cooldown case(s) failed:", file=sys.stderr)
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
        return 1
    print(f"✓ pr-cooldown: {len(CASES)} soak-clock cases pass.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

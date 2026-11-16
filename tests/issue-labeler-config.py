#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.9"
# dependencies = ["pyyaml==6.0.3"]
# ///
"""Check the issue-labeler config that config-sync distributes.

config-sync/files/issue-labeler.yaml is read by github/issue-labeler v3 (pinned
in .github/workflows/labeler.yml). For each label, that action:

- turns an entry written as '/pattern/flags' into `new RegExp(pattern, flags)`
  and passes any other entry to `String.prototype.match`, which builds a
  RegExp from it. JavaScript rejects inline flags such as '(?i)', and the
  resulting SyntaxError aborts the whole run;
- requires every entry under a label to match (AND).

This test checks that each label has exactly one entry, that every pattern is
a valid JavaScript RegExp (compiled with node when it is on PATH, and checked
for inline flag groups either way), and that sample issues get the expected
labels. The title and body are matched as "<title>\\n\\n<body>", as the
workflow passes include-title: 1.
"""

from __future__ import annotations

import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
CONFIG = REPO_ROOT / "config-sync" / "files" / "issue-labeler.yaml"

# github/issue-labeler: `regEx.match(/^\/(.+)\/(.*)$/)`
WRAPPED = re.compile(r"^/(.+)/(.*)$", re.DOTALL)
JS_FLAGS = set("dgimsuvy")
# Inline flags '(?i)' and modifier groups '(?i:...)' / '(?-i:...)'.
INLINE_FLAG_GROUP = re.compile(r"\(\?[a-zA-Z-]+[):]")
PY_FLAGS = {"i": re.IGNORECASE, "m": re.MULTILINE, "s": re.DOTALL}

# (title, body, expected labels)
CASES = [
    ("feat(api): add CSV export", "", {"feat"}),
    ("feat!: drop the v1 API", "", {"feat"}),
    ("Feature request: dark mode", "", {"feat"}),
    ("Pull request template is outdated", "", set()),
    ("fix!: handle empty input", "", {"fix"}),
    ("Build failed on main", "", {"fix"}),
    ("feat: add failover support", "", {"feat"}),
    ("feat: add Crashlytics and Bugsnag integrations", "", {"feat"}),
    ("Login is not working", "", {"fix"}),
    ("App crashes on start", "", {"fix", "area/apps"}),
    ("Login page", "What happened?\nThe button is broken.", {"fix"}),
    ("Debug logging is noisy", "", set()),
    ("perf: faster startup", "", {"perf"}),
    ("refactor: split the parser", "", {"refactor"}),
    ("chore(deps): bump a tool", "", {"chore"}),
    ("Update the README", "", {"docs"}),
    ("Docker image is missing", "", {"area/apps"}),
    ("Happy path approach", "", set()),
    (
        "Workflow fails on a specific runner",
        "",
        {"ci", "fix", "area/github"},
    ),
    (
        "Bump dependencies in .github workflows",
        "",
        {"area/renovate", "ci", "area/github"},
    ),
    ("How do I configure renovate?", "", {"question", "area/renovate"}),
    ("Add a cron job script", "", {"area/scripts"}),
    ("PowerShell profile loads slowly", "", set()),
]


def fail(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    sys.exit(1)


def load_rules() -> dict[str, tuple[str, str]]:
    config = yaml.safe_load(CONFIG.read_text(encoding="utf-8"))
    if not isinstance(config, dict) or not config:
        fail(f"{CONFIG} must map labels to patterns")

    rules: dict[str, tuple[str, str]] = {}
    for label, entries in config.items():
        if isinstance(entries, str):
            entries = [entries]
        if not isinstance(entries, list) or len(entries) != 1:
            fail(
                f"label {label!r} must have exactly one pattern: "
                "github/issue-labeler ANDs the entries under a label"
            )
        entry = entries[0]
        if not isinstance(entry, str):
            fail(f"label {label!r}: pattern must be a string")
        wrapped = WRAPPED.match(entry)
        pattern, flags = (wrapped.group(1), wrapped.group(2)) if wrapped else (entry, "")
        if not set(flags) <= JS_FLAGS:
            fail(f"label {label!r}: unsupported RegExp flags {flags!r}")
        if INLINE_FLAG_GROUP.search(pattern):
            fail(
                f"label {label!r}: inline flags are invalid in JavaScript; "
                f"use '/pattern/i' instead of {entry!r}"
            )
        rules[label] = (pattern, flags)
    return rules


def check_with_node(rules: dict[str, tuple[str, str]]) -> None:
    node = shutil.which("node")
    if node is None:
        print("note: node not found; skipping the JavaScript RegExp compile check")
        return
    script = (
        "const rules = JSON.parse(require('fs').readFileSync(0, 'utf8'));"
        "let bad = 0;"
        "for (const [label, [p, f]] of Object.entries(rules)) {"
        "  try { new RegExp(p, f); }"
        "  catch (e) { console.error(`${label}: ${e.message}`); bad = 1; }"
        "}"
        "process.exit(bad);"
    )
    result = subprocess.run(
        [node, "-e", script],
        input=json.dumps(rules),
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        fail(f"invalid JavaScript RegExp:\n{result.stderr.strip()}")


def labels_for(rules: dict[str, tuple[str, str]], title: str, body: str) -> set[str]:
    content = f"{title}\n\n{body}"
    applied = set()
    for label, (pattern, flags) in rules.items():
        py_flags = 0
        for flag in flags:
            py_flags |= PY_FLAGS.get(flag, 0)
        if re.search(pattern, content, py_flags):
            applied.add(label)
    return applied


def main() -> None:
    rules = load_rules()
    check_with_node(rules)

    failures = []
    for title, body, expected in CASES:
        got = labels_for(rules, title, body)
        if got != expected:
            failures.append(f"{title!r}: expected {sorted(expected)}, got {sorted(got)}")
    if failures:
        fail("unexpected issue labels:\n  " + "\n  ".join(failures))

    print(f"ok: {len(rules)} issue-labeler rules, {len(CASES)} sample issues")


if __name__ == "__main__":
    main()

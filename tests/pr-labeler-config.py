#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.9"
# dependencies = ["pyyaml==6.0.3"]
# ///
"""Check the PR labeler config that config-sync distributes.

config-sync/files/pr-labeler.yaml is read by actions/labeler v7 (pinned in
.github/workflows/labeler.yml) in every repository that calls the reusable
labeler, whatever its layout. This test runs changed-file lists from the
fleet's layouts (src/, services/, apps/ + crates/, backend/ + frontend/,
home/) through the rules and checks the labels. area/apps is an allowlist of
source directories, so docs, Markdown, config, CI and infrastructure files must
not get it.

It mirrors actions/labeler v7: top-level `changed-files` entries of a label are
alternatives, each operator (`any-glob-to-any-file`, `all-globs-to-any-file`,
...) is evaluated per Minimatch with `dot: true`, and a leading `!` negates a
glob. Globs are limited to the Minimatch subset this test implements: `*`,
`**`, single-level `{a,b}` braces and a leading `!`.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
CONFIG = REPO_ROOT / "config-sync" / "files" / "pr-labeler.yaml"

OPERATORS = {
    "any-glob-to-any-file",
    "any-glob-to-all-files",
    "all-globs-to-any-file",
    "all-globs-to-all-files",
}
SUPPORTED_GLOB = re.compile(r"^!?[A-Za-z0-9_.\-/*{},]+$")
BRACE = re.compile(r"\{([^{}]*)\}")

# (changed files, expected labels)
CASES = [
    # aliasaurus: app under src/functions/, no services/ (DevSecNinja/.github#507)
    (["src/functions/alias.ts"], {"area/apps"}),
    # truenas-apps
    (["services/plex/compose.yaml"], {"area/apps"}),
    # note-iq
    (["apps/web/main.ts", "crates/core/src/lib.rs"], {"area/apps"}),
    # hadiscover
    (["backend/app.py", "frontend/src/App.tsx"], {"area/apps"}),
    # dotfiles: home/ holds dotfiles, not application code
    (["home/dot_bashrc.tmpl"], set()),
    (["src/README.md"], {"area/docs"}),
    (["docs/guide.md", "docs/img/flow.png"], {"area/docs"}),
    (["README.md"], {"area/docs"}),
    # release-please PR
    (["CHANGELOG.md", ".release-please-manifest.json"], set()),
    ([".github/workflows/ci.yml"], {"area/github"}),
    ([".github/instructions/style.instructions.md"], {"area/github", "area/docs"}),
    (["renovate.json5"], {"area/renovate"}),
    ([".github/renovate.json5"], {"area/renovate", "area/github"}),
    (["scripts/setup.sh"], {"area/scripts"}),
    (["script/bootstrap"], {"area/scripts"}),
    ([".devcontainer/post-create.sh"], {"area/scripts"}),
    (["src/build.sh"], {"area/scripts"}),
    (["tests/test_parser.py", "specs/001-feature/spec.md"], {"area/docs"}),
    ([".mise.toml", "pr-labeler.yaml", "LICENSE"], set()),
    # Excluded areas count at any depth
    (["crates/core/tests/parser.rs"], set()),
    (["apps/web/docs/flow.svg"], {"area/docs"}),
    (["src/.cache/index.json"], set()),
    (["src/scripts/seed.py"], {"area/scripts"}),
    (["src/__tests__/app.test.ts"], set()),
    # Only source code gets area/apps: not docs, config, CI or infrastructure
    (["src/docs/guide.txt", "apps/web/README.md"], {"area/docs"}),
    (["infra/main.bicep", "config/settings.yaml", "public/index.html"], set()),
    (["tools/gen/main.go", "Dockerfile", "package.json"], set()),
    ([".github/workflows/ci.yml", ".devcontainer/devcontainer.json"], {"area/github"}),
    (["src/config/appsettings.json"], {"area/apps"}),
    (["docs/guide.md", "src/app.ts"], {"area/docs", "area/apps"}),
]


def fail(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    sys.exit(1)


def expand_braces(glob: str) -> list[str]:
    match = BRACE.search(glob)
    if not match:
        return [glob]
    head, tail = glob[: match.start()], glob[match.end() :]
    return [expanded for option in match.group(1).split(",") for expanded in expand_braces(head + option + tail)]


def segment_regex(segment: str) -> str:
    return "".join("[^/]*" if char == "*" else re.escape(char) for char in segment)


def glob_regex(glob: str) -> re.Pattern[str]:
    segments = glob.split("/")
    parts = []
    for index, segment in enumerate(segments):
        last = index == len(segments) - 1
        if segment == "**":
            parts.append(".*" if last else "(?:[^/]+/)*")
        else:
            parts.append(segment_regex(segment) + ("" if last else "/"))
    return re.compile("".join(parts))


class Matcher:
    def __init__(self, glob: str) -> None:
        self.negate = glob.startswith("!")
        body = glob[1:] if self.negate else glob
        self.regexes = [glob_regex(g) for g in expand_braces(body)]

    def match(self, path: str) -> bool:
        hit = any(regex.fullmatch(path) for regex in self.regexes)
        return hit != self.negate


def check_operator(operator: str, globs: list[str], files: list[str]) -> bool:
    matchers = [Matcher(glob) for glob in globs]
    if operator == "any-glob-to-any-file":
        return any(m.match(f) for m in matchers for f in files)
    if operator == "any-glob-to-all-files":
        return any(all(m.match(f) for f in files) for m in matchers)
    if operator == "all-globs-to-any-file":
        return any(all(m.match(f) for m in matchers) for f in files)
    return all(all(m.match(f) for m in matchers) for f in files)


def load_rules() -> dict[str, list[tuple[str, list[str]]]]:
    config = yaml.safe_load(CONFIG.read_text(encoding="utf-8"))
    if not isinstance(config, dict) or not config:
        fail(f"{CONFIG} must map labels to match configs")

    rules: dict[str, list[tuple[str, list[str]]]] = {}
    for label, configs in config.items():
        if not isinstance(configs, list):
            fail(f"label {label!r}: expected a list of match configs")
        alternatives = []
        for entry in configs:
            if not isinstance(entry, dict) or set(entry) != {"changed-files"}:
                fail(f"label {label!r}: only top-level `changed-files` entries are tested")
            for item in entry["changed-files"]:
                if not isinstance(item, dict) or len(item) != 1:
                    fail(f"label {label!r}: each `changed-files` item needs one operator")
                ((operator, globs),) = item.items()
                if operator not in OPERATORS:
                    fail(f"label {label!r}: unknown operator {operator!r}")
                globs = globs if isinstance(globs, list) else [globs]
                for glob in globs:
                    if not isinstance(glob, str) or not SUPPORTED_GLOB.match(glob):
                        fail(f"label {label!r}: glob {glob!r} is outside the tested subset")
                alternatives.append((operator, globs))
        rules[label] = alternatives
    return rules


def labels_for(rules: dict[str, list[tuple[str, list[str]]]], files: list[str]) -> set[str]:
    return {
        label
        for label, alternatives in rules.items()
        if any(check_operator(op, globs, files) for op, globs in alternatives)
    }


def main() -> None:
    rules = load_rules()
    failures = []
    for files, expected in CASES:
        got = labels_for(rules, files)
        if got != expected:
            failures.append(f"{files}: expected {sorted(expected)}, got {sorted(got)}")
    if failures:
        fail("unexpected PR labels:\n  " + "\n  ".join(failures))

    print(f"ok: {len(rules)} pr-labeler rules, {len(CASES)} sample PRs")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Summarize JUnit XML test results on the GitHub Actions run page.

Reads the JUnit XML files that match one or more glob patterns and writes a
job summary (totals per suite and a table of failing tests), `::error`
annotations for failures, and `total`/`passed`/`failed`/`skipped` step
outputs. Standard library only, Python 3.8+. It only reports: failing tests do
not change the exit code, because the test step itself already fails the job.
"""

from __future__ import annotations

import argparse
import glob
import os
import re
import secrets
import sys
from pathlib import Path
from xml.etree import ElementTree as ET

MESSAGE_CELL = 200
MESSAGE_ANNOTATION = 1000
MAX_ANNOTATIONS = 10  # GitHub shows at most 10 error annotations per step.
COLLAPSE_SUITES = 10
# bats: "(in test file tests/x.bats, line 12)"
BATS_LOCATION = re.compile(r"in test file (?P<file>.+?), line (?P<line>\d+)")
BATS_NOTE = re.compile(r"^\s*\(in test file [^)]*\)\s*$", re.MULTILINE)
# Python tracebacks: 'File "tests/test_x.py", line 12'
PYTHON_LOCATION = re.compile(r'File "(?P<file>[^"]+)", line (?P<line>\d+)')
# pytest, Pester, jest, go and most others: "tests/test_x.py:12". The path may
# contain spaces, which spaced_paths() tries in turn.
PATH_LOCATION = re.compile(r"(?P<file>[\w./\\:-]*[\w-]\.[A-Za-z0-9]+):(?P<line>\d+)")


class Suite:
    def __init__(self, name: str) -> None:
        self.name = name
        self.passed = 0
        self.failed = 0
        self.skipped = 0
        self.time = 0.0


class Failure:
    def __init__(self, group: str, name: str, message: str, file: str | None, line: str | None) -> None:
        self.group = group
        self.name = name
        self.message = message
        self.file = file
        self.line = line

    @property
    def where(self) -> str:
        return f"{self.file}:{self.line}" if self.line else self.file or ""


def number(value: str | None) -> float:
    try:
        return float((value or "0").replace(",", ""))
    except ValueError:
        return 0.0


def first_line(text: str) -> str:
    return next((line.strip() for line in text.splitlines() if line.strip()), "")


def workspace_file(path: str, workspace: Path) -> str | None:
    """`path` relative to the workspace when it is a file inside it, else None."""
    candidate = Path(path)
    if not candidate.is_absolute():
        candidate = workspace / candidate
    try:
        if candidate.is_file():
            return candidate.resolve().relative_to(workspace.resolve()).as_posix()
    except (ValueError, OSError):
        pass
    return None


def spaced_paths(text: str, match: re.Match) -> list[str]:
    """Paths that end where `match`'s path ends, longest first: the path may
    start after any earlier space on the same line."""
    line_start = text.rfind("\n", 0, match.start("file")) + 1
    before = text[line_start : match.start("file")]
    starts = [0] + [i + 1 for i, char in enumerate(before) if char == " "]
    return [text[line_start + start : match.end("file")] for start in starts] + [match.group("file")]


def location(case: ET.Element, result: ET.Element, workspace: Path) -> tuple[str | None, str | None]:
    """Where a test failed: the testcase's file and line attributes, or else
    the last (deepest) location in the failure text that is a file in the
    workspace, so frames in libraries and the standard library are skipped."""
    attribute = case.get("file")
    if attribute and case.get("line"):
        return workspace_file(attribute, workspace) or attribute, case.get("line")
    text = "\n".join(filter(None, (result.get("message"), result.text)))
    found: tuple[int, str | None, str | None] = (-1, None, None)
    for pattern in (BATS_LOCATION, PYTHON_LOCATION, PATH_LOCATION):
        for match in pattern.finditer(text):
            if match.start() <= found[0]:
                continue
            candidates = spaced_paths(text, match) if pattern is PATH_LOCATION else [match.group("file")]
            path = next(filter(None, (workspace_file(c, workspace) for c in candidates)), None)
            if path:
                found = (match.start(), path, match.group("line"))
    if found[1] or not attribute:
        return found[1], found[2]
    return workspace_file(attribute, workspace) or attribute, None


def parse(path: str, workspace: Path, suites: list[Suite], failures: list[Failure]) -> None:
    root = ET.parse(path).getroot()  # XML written by the caller's own tests
    for element in root.iter("testsuite"):
        cases = element.findall("testcase")
        if not cases:
            continue
        suite = Suite(element.get("name") or Path(path).name)
        for case in cases:
            suite.time += number(case.get("time"))
            result = case.find("failure")
            if result is None:
                result = case.find("error")
            if result is not None:
                suite.failed += 1
                file, line = location(case, result, workspace)
                message = result.get("message") or first_line(BATS_NOTE.sub("", result.text or "")) or result.tag
                group = case.get("classname") or suite.name
                failures.append(Failure(group, case.get("name") or "(unnamed)", message, file, line))
            elif case.find("skipped") is not None:
                suite.skipped += 1
            else:
                suite.passed += 1
        if element.get("time"):
            suite.time = number(element.get("time"))
        suites.append(suite)


def duration(seconds: float) -> str:
    if seconds < 60:
        return f"{seconds:.1f}s"
    minutes, rest = divmod(round(seconds), 60)
    return f"{minutes}m {rest}s"


def truncate(text: str, limit: int) -> str:
    text = " ".join(text.split())
    return text if len(text) <= limit else text[: limit - 1] + "…"


def cell(text: str) -> str:
    text = text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    return text.replace("|", "\\|").replace("\r", " ").replace("\n", " ")


def escape_data(value: str) -> str:
    return value.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def escape_property(value: str) -> str:
    return escape_data(value).replace(":", "%3A").replace(",", "%2C")


def annotate(failure: Failure) -> None:
    props = []
    if failure.file:
        props.append(f"file={escape_property(failure.file)}")
        if failure.line:
            props.append(f"line={escape_property(failure.line)}")
    props.append(f"title={escape_property(f'Test failed: {failure.name}')}")
    message = truncate(f"{failure.group} › {failure.name}: {failure.message}", MESSAGE_ANNOTATION)
    print(f"::error {','.join(props)}::{escape_data(message)}")


def render(title: str, suites: list[Suite], failures: list[Failure], max_failures: int, notes: list[str]) -> str:
    passed = sum(s.passed for s in suites)
    failed = sum(s.failed for s in suites)
    skipped = sum(s.skipped for s in suites)
    total = passed + failed + skipped
    icon = "❌" if failed else "✅" if total else "⚠️"
    out = [
        f"### {icon} {cell(title)}: {passed} passed, {failed} failed, {skipped} skipped",
        "",
        f"{total} test(s) in {len(suites)} suite(s), {duration(sum(s.time for s in suites))}.",
        "",
    ]
    if suites:
        table = ["| Suite | Passed | Failed | Skipped | Time |", "| ----- | -----: | -----: | ------: | ---: |"]
        table += [
            f"| {'❌' if s.failed else '✅'} {cell(s.name)} | {s.passed} | {s.failed} | {s.skipped} | {duration(s.time)} |"
            for s in suites
        ]
        if len(suites) > COLLAPSE_SUITES:
            table = [f"<details><summary>{len(suites)} suites</summary>", "", *table, "", "</details>"]
        out += [*table, ""]
    if failures and max_failures:
        out += ["#### Failed tests", "", "| Test | Location | Message |", "| ---- | -------- | ------- |"]
        for failure in failures[:max_failures]:
            test = f"{cell(failure.group)} › {cell(failure.name)}"
            where = f"`{cell(failure.where)}`" if failure.file else ""
            out.append(f"| {test} | {where} | {cell(truncate(failure.message, MESSAGE_CELL))} |")
        out.append("")
    if len(failures) > max_failures:
        out += [f"{len(failures) - max_failures} more failed test(s) not listed.", ""]
    out += [f"> {note}\n" for note in notes]
    return "\n".join(out) + "\n"


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Summarize JUnit XML test results on the GitHub Actions run page.")
    parser.add_argument("--paths", required=True, help="newline-separated glob patterns of JUnit XML files")
    parser.add_argument("--title", default="Test results")
    parser.add_argument("--max-failures", type=int, default=50, help="rows in the failed-tests table")
    parser.add_argument("--if-no-files", choices=("warn", "error", "ignore"), default="warn")
    parser.add_argument("--workspace", type=Path, default=Path(os.environ.get("GITHUB_WORKSPACE") or "."))
    parser.add_argument("--summary", default=os.environ.get("GITHUB_STEP_SUMMARY"))
    parser.add_argument("--github-output", default=os.environ.get("GITHUB_OUTPUT"))
    args = parser.parse_args(argv)
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")  # cp1252 on Windows runners
    if args.max_failures < 0:
        parser.error("--max-failures must be 0 or more")
    patterns = [line.strip() for line in args.paths.splitlines() if line.strip()]
    if not patterns:
        parser.error("--paths must contain at least one glob pattern")
    files: dict[str, str] = {}
    for pattern in patterns:
        for path in sorted(glob.glob(pattern, recursive=True)):
            if os.path.isfile(path):
                files.setdefault(os.path.realpath(path), path)  # one entry per file, however it matched

    suites: list[Suite] = []
    failures: list[Failure] = []
    notes: list[str] = []
    for path in files.values():
        try:
            parse(path, args.workspace, suites, failures)
        except (ET.ParseError, OSError) as error:
            print(
                f"::warning file={escape_property(path)},title=Test report::Could not parse: {escape_data(str(error))}"
            )
            notes.append(f"⚠️ Could not parse `{cell(path)}`: {cell(str(error))}")
    if not files:
        message = f"No test result files match: {', '.join(patterns)}"
        if args.if_no_files == "ignore":
            print(message)
            return 0
        level = "error" if args.if_no_files == "error" else "warning"
        print(f"::{level} title=Test report::{escape_data(message)}")
        notes.append(f"⚠️ {cell(message)}")

    for failure in failures[:MAX_ANNOTATIONS]:
        annotate(failure)
    text = render(args.title, suites, failures, args.max_failures, notes)
    # Test names come from the XML, so stop the runner from reading workflow
    # commands in this echo of the summary.
    token = secrets.token_hex(16)
    print(f"::stop-commands::{token}\n{text}\n::{token}::")
    if args.summary:
        with open(args.summary, "a", encoding="utf-8") as handle:
            handle.write(text)
    if args.github_output:
        counts = {key: sum(getattr(s, key) for s in suites) for key in ("passed", "failed", "skipped")}
        counts["total"] = sum(counts.values())
        with open(args.github_output, "a", encoding="utf-8") as handle:
            handle.writelines(f"{key}={value}\n" for key, value in counts.items())
    return 1 if not files and args.if_no_files == "error" else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

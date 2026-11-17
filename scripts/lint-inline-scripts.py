#!/usr/bin/env python3
# /// script
# requires-python = ">=3.9"
# dependencies = ["pyyaml==6.0.3"]
# ///
"""Report inline scripts in GitHub Actions `run:` steps (#537).

Code in a `run:` block is out of reach of linters, formatters and tests, so a
`run:` may hold exactly one line with one simple command, such as
`./scripts/build.sh`, `bash .github/scripts/x.sh` or `mise run test`. This
checker reports every `run:` step of the workflows in `.github/workflows/` and
of the composite actions (`action.yml` / `action.yaml`) in the repository that
contains any of:

- more than one line;
- a pipe, or a command list (`&&`, `||`, `;`, `&`);
- command substitution (`$(...)`, backticks, `<(...)`) or a heredoc (`<<`);
- shell control flow (`if`, `for`, `while`, `case`, ...);
- a `${{ }}` expression (pass the value through `env:` instead, which also
  prevents template injection);
- any code under a non-bash `shell:` (python, pwsh, ...), whether set on the
  step, by `defaults.run.shell`, or implied by a Windows `runs-on` (pwsh).

A step opts out with a comment `# lint: allow-inline-script <reason>`: a YAML
comment directly above the step or inside it, or a shell comment in its script.
Text inside strings does not count. The reason is required.

Findings are GitHub annotations: warnings by default, errors with `--blocking`
(or LINT_INLINE_SCRIPTS_BLOCKING=true), in which case the exit code is 1 when
anything is found or a file can't be parsed. Without arguments the current
directory is checked; pass directories to check those repositories, or files to
check single workflows or actions.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print(
        "::error title=Inline scripts::PyYAML is not installed for "
        f"{sys.executable}. Run this checker with a Python that has PyYAML, "
        "or with `uv run --script`."
    )
    sys.exit(2)

OPT_OUT = re.compile(r"#\s*lint:\s*allow-inline-script(?![\w-])(?P<reason>.*)$")
SKIP_DIRS = {".git", "node_modules"}
BASH_SHELLS = {"bash", "sh"}
CONTROL_WORDS = {
    "if", "then", "elif", "else", "fi", "for", "while", "until", "do", "done",
    "case", "esac", "select", "function", "{", "}", "(", ")", "[[",
}  # fmt: skip

MULTILINE = "multiple lines"
PIPE = "a pipe (|)"
CHAIN = "a command list (&&, ||, ; or &)"
SUBSTITUTION = "command substitution ($(...), backticks or <(...))"
HEREDOC = "a heredoc or here-string (<<)"
CONTROL = "shell control flow (if, for, while, case, ...)"
EXPRESSION = "a ${{ }} expression (pass it through env: instead)"
REASON_ORDER = [MULTILINE, PIPE, CHAIN, SUBSTITUTION, HEREDOC, CONTROL, EXPRESSION]
GUIDANCE = (
    "Move the code to a script under scripts/ or .github/scripts/ and call it "
    "with one command, or opt out with '# lint: allow-inline-script <reason>'."
)


HEREDOC_WORD = re.compile(r"-?[ \t]*(['\"]?)([^\s'\";&|<>()]+)\1")


def scan_script(script: str) -> tuple[set[str], list[str]]:
    """Shell constructs that make a script more than one simple command, and
    the script's shell comments. Quote, `${...}` and heredoc state carry
    across lines, so quoted text and heredoc payloads are data, never
    operators or comments."""
    found: set[str] = set()
    comments: list[str] = []
    quote = None
    braces = 0
    pending: list[str] = []
    body: list[str] = []
    for line in script.splitlines():
        if body:
            if line.strip() == body[0]:
                body.pop(0)
            continue
        words = line.split()
        if quote is None and not braces and words and (words[0] in CONTROL_WORDS or words[0][0] in "({"):
            found.add(CONTROL)
        i, n = 0, len(line)
        while i < n:
            c = line[i]
            if quote == "'":
                if c == "'":
                    quote = None
                i += 1
                continue
            if c == "\\":
                i += 2
                continue
            if quote == '"':
                if c == '"':
                    quote = None
                elif c == "`" or line.startswith("$(", i):
                    found.add(SUBSTITUTION)
                i += 1
                continue
            if c == "#" and not braces and (i == 0 or line[i - 1] in " \t"):
                comments.append(line[i:])
                break
            if c in "'\"":
                quote = c
            elif c == "`" or line.startswith(("$(", "<(", ">("), i):
                found.add(SUBSTITUTION)
            elif line.startswith("${", i):
                braces += 1
                i += 2
                continue
            elif c == "}" and braces:
                braces -= 1
            elif braces:
                pass  # Operators inside ${...} are argument text.
            elif line.startswith("<<<", i):
                found.add(HEREDOC)
                i += 3
                continue
            elif line.startswith("<<", i):
                found.add(HEREDOC)
                word = HEREDOC_WORD.match(line, i + 2)
                if word:
                    pending.append(word.group(2))
                    i = word.end()
                else:
                    i += 2
                continue
            elif line.startswith(("&&", "||"), i):
                found.add(CHAIN)
                i += 2
                continue
            elif c in "<>":
                # Redirections, consumed whole: >|, >&, <&, >>, <> and 2>&1.
                i += 2 if line[i + 1 : i + 2] in ("|", "&", ">") else 1
                continue
            elif line.startswith("&>", i):
                i += 3 if line.startswith("&>>", i) else 2
                continue
            elif c == "|":
                found.add(PIPE)
            elif c in ";&":
                found.add(CHAIN)
            i += 1
        if pending and quote is None:
            body, pending = pending, []
    return found, comments


def run_problems(script: str, shell: str | None, found: set[str]) -> list[str]:
    """Why a `run:` script is not one simple command (empty when it is)."""
    problems = set(found)
    if len([line for line in script.splitlines() if line.strip()]) > 1:
        problems.add(MULTILINE)
    if "${{" in script:
        problems.add(EXPRESSION)
    ordered = [reason for reason in REASON_ORDER if reason in problems]
    words = (shell or "").split()
    # A shell given by an expression can't be resolved statically.
    if words and "${{" not in shell and words[0].rsplit("/", 1)[-1] not in BASH_SHELLS:
        ordered.append(f"inline code for shell '{words[0]}'")
    return ordered


def child(node: yaml.Node | None, key: str) -> yaml.Node | None:
    if isinstance(node, yaml.MappingNode):
        for key_node, value_node in node.value:
            if isinstance(key_node, yaml.ScalarNode) and key_node.value == key:
                return value_node
    return None


def scalar(node: yaml.Node | None) -> str | None:
    return node.value if isinstance(node, yaml.ScalarNode) else None


def run_line(step: yaml.MappingNode) -> int:
    for key_node, _ in step.value:
        if isinstance(key_node, yaml.ScalarNode) and key_node.value == "run":
            return key_node.start_mark.line + 1
    return step.start_mark.line + 1


def defaults_shell(node: yaml.Node | None) -> str | None:
    return scalar(child(child(child(node, "defaults"), "run"), "shell"))


def indent(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


def scalar_spans(node: yaml.Node) -> list[tuple[tuple[int, int], tuple[int, int]]]:
    """(start, end) positions of every scalar under a node, end exclusive."""
    if isinstance(node, yaml.ScalarNode):
        start = (node.start_mark.line, node.start_mark.column)
        if node.style in ("|", ">"):
            # The header line of a block scalar may end with a YAML comment.
            start = (node.start_mark.line + 1, 0)
        return [(start, (node.end_mark.line, node.end_mark.column))]
    if isinstance(node, yaml.MappingNode):
        return [span for pair in node.value for item in pair for span in scalar_spans(item)]
    if isinstance(node, yaml.SequenceNode):
        return [span for item in node.value for span in scalar_spans(item)]
    return []


def step_comments(lines: list[str], step: yaml.MappingNode, shell_comments: list[str]) -> list[str]:
    """The YAML comments directly above and inside a step, and the shell
    comments of its script. Quoted or other string data never counts."""
    start = step.start_mark.line
    base = indent(lines[start])
    comments = []
    k = start - 1
    while k >= 0 and lines[k].lstrip().startswith("#") and indent(lines[k]) <= base:
        comments.append(lines[k].lstrip())
        k -= 1
    spans = scalar_spans(step)
    k = start
    while k < len(lines) and (k == start or not lines[k].strip() or indent(lines[k]) > base):
        line = lines[k]
        for col, c in enumerate(line):
            if (
                c == "#"
                and (col == 0 or line[col - 1] in " \t")
                and not any(begin <= (k, col) < end for begin, end in spans)
            ):
                comments.append(line[col:])
                break
        k += 1
    return comments + shell_comments


def implicit_shell(job: yaml.Node) -> str | None:
    """The default shell of a job without defaults.run.shell: pwsh on runners
    that are statically Windows, bash (None) otherwise or when unknown."""
    runs_on = child(job, "runs-on")
    if isinstance(runs_on, yaml.MappingNode):
        runs_on = child(runs_on, "labels")
    nodes = runs_on.value if isinstance(runs_on, yaml.SequenceNode) else [runs_on]
    labels = [label for label in map(scalar, nodes) if label]
    # Every label must match, so a literal Windows label decides even when
    # another label is an expression.
    return "pwsh" if any(label.lower().startswith("windows") for label in labels) else None


def msg(value: str) -> str:
    return value.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def prop(value: str) -> str:
    return msg(value).replace(":", "%3A").replace(",", "%2C")


def cell(value: str) -> str:
    return value.replace("|", "\\|").replace("\n", " ")


class Checker:
    def __init__(self, level: str) -> None:
        self.level = level
        # (file, line, step, problems or opt-out reason)
        self.findings: list[tuple[str, int, str, str]] = []
        self.opt_outs: list[tuple[str, int, str, str]] = []
        self.steps = 0
        self.files = 0
        self.unreadable = 0

    def check_file(self, path: Path, display: str, is_action: bool) -> None:
        try:
            text = path.read_text(encoding="utf-8")
            root = yaml.compose(text, Loader=yaml.SafeLoader)
        except (OSError, UnicodeDecodeError, yaml.YAMLError) as error:
            first = (str(error).splitlines() or [type(error).__name__])[0]
            print(f"::{self.level} file={prop(display)},title=Inline scripts::Could not parse: {msg(first)}")
            self.unreadable += 1
            return
        self.files += 1
        lines = text.splitlines()
        if is_action:
            runs = child(root, "runs")
            if scalar(child(runs, "using")) == "composite":
                self.check_steps(child(runs, "steps"), lines, display, "composite action", None)
            return
        jobs = child(root, "jobs")
        if not isinstance(jobs, yaml.MappingNode):
            return
        workflow_shell = defaults_shell(root)
        for job_key, job in jobs.value:
            job_shell = defaults_shell(job) or workflow_shell or implicit_shell(job)
            self.check_steps(child(job, "steps"), lines, display, f"job '{job_key.value}'", job_shell)

    def check_steps(
        self,
        steps: yaml.Node | None,
        lines: list[str],
        display: str,
        owner: str,
        default_shell: str | None,
    ) -> None:
        if not isinstance(steps, yaml.SequenceNode):
            return
        for index, step in enumerate(steps.value, start=1):
            script = scalar(child(step, "run"))
            if script is None:
                continue
            self.steps += 1
            label = scalar(child(step, "name")) or scalar(child(step, "id")) or f"#{index}"
            where = f"{owner}, step '{label}'"
            line = run_line(step)
            found, shell_comments = scan_script(script)
            problems = run_problems(script, scalar(child(step, "shell")) or default_shell, found)
            comments = step_comments(lines, step, shell_comments)
            opt_out = next(filter(None, map(OPT_OUT.search, comments)), None)
            if opt_out:
                reason = opt_out.group("reason").lstrip(" :-").strip()
                if reason:
                    self.opt_outs.append((display, line, where, reason))
                    continue
                problems.append("an allow-inline-script opt-out without a reason")
            if problems:
                self.report(display, line, where, ", ".join(problems))

    def report(self, display: str, line: int, where: str, problems: str) -> None:
        text = f"{where[0].upper()}{where[1:]}: {problems}. {GUIDANCE}"
        print(f"::{self.level} file={prop(display)},line={line},title=Inline script::{msg(text)}")
        self.findings.append((display, line, where, problems))

    def write_summary(self, summary: str) -> None:
        out = []
        for rows, title, column in (
            (self.findings, "`run:` step(s) to move into a script", "Problems"),
            (self.opt_outs, "opt-out(s)", "Reason"),
        ):
            if not rows:
                continue
            out += [
                f"### Inline scripts: {len(rows)} {title}",
                "",
                f"| File:line | Step | {column} |",
                f"| --------- | ---- | {'-' * len(column)} |",
            ]
            out += [f"| {cell(f)}:{n} | {cell(w)} | {cell(p)} |" for f, n, w, p in rows]
            out.append("")
        if self.findings:
            out += [GUIDANCE, ""]
        if self.unreadable:
            out += [f"Inline scripts: {self.unreadable} file(s) could not be parsed, so they were not checked.", ""]
        if out:
            with open(summary, "a", encoding="utf-8") as handle:
                handle.write("\n".join(out) + "\n")


def discover(root: Path) -> list[tuple[Path, bool]]:
    """The workflows and action metadata files of a repository."""
    found: list[tuple[Path, bool]] = []
    workflows = root / ".github" / "workflows"
    if workflows.is_dir():
        found += [
            (path, False) for path in sorted(workflows.iterdir()) if path.is_file() and path.suffix in (".yml", ".yaml")
        ]
    for directory, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(name for name in dirnames if name not in SKIP_DIRS)
        found += [(Path(directory) / name, True) for name in sorted(filenames) if name in ("action.yml", "action.yaml")]
    return found


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Report inline scripts in GitHub Actions run: steps.")
    parser.add_argument("paths", nargs="*", type=Path, help="repositories, workflows or actions to check")
    parser.add_argument(
        "--blocking",
        action="store_true",
        default=os.environ.get("LINT_INLINE_SCRIPTS_BLOCKING", "").lower() == "true",
        help="report errors and exit 1 on findings (default: warnings, exit 0)",
    )
    args = parser.parse_args(argv)
    checker = Checker("error" if args.blocking else "warning")
    for target in args.paths or [Path(".")]:
        if target.is_dir():
            for path, is_action in discover(target):
                checker.check_file(path, path.relative_to(target).as_posix(), is_action)
        elif target.is_file():
            checker.check_file(target, target.as_posix(), target.name in ("action.yml", "action.yaml"))
        else:
            print(f"::error title=Inline scripts::No such file or directory: {msg(str(target))}")
            return 2
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        checker.write_summary(os.environ["GITHUB_STEP_SUMMARY"])
    print(
        f"Inline scripts: checked {checker.steps} run step(s) in {checker.files} file(s); "
        f"{len(checker.findings)} to move into a script, {len(checker.opt_outs)} opted out."
    )
    if checker.unreadable:
        print(f"Inline scripts: {checker.unreadable} file(s) could not be parsed, so they were not checked.")
    return 1 if args.blocking and (checker.findings or checker.unreadable) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

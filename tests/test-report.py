#!/usr/bin/env python3
"""Contract tests for actions/test-report using JUnit fixtures of pytest, bats
and Pester, run through the composite action's actual Bash step."""

import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parent.parent
ACTION = ROOT / "actions" / "test-report"
FIXTURES = ROOT / "tests" / "fixtures" / "test-report"
SOURCES = ["tests/test_math.py", "tests/test_io.py", "tests/bash/install.bats", "tests/Get-Thing.Tests.ps1"]


class TestReportContract(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="test-report-")
        self.addCleanup(temp.cleanup)
        self.work = Path(temp.name).resolve()
        for source in SOURCES:
            (self.work / source).parent.mkdir(parents=True, exist_ok=True)
            (self.work / source).write_text("\n", encoding="utf-8")
        results = self.work / "results"
        results.mkdir()
        for fixture in FIXTURES.glob("*.xml"):
            text = fixture.read_text(encoding="utf-8").replace("WORKSPACE", self.work.as_posix())
            (results / fixture.name).write_text(text, encoding="utf-8")

    def run_action(self, **overrides):
        """Run the composite step with its env mapping, like the runner does."""
        text = (ACTION / "action.yml").read_text(encoding="utf-8")
        inputs = {"paths": "results/*.xml", "title": "Test results", "max-failures": "50", "if-no-files": "warn"}
        inputs.update(overrides)
        summary, output = self.work / "summary.md", self.work / "output"
        summary.write_text("", encoding="utf-8")
        output.write_text("", encoding="utf-8")
        env = dict(os.environ, GITHUB_WORKSPACE=str(self.work), GITHUB_STEP_SUMMARY=str(summary))
        env["GITHUB_OUTPUT"] = str(output)
        mappings = re.findall(r"^        ([A-Z_]+): \$\{\{ inputs\.([\w-]+) \}\}$", text, re.MULTILINE)
        self.assertEqual({name for _, name in mappings}, set(inputs))
        for variable, name in mappings:
            env[variable] = inputs[name]
        self.assertIn('      run: bash "${GITHUB_ACTION_PATH}/report.sh"\n', text)
        report = shlex.quote(str(ACTION / "report.sh").replace("\\", "/"))
        # Windows's python3 app alias is not necessarily the interpreter running this test.
        interpreter = shlex.quote(sys.executable.replace("\\", "/"))
        script = f'python3() {{ {interpreter} "$@"; }}\nexport -f python3\nbash {report}\n'
        result = subprocess.run(
            [shutil.which("bash"), "--noprofile", "--norc", "-c", script],
            check=False,
            env=env,
            cwd=self.work,
            text=True,
            capture_output=True,
            encoding="utf-8",
        )
        outputs = dict(line.split("=", 1) for line in output.read_text(encoding="utf-8").splitlines())
        return result, summary.read_text(encoding="utf-8"), outputs

    def annotations(self, stdout):
        return [line for line in stdout.splitlines() if line.startswith("::error ")]

    def test_reports_pytest_bats_and_pester_results(self):
        result, summary, outputs = self.run_action(title="Unit tests (3.14)")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(outputs, {"passed": "4", "failed": "4", "skipped": "2", "total": "10"})
        self.assertIn("### ❌ Unit tests (3.14): 4 passed, 4 failed, 2 skipped", summary)
        self.assertIn("| ❌ install.bats | 1 | 1 | 0 | 0.3s |", summary)
        self.assertIn("| ✅ helpers.bats | 0 | 0 | 1 | 0.0s |", summary)
        # Table cells are escaped; the deepest workspace frame wins over stdlib frames.
        self.assertIn(
            "| tests.test_io › test_read[a\\|b] | `tests/test_io.py:4` | "
            'failed on setup with "FileNotFoundError: data.txt" |',
            summary,
        )
        # bats shows the failing command, not its location note.
        self.assertIn("| install.bats › rejects a bad version | `tests/bash/install.bats:12` | `[", summary)
        self.assertEqual(
            sorted(re.findall(r"file=([^,]+),line=(\d+)", "\n".join(self.annotations(result.stdout)))),
            [
                ("tests/Get-Thing.Tests.ps1", "14"),
                ("tests/bash/install.bats", "12"),
                ("tests/test_io.py", "4"),
                ("tests/test_math.py", "7"),
            ],
        )

    def test_unparseable_file_is_reported_and_others_still_count(self):
        (self.work / "results" / "broken.xml").write_text("<testsuite><testcase", encoding="utf-8")
        result, summary, outputs = self.run_action(paths="results/bats.xml\nresults/broken.xml\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(outputs["total"], "3")
        self.assertIn("::warning file=results/broken.xml,title=Test report::Could not parse", result.stdout)
        self.assertIn("Could not parse `results/broken.xml`", summary)

    def test_failed_tests_table_and_annotations_are_capped(self):
        cases = "".join(f'<testcase classname="c" name="t{i}"><failure message="m{i}"/></testcase>' for i in range(12))
        (self.work / "results" / "many.xml").write_text(f"<testsuite name='many'>{cases}</testsuite>", "utf-8")
        result, summary, _ = self.run_action(paths="results/many.xml", **{"max-failures": "3"})
        self.assertEqual(len(self.annotations(result.stdout)), 10)
        self.assertIn("| c › t2 |", summary)
        self.assertNotIn("| c › t3 |", summary)
        self.assertIn("9 more failed test(s) not listed.", summary)

    def test_no_matching_files(self):
        for mode, code, level in (("warn", 0, "warning"), ("error", 1, "error")):
            with self.subTest(mode=mode):
                result, summary, outputs = self.run_action(paths="missing/*.xml", **{"if-no-files": mode})
                self.assertEqual(result.returncode, code, result.stderr)
                self.assertIn(f"::{level} title=Test report::No test result files match: missing/*.xml", result.stdout)
                self.assertIn("### ⚠️ Test results: 0 passed, 0 failed, 0 skipped", summary)
        result, summary, outputs = self.run_action(paths="missing/*.xml", **{"if-no-files": "ignore"})
        self.assertEqual((result.returncode, summary, outputs), (0, "", {}))

    def test_invalid_input_fails(self):
        result, _, _ = self.run_action(**{"if-no-files": "maybe"})
        self.assertEqual(result.returncode, 2)
        self.assertIn("invalid choice", result.stderr)

    def test_locations_in_paths_with_spaces_and_file_without_line(self):
        for source in ("my suite/a.bats", "my suite/B.Tests.ps1", "my tests/test_c.py", "tests/test_d.py"):
            (self.work / source).parent.mkdir(parents=True, exist_ok=True)
            (self.work / source).write_text("\n", encoding="utf-8")
        cases = [
            ("a", "", "(in test file my suite/a.bats, line 3)"),
            ("b", "", f"at &lt;ScriptBlock&gt;, {self.work.as_posix()}/my suite/B.Tests.ps1:4"),
            ("c", "", "my tests/test_c.py:5: AssertionError"),
            ("d", ' file="tests/test_d.py"', "tests/test_d.py:6: AssertionError"),
        ]
        xml = "".join(f'<testcase name="{n}"{a}><failure>{t}</failure></testcase>' for n, a, t in cases)
        (self.work / "results" / "spaces.xml").write_text(f"<testsuite name='s'>{xml}</testsuite>", "utf-8")
        result, _, _ = self.run_action(paths="results/spaces.xml")
        self.assertEqual(
            re.findall(r"file=([^,]+),line=(\d+)", result.stdout),
            [
                ("my suite/a.bats", "3"),
                ("my suite/B.Tests.ps1", "4"),
                ("my tests/test_c.py", "5"),
                ("tests/test_d.py", "6"),
            ],
        )

    def test_text_location_beats_attributes_and_dependencies_are_skipped(self):
        dependency = self.work / ".venv/lib/python3.14/site-packages/pkg/helper.py"
        dependency.parent.mkdir(parents=True)
        dependency.write_text("\n", encoding="utf-8")
        cases = [
            ("e", ' file="tests/test_math.py" line="2"', "tests/test_math.py:9: AssertionError"),
            ("f", ' file="tests/test_math.py" line="0"', "AssertionError"),
            ("g", "", "tests/test_io.py:7: in test_g\n.venv/lib/python3.14/site-packages/pkg/helper.py:20: Error"),
        ]
        xml = "".join(f'<testcase name="{n}"{a}><failure>{t}</failure></testcase>' for n, a, t in cases)
        (self.work / "results" / "attrs.xml").write_text(f"<testsuite name='s'>{xml}</testsuite>", "utf-8")
        result, _, _ = self.run_action(paths="results/attrs.xml")
        self.assertEqual(
            re.findall(r"^::error file=([^,]+)(?:,line=(\d+))?,title", result.stdout, re.MULTILINE),
            [("tests/test_math.py", "9"), ("tests/test_math.py", ""), ("tests/test_io.py", "7")],
        )

    def test_overlapping_patterns_count_each_file_once(self):
        _, _, outputs = self.run_action(paths="results/bats.xml\n./results/bats.xml\nresults/*ats.xml")
        self.assertEqual(outputs["total"], "3")

    def test_test_names_cannot_inject_workflow_commands(self):
        name = "x&#13;::error title=Injected::forged&#13;"
        xml = f'<testsuite name="s"><testcase name="{name}"><failure message="m"/></testcase></testsuite>'
        (self.work / "results" / "inject.xml").write_text(xml, "utf-8")
        result, summary, _ = self.run_action(paths="results/inject.xml")
        self.assertNotIn("\r", summary)
        # The summary echo runs with workflow commands stopped; nothing outside it may inject.
        stopped = re.sub(r"::stop-commands::(\w+)\n.*?\n::\1::", "", result.stdout, flags=re.DOTALL)
        lines = re.split(r"[\r\n]", stopped)
        self.assertFalse([line for line in lines if line.lstrip().startswith("::error title=Injected")])
        self.assertEqual(len([line for line in lines if line.startswith("::error ")]), 1)

    def test_node_root_level_testcases_and_file_urls(self):
        source = self.work / "tests" / "planner.test.js"
        source.write_text("\n", encoding="utf-8")
        spaced = self.work / "my tests" / "static.test.js"
        spaced.parent.mkdir()
        spaced.write_text("\n", encoding="utf-8")
        failure = f"Expected values to be strictly equal\n    at TestContext.&lt;anonymous&gt; ({source.as_uri()}:12:3)"
        xml = (
            '<testsuites><testcase name="top passes" classname="test"/>'
            f'<testcase name="top fails" classname="test"><failure type="testCodeFailure">{failure}</failure></testcase>'
            f'<testcase name="spaced" classname="test"><failure>at x ({spaced.as_uri()}:4:1)</failure></testcase>'
            '<testsuite name="group"><testcase name="nested" classname="test"/></testsuite></testsuites>'
        )
        (self.work / "results" / "node.xml").write_text(xml, "utf-8")
        result, summary, outputs = self.run_action(paths="results/node.xml")
        self.assertEqual(outputs, {"passed": "2", "failed": "2", "skipped": "0", "total": "4"})
        self.assertIn("| ❌ node.xml | 1 | 2 | 0 |", summary)
        self.assertEqual(
            re.findall(r"file=([^,]+),line=(\d+)", result.stdout),
            [("tests/planner.test.js", "12"), ("my tests/static.test.js", "4")],
        )

    def test_paths_relative_to_a_report_in_a_subdirectory(self):
        (self.work / "backend" / "tests").mkdir(parents=True)
        (self.work / "backend" / "tests" / "test_api.py").write_text("\n", encoding="utf-8")
        xml = (
            '<testsuite name="pytest"><testcase classname="tests.test_api" name="a" file="tests/test_api.py" line="3">'
            '<failure message="boom">tests/test_api.py:12: AssertionError</failure></testcase>'
            '<testcase classname="tests.test_api" name="b" file="tests/test_api.py" line="20">'
            '<failure message="no location"/></testcase></testsuite>'
        )
        (self.work / "backend" / "junit.xml").write_text(xml, "utf-8")
        result, _, _ = self.run_action(paths="backend/junit.xml")
        self.assertEqual(
            re.findall(r"file=([^,]+),line=(\d+)", result.stdout),
            [("backend/tests/test_api.py", "12"), ("backend/tests/test_api.py", "20")],
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)

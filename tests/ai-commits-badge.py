#!/usr/bin/env python3
"""Offline contract tests using synthetic history and the actual composite step."""
import importlib.util
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from xml.etree import ElementTree as ET

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parent.parent
ACTION = ROOT / "actions" / "ai-commits-badge"
SPEC = importlib.util.spec_from_file_location("badge", ACTION / "ai_commits_badge.py")
badge = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(badge)
NS = {"svg": "http://www.w3.org/2000/svg"}


class BadgeContract(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ai-badge-")
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.repo = self.work / "repo"
        self.env = dict(os.environ, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull)
        for key in list(self.env):
            if key.startswith(("GIT_CONFIG_KEY_", "GIT_CONFIG_VALUE_")) or key == "GIT_CONFIG_COUNT":
                del self.env[key]
        self.git("init", "--quiet", str(self.repo), cwd=self.work)
        self.tree = self.git("mktree", input="").stdout.strip()
        self.tip = None
        self.commit("Human", "human@example.org", "Initial")
        self.commit("copilot-swe-agent[bot]", "agent@example.org", "Agent")
        self.commit(
            "Human", "human@example.org",
            "Pair\n\nCo-authored-by: Someone <someone@example.org>\n"
            "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>",
        )
        self.commit(
            "renovate[bot]", "bot@example.org",
            "Automation\n\nCo-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>",
        )
        side = self.commit("Human", "human@example.org", "Side")
        self.commit("Human", "human@example.org", "Merge", parents=[side, self.initial])

    def git(self, *args, cwd=None, input=None, env=None):
        return subprocess.run(
            ["git", *args], cwd=cwd or self.repo, env=env or self.env,
            input=input, capture_output=True, text=True, encoding="utf-8", check=True,
        )

    def commit(self, name, email, message, parents=None):
        env = dict(
            self.env, GIT_AUTHOR_NAME=name, GIT_AUTHOR_EMAIL=email,
            GIT_COMMITTER_NAME=name, GIT_COMMITTER_EMAIL=email,
            GIT_AUTHOR_DATE="2020-01-01T12:00:00+00:00",
            GIT_COMMITTER_DATE="2020-01-01T12:00:00+00:00",
        )
        args = ["commit-tree", self.tree]
        for parent in parents if parents is not None else ([self.tip] if self.tip else []):
            args += ["-p", parent]
        self.tip = self.git(*args, input=message + "\n", env=env).stdout.strip()
        if not hasattr(self, "initial"):
            self.initial = self.tip
        self.git("update-ref", "refs/heads/main", self.tip)
        self.git("symbolic-ref", "HEAD", "refs/heads/main")
        return self.tip

    def run_action(self, **overrides):
        text = (ACTION / "action.yml").read_text(encoding="utf-8")
        inputs = {
            "ref": "HEAD", "since": "", "name": "owner/repo", "label": "AI commits",
            "out": str(self.work / "out"), "themes": "false", "repo-dir": str(self.repo),
        }
        inputs.update(overrides)
        env = dict(self.env, ACTION_PATH=str(ACTION), GITHUB_OUTPUT=str(self.work / "outputs"))
        mappings = re.findall(r"^        ([A-Z_]+): \$\{\{ inputs\.([\w-]+) \}\}$", text, re.M)
        self.assertEqual({name for _, name in mappings}, set(inputs))
        for variable, name in mappings:
            env[variable] = inputs[name]
        step = re.split(r"      run: \|[-+]?\n", text, maxsplit=1)[1]
        script = "\n".join(line[8:] for line in step.splitlines()) + "\n"
        # Windows's python3 app alias is not necessarily the interpreter running this test.
        interpreter = shlex.quote(sys.executable.replace("\\", "/"))
        script = f"python3() {{ {interpreter} \"$@\"; }}\n" + script
        return subprocess.run(
            [shutil.which("bash"), "--noprofile", "--norc", "-c", script],
            env=env, cwd=self.work, text=True, capture_output=True, encoding="utf-8",
        )

    def stats(self):
        return json.loads((self.work / "out" / "ai-commits-stats.json").read_text(encoding="utf-8"))

    def test_classification_files_and_step_outputs(self):
        result = self.run_action(themes="true", name='owner/<repo> & "name"')
        self.assertEqual(result.returncode, 0, result.stderr)
        st = self.stats()
        expected = {
            "commits": 4, "ai_commits": 2, "ai_percent": 50.0,
            "agent": 1, "coauthored": 1, "unattributed": 2, "excluded_automation": 1,
        }
        for key, value in expected.items():
            self.assertEqual(st[key], value, key)
        self.assertEqual(st["tools"], {"Copilot coding agent": 1, "Copilot CLI": 1})
        out = self.work / "out"
        self.assertEqual({p.name for p in out.iterdir()}, {
            "ai-commits.svg", "ai-commits.json", "ai-commits-stats.json",
            "ai-commits-card.svg", "ai-commits-card-light.svg", "ai-commits-card-dark.svg",
        })
        endpoint = json.loads((out / "ai-commits.json").read_text(encoding="utf-8"))
        self.assertEqual(endpoint["schemaVersion"], 1)
        self.assertEqual(endpoint["message"], "50%")
        for path in out.glob("*.svg"):
            svg = ET.parse(path).getroot()
            self.assertIn("No recorded AI attribution", svg.get("aria-label"))
            self.assertIn('owner/<repo> & "name"', svg.find("svg:title", NS).text)
            self.assertNotIn("human only", path.read_text(encoding="utf-8").lower())
            if "card" in path.name:
                self.assertIsNone(svg.find(".//*[@textLength]"))
                self.assertIsNone(svg.find(".//*[@lengthAdjust]"))
                labels = svg.findall("svg:text[@y='121']", NS)
                self.assertEqual(len(labels), 3)
                for label in labels:
                    self.assertTrue(badge.fits("".join(label.itertext()), 12, 129))
        actual = dict(line.split("=", 1) for line in (self.work / "outputs").read_text().splitlines())
        self.assertEqual(actual, {key.replace("_", "-"): str(value) for key, value in expected.items()})
        text = (ACTION / "action.yml").read_text()
        for key in actual:
            self.assertIn(f"value: ${{{{ steps.generate.outputs.{key} }}}}", text)

    def test_shallow_guard(self):
        shallow = self.work / "shallow"
        self.git("clone", "--quiet", "--depth=1", self.repo.as_uri(), str(shallow), cwd=self.work)
        result = self.run_action(**{"repo-dir": str(shallow), "since": "2019-01-01"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("fetch-depth: 0", result.stderr)
        self.assertFalse((self.work / "out").exists())
        self.assertFalse((self.work / "outputs").exists())

    def test_empty_denominator_and_default_files(self):
        result = self.run_action(since="2100-01-01", label="Custom")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNone(self.stats()["ai_percent"])
        endpoint = json.loads((self.work / "out" / "ai-commits.json").read_text())
        self.assertEqual((endpoint["message"], endpoint["label"]), ("n/a", "Custom"))
        self.assertEqual(len(list((self.work / "out").iterdir())), 4)
        self.assertIn("ai-percent=n/a\n", (self.work / "outputs").read_text())

    def test_central_identities_recognize_agent_bots_and_unknown_authors(self):
        self.commit("google-labs-jules[bot]", "jules@example.org", "Jules")
        self.commit("Unknown assistant", "unknown@example.org", "Unrecognized")
        result = self.run_action()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.stats()["agent"], 2)
        self.assertEqual(self.stats()["unattributed"], 3)
        self.assertEqual(self.stats()["ai_percent"], 50.0)
        self.assertEqual(self.stats()["excluded_automation"], 1)
        self.assertEqual(self.stats()["tools"]["Jules"], 1)

    def test_invalid_inputs_fail_before_writing(self):
        for overrides in (
            {"themes": "yes"},
            {"ref": "--all"}, {"ref": "missing"},
        ):
            with self.subTest(overrides=overrides):
                result = self.run_action(**overrides)
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue(result.stderr)
                self.assertFalse((self.work / "out").exists())
                self.assertFalse((self.work / "outputs").exists())

    def test_ref_limits_measured_history(self):
        result = self.run_action(ref=self.initial)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.stats()["commits"], 1)
        self.assertEqual(self.stats()["ai_percent"], 0.0)

    def test_partial_identities_do_not_count_as_ai(self):
        self.commit("Human", "noreply@anthropic.com.example.org", "Not Claude")
        self.commit("Human", "alice+223556219+Copilot@example.org", "Not Copilot")
        self.commit("not-copilot-swe-agent", "human@example.org", "Not the agent")
        self.commit(
            "Human", "human@example.org",
            "Unrecognized trailers\n\n"
            "Co-authored-by: Human <noreply@anthropic.com.example.org>\n"
            "Co-authored-by: Human <alice+223556219+Copilot@example.org>",
        )
        result = self.run_action()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.stats()["agent"], 1)
        self.assertEqual(self.stats()["coauthored"], 1)
        self.assertEqual(self.stats()["unattributed"], 6)
        self.assertEqual(self.stats()["ai_percent"], 25.0)

    def test_display_percentage_avoids_double_rounding(self):
        self.tip = None
        self.commit("copilot-swe-agent[bot]", "agent@example.org", "Agent")
        for i in range(21):
            self.commit("Human", "human@example.org", f"Unattributed {i}")
        result = self.run_action(themes="true")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.stats()["ai_percent"], 4.5)
        out = self.work / "out"
        endpoint = json.loads((out / "ai-commits.json").read_text(encoding="utf-8"))
        self.assertEqual(endpoint["message"], "5%")
        compact = ET.parse(out / "ai-commits.svg")
        self.assertIn("5%", [text.text for text in compact.findall(".//svg:text", NS)])
        for path in out.glob("ai-commits-card*.svg"):
            card = ET.parse(path)
            self.assertEqual(card.find("svg:text[@y='74']/svg:tspan", NS).text, "5%")
            self.assertEqual(card.find("svg:text[@y='121']/svg:tspan", NS).text, "5%")
        self.assertIn("ai-percent=4.5\n", (self.work / "outputs").read_text())


if __name__ == "__main__":
    unittest.main(verbosity=2)

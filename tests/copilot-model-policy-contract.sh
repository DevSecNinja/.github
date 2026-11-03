#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v python >/dev/null 2>&1; then
    python_command=python
elif command -v python3 >/dev/null 2>&1; then
    python_command=python3
else
    echo "error: Python 3 is required for strict offline policy validation." >&2
    exit 1
fi

"${python_command}" - "${repo_root}" <<'PYTHON'
import copy
import json
import re
import sys
import unittest
from pathlib import Path

repo_root = Path(sys.argv[1])


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate object key: {key!r}")
        result[key] = value
    return result


def reject_constant(token):
    raise ValueError(f"nonstandard JSON numeric constant: {token}")


def parse_model_policy(document):
    policy = json.loads(
        document, object_pairs_hook=unique_object, parse_constant=reject_constant
    )
    if not isinstance(policy, dict) or set(policy) != {"schemaVersion", "revision", "models"}:
        raise ValueError("policy must contain exactly schemaVersion, revision, and models")
    if type(policy["schemaVersion"]) is not int or policy["schemaVersion"] != 1:
        raise ValueError("schemaVersion must be the integer token 1")
    revision = policy["revision"]
    if type(revision) is not int or not 1 <= revision <= 9007199254740991:
        raise ValueError("revision must be an integer token in 1..9007199254740991")
    models = policy["models"]
    if not isinstance(models, dict) or set(models) != {"default", "writer"}:
        raise ValueError("models must contain exactly default and writer")
    for role, model in models.items():
        if (
            not isinstance(model, str)
            or model == "auto"
            or re.fullmatch(r"[a-z0-9][a-z0-9._-]{0,127}", model) is None
        ):
            raise ValueError(f"invalid explicit model ID for {role}")
    return policy


class ModelPolicyContract(unittest.TestCase):
    def test_repository_policy(self):
        parse_model_policy((repo_root / "copilot-models.json").read_text(encoding="utf-8"))

    def test_raw_conformance_corpus(self):
        cases = json.loads(
            (repo_root / "tests/fixtures/copilot-model-policy-cases.json").read_text(
                encoding="utf-8"
            ),
            object_pairs_hook=unique_object,
            parse_constant=reject_constant,
        )
        self.assertIsInstance(cases, list)
        self.assertTrue(cases, "the conformance corpus must not be empty")
        names = set()
        for case in cases:
            self.assertIsInstance(case, dict)
            self.assertEqual(set(case), {"name", "valid", "document"})
            self.assertIsInstance(case["name"], str)
            self.assertTrue(case["name"])
            self.assertNotIn(case["name"], names)
            names.add(case["name"])
            self.assertIs(type(case["valid"]), bool)
            self.assertIsInstance(case["document"], str)
            with self.subTest(case=case["name"]):
                if case["valid"]:
                    parse_model_policy(case["document"])
                else:
                    with self.assertRaises(ValueError):
                        parse_model_policy(case["document"])
        print(f"Checked {len(cases)} raw policy conformance cases (offline).")

    def test_invalid_shapes(self):
        base = {
            "schemaVersion": 1,
            "revision": 1,
            "models": {"default": "model-a", "writer": "model-b"},
        }
        for field in base:
            with self.subTest(missing=field):
                candidate = copy.deepcopy(base)
                del candidate[field]
                with self.assertRaises(ValueError):
                    parse_model_policy(json.dumps(candidate))
        invalid_values = {
            "schemaVersion": [None, "1", True, 1.0, 1.5, 2],
            "revision": [None, "1", True, 1.0, 1.5, 0, -1, 9007199254740992],
            "models": [None, [], {}],
        }
        for field, values in invalid_values.items():
            for value in values:
                with self.subTest(field=field, value=value):
                    candidate = copy.deepcopy(base)
                    candidate[field] = value
                    with self.assertRaises(ValueError):
                        parse_model_policy(json.dumps(candidate))
        for role in base["models"]:
            with self.subTest(missing_role=role):
                candidate = copy.deepcopy(base)
                del candidate["models"][role]
                with self.assertRaises(ValueError):
                    parse_model_policy(json.dumps(candidate))

    def test_model_boundaries(self):
        base = {
            "schemaVersion": 1,
            "revision": 1,
            "models": {"default": "model-a", "writer": "model-b"},
        }
        for role in base["models"]:
            for model in ("a", "a" * 128, "0model._-1"):
                with self.subTest(role=role, valid_model=model):
                    candidate = copy.deepcopy(base)
                    candidate["models"][role] = model
                    parse_model_policy(json.dumps(candidate))
            for model in (
                None, False, 1, [], {}, "a" * 129, "", " ", "auto", "AUTO", "Auto",
                "--model", " model", "model ", "model name", "model/name",
                "model;command", "$(command)", "model\n", "model\r", "model\t",
            ):
                with self.subTest(role=role, invalid_model=model):
                    candidate = copy.deepcopy(base)
                    candidate["models"][role] = model
                    with self.assertRaises(ValueError):
                        parse_model_policy(json.dumps(candidate))


unittest.main(argv=[sys.argv[0]])
PYTHON

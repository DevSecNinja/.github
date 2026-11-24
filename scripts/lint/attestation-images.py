#!/usr/bin/env python3
"""Print the image values that dev container and Compose files pin.

Reads NUL-separated repository paths on stdin and prints one
"<path>\t<image>" line per image:

- dev container (`devcontainer.json`, `.devcontainer.json`, JSONC: comments
  and trailing commas allowed): the top-level "image";
- Compose (`compose*.y(a)ml`, `docker-compose*.y(a)ml`): `services.<name>.image`,
  with anchors, aliases and merge keys resolved and any YAML layout.

A file that can't be parsed prints "<path>\t!<reason>". Comments never count.
Part of scripts/lint/attestations.sh; the runner's system Python ships PyYAML.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

import yaml


def strip_jsonc(text: str) -> str:
    """JSON from JSONC: drop // and /* */ comments outside strings, then trailing commas."""
    out, i, n, in_string = [], 0, len(text), False
    while i < n:
        c = text[i]
        if in_string:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 1
            elif c == '"':
                in_string = False
        elif c == '"':
            in_string = True
            out.append(c)
        elif text.startswith("//", i):
            i = text.find("\n", i)
            if i < 0:
                break
            continue
        elif text.startswith("/*", i):
            end = text.find("*/", i + 2)
            i = n if end < 0 else end + 2
            continue
        else:
            out.append(c)
        i += 1
    return re.sub(r",(\s*[}\]])", r"\1", "".join(out))


def images(path: str) -> list[str]:
    text = Path(path).read_text(encoding="utf-8")
    if path.endswith(".json"):
        data = json.loads(strip_jsonc(text))
        value = data.get("image") if isinstance(data, dict) else None
        return [value] if isinstance(value, str) else []
    data = yaml.safe_load(text)
    services = data.get("services") if isinstance(data, dict) else None
    if not isinstance(services, dict):
        return []
    return [s["image"] for s in services.values() if isinstance(s, dict) and isinstance(s.get("image"), str)]


def main() -> int:
    for path in filter(None, sys.stdin.read().split("\0")):
        try:
            for value in images(path):
                print(f"{path}\t{value}")
        except (OSError, ValueError, yaml.YAMLError) as exc:
            reason = " ".join(str(exc).split())
            print(f"{path}\t!{reason}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

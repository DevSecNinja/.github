"""Print the image values that dev container and Compose files pin.

Reads NUL-separated repository paths on stdin and writes NUL-separated
"<path>", "<image>" pairs, so any file name is safe:

- dev container (`devcontainer.json`, `.devcontainer.json`, JSONC: comments
  and trailing commas allowed): the top-level "image";
- Compose (`compose*.y(a)ml`, `docker-compose*.y(a)ml`): `services.<name>.image`,
  with anchors, aliases, merge keys and Compose's `!reset`/`!override` tags
  resolved, in any YAML layout.

A file that can't be parsed writes "<path>", "!<reason>". Comments never count.
Run by scripts/lint/attestations.sh with the runner's system Python, which
ships PyYAML (no shebang: the API commits that ship it can't set the
executable bit).
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

import yaml


class ComposeLoader(yaml.SafeLoader):
    """SafeLoader plus Compose's merge tags; every other unknown tag is still rejected."""


def _override(loader: ComposeLoader, node: yaml.Node):
    if isinstance(node, yaml.MappingNode):
        return loader.construct_mapping(node, deep=True)
    if isinstance(node, yaml.SequenceNode):
        return loader.construct_sequence(node, deep=True)
    return loader.construct_scalar(node)


ComposeLoader.add_constructor("!override", _override)
ComposeLoader.add_constructor("!reset", lambda loader, node: None)


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
    data = yaml.load(text, Loader=ComposeLoader)  # a SafeLoader subclass
    services = data.get("services") if isinstance(data, dict) else None
    if not isinstance(services, dict):
        return []
    return [s["image"] for s in services.values() if isinstance(s, dict) and isinstance(s.get("image"), str)]


def main() -> int:
    out = sys.stdout
    for path in filter(None, sys.stdin.read().split("\0")):
        try:
            for value in images(path):
                out.write(f"{path}\0{value}\0")
        except (OSError, ValueError, yaml.YAMLError) as exc:
            reason = " ".join(str(exc).split())
            out.write(f"{path}\0!{reason}\0")
    return 0


if __name__ == "__main__":
    sys.exit(main())

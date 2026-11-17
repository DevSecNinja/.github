"""Exit 0 when renovate.json5 extends the preset in argv[1] at the top level.

Run by scripts/config-sync/sync-files.sh (job sync of
.github/workflows/config-sync.yml). renovate.json5 is repo-owned; config-sync
only checks that its top-level `extends` still pulls in the org defaults. The
runner has no JSON5 parser, so this tokenizes the file (strings, comments,
brackets) with the Python standard library. Exit 1: preset missing; exit 2:
unterminated comment.
"""

import sys
from pathlib import Path

text = Path("renovate.json5").read_text(encoding="utf-8")
tokens, i, n = [], 0, len(text)
while i < n:
    c = text[i]
    if text.startswith("//", i):
        i = text.find("\n", i)
        i = n if i < 0 else i
    elif text.startswith("/*", i):
        i = text.find("*/", i + 2)
        if i < 0:
            sys.exit(2)
        i += 2
    elif c in "\"'":
        j, value = i + 1, []
        while j < n and text[j] != c:
            if text[j] == "\\":
                j += 1
            value.append(text[j : j + 1])
            j += 1
        tokens.append(("str", "".join(value)))
        i = j + 1
    elif c in "{}[]:,":
        tokens.append((c, c))
        i += 1
    elif c.isspace():
        i += 1
    else:
        j = i + 1
        while j < n and not text[j].isspace() and text[j] not in "{}[]:,\"'/":
            j += 1
        tokens.append(("word", text[i:j]))
        i = j

depth, extends = 0, None
for k, (kind, value) in enumerate(tokens):
    if kind in ("{", "["):
        depth += 1
    elif kind in ("}", "]"):
        depth -= 1
    elif depth == 1 and value == "extends" and [t[0] for t in tokens[k + 1 : k + 3]] == [":", "["]:
        extends, nested = [], 0
        for kind2, value2 in tokens[k + 3 :]:
            if kind2 in ("{", "["):
                nested += 1
            elif kind2 in ("}", "]"):
                if nested == 0:
                    break
                nested -= 1
            elif kind2 == "str" and nested == 0:
                extends.append(value2)
sys.exit(0 if extends and sys.argv[1] in extends else 1)

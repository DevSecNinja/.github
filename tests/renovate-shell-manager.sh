#!/usr/bin/env bash
#
# Checks the Renovate custom manager for `# renovate:` annotations in shell
# scripts (.renovate/customManagers.json5, "Process annotated versions in shell
# scripts"):
#
# - plain versions, images with a digest, optional annotation fields and
#   assignment keywords are extracted; non-literal values are not;
# - CRLF files match like LF files, for every annotation manager;
# - no annotated line is extracted by two managers, which would make Renovate
#   update the same value twice (the old dccd.sh SOPS manager is replaced).

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
custom_managers="${repo_root}/.renovate/customManagers.json5"

if ! command -v pyjson5 >/dev/null 2>&1; then
    echo "error: 'pyjson5' not found on PATH. Run via 'mise run test'." >&2
    exit 1
fi

MANAGERS="$(pyjson5 --as-json "${custom_managers}" | tr -d '\r')" python3 - <<'PY'
import json
import os
import re
import sys

managers = json.loads(os.environ["MANAGERS"])["customManagers"]
errors = []


def compile_js(pattern):
    # Renovate uses JavaScript named groups; Python spells them (?P<name>...).
    return re.compile(pattern.replace("(?<", "(?P<"))


shell = [m for m in managers if m["description"] == "Process annotated versions in shell scripts"]
if len(shell) != 1:
    print("error: expected one shell annotation manager", file=sys.stderr)
    sys.exit(1)
shell = shell[0]
if any(m["description"].startswith("Process SOPS version") for m in managers):
    errors.append("the dccd.sh SOPS manager duplicates the shell manager; remove it")
for m in managers:
    for p in m.get("matchStrings", []):
        # Renovate runs custom-manager regexes on RE2, which has no lookaround.
        if re.search(r"\(\?<?[=!]", p):
            errors.append(f"{m['description']}: lookaround is not supported by Renovate's RE2 engine")

patterns = [compile_js(s) for s in shell["matchStrings"]]
names = ("datasource", "depName", "currentValue", "currentDigest")
digest = "sha256:" + "4da1a4828be12604092fa55311276f08f9224a74a62dcb4708bd7439e2a03911"
gr = "# renovate: datasource=github-releases depName="
cases = {
    # DevSecNinja/dotfiles and truenas-apps tests/setup_libs.sh
    f'{gr}bats-core/bats-support\nBATS_SUPPORT_VERSION="v0.3.0"\n': ("github-releases", "bats-core/bats-support", "v0.3.0", None),
    f'{gr}bats-core/bats-assert\nBATS_ASSERT_VERSION="v2.1.0"\n': ("github-releases", "bats-core/bats-assert", "v2.1.0", None),
    # truenas-apps scripts/gha-backup-restore-test.sh
    f'# renovate: datasource=docker depName=docker.io/library/postgres\nPOSTGRES_IMAGE="docker.io/library/postgres:18.3-alpine@{digest}"\n':
        ("docker", "docker.io/library/postgres", "18.3-alpine", digest),
    f'# renovate: datasource=docker depName=docker.io/tiredofit/db-backup\nDB_BACKUP_IMAGE="docker.io/tiredofit/db-backup:4.1.100@{digest}"\n':
        ("docker", "docker.io/tiredofit/db-backup", "4.1.100", digest),
    # truenas-apps scripts/dccd.sh (was the SOPS manager), trailing comment
    f'{gr}getsops/sops\nSOPS_VERSION="v3.13.3" # SOPS version for secret decryption\n': ("github-releases", "getsops/sops", "v3.13.3", None),
    # Assignment keywords, quoting, indentation, end of file
    f'{gr}a/b\n    export A_VERSION=1.2.3\n': ("github-releases", "a/b", "1.2.3", None),
    f"{gr}a/b\n  local A_VERSION='1.2.3'\n": ("github-releases", "a/b", "1.2.3", None),
    f'{gr}a/b\nreadonly A_VERSION="1.2.3";\n': ("github-releases", "a/b", "1.2.3", None),
    f'{gr}a/b\ndeclare -r A_VERSION="1.2.3"': ("github-releases", "a/b", "1.2.3", None),
    # Debian epochs are kept, in every quoting form
    f'# renovate: datasource=deb depName=docker-ce\nDOCKER_CE="5:29.6.2-1~debian.13~trixie"\n': ("deb", "docker-ce", "5:29.6.2-1~debian.13~trixie", None),
    "# renovate: datasource=deb depName=docker-ce\nDOCKER_CE='5:29.6.2-1~debian.13~trixie'\n": ("deb", "docker-ce", "5:29.6.2-1~debian.13~trixie", None),
    "# renovate: datasource=deb depName=docker-ce\nDOCKER_CE=5:29.6.2-1~debian.13~trixie\n": ("deb", "docker-ce", "5:29.6.2-1~debian.13~trixie", None),
    # An image needs a path; a registry with a port works
    "# renovate: datasource=docker depName=redis\nREDIS_IMAGE=redis:7.4\n": None,
    "# renovate: datasource=docker depName=docker.io/library/redis\nREDIS_IMAGE=docker.io/library/redis:7.4\n": ("docker", "docker.io/library/redis", "7.4", None),
    f'# renovate: datasource=docker depName=registry.local:5000/team/app\nAPP="registry.local:5000/team/app:2.0.1@{digest}"\n':
        ("docker", "registry.local:5000/team/app", "2.0.1", digest),
    # Unquoted values end at a command separator
    f'{gr}a/b\nA_VERSION=1.2.3;\n': ("github-releases", "a/b", "1.2.3", None),
    f'{gr}a/b\nA_VERSION=1.2.3 && echo ok\n': ("github-releases", "a/b", "1.2.3", None),
    # Not plain literals, or not annotated: never matched
    f'{gr}a/b\nA_VERSION="1.2.3 ${{SUFFIX}}"\n': None,
    f'{gr}a/b\nA_VERSION="1.2.3"$SUFFIX\n': None,
    # A `#` that does not start a word is part of the value, not a comment
    f'{gr}a/b\nA_VERSION="1.2.3"#${{SUFFIX}}\n': None,
    f"{gr}a/b\nA_VERSION='1.2.3'#${{SUFFIX}}\n": None,
    f'{gr}a/b\nA_VERSION=1.2.3#${{SUFFIX}}\n': None,
    f'{gr}a/b\nA_VERSION=1.2.3 # pinned\n': ("github-releases", "a/b", "1.2.3", None),
    # Command substitution is not a literal
    f'# renovate: datasource=docker depName=registry.example/app\nAPP="registry.example/`get_image`:1.2.3"\n': None,
    f'# renovate: datasource=docker depName=registry.example/app\nAPP=registry.example/`get_image`:1.2.3\n': None,
    f'{gr}a/b\nA_VERSION="`cat VERSION`"\n': None,
    f'{gr}a/b\nA_VERSION=1.2.3$SUFFIX\n': None,
    f"{gr}a/b\nA_VERSION='1.2.3\"\n": None,
    f'{gr}a/b\nA_VERSION="${{OTHER_VERSION}}"\n': None,
    f'{gr}a/b\nA_VERSION="v1.2-$SUFFIX"\n': None,
    f'{gr}a/b\n\nA_VERSION="1.2.3"\n': None,
    'A_VERSION="1.2.3"\n': None,
}
for text, want in cases.items():
    for variant, label in ((text, "LF"), (text.replace("\n", "\r\n"), "CRLF")):
        # The quoted and unquoted patterns are exclusive: one line, one dep.
        matches = [m for m in (p.search(variant) for p in patterns) if m]
        if len(matches) > 1:
            errors.append(f"shell manager ({label}): {text!r} matched by {len(matches)} patterns")
        got = None if not matches else tuple(matches[0].groupdict().get(n) for n in names)
        if got != want:
            errors.append(f"shell manager ({label}): {text!r}: want {want}, got {got}")


def search(text):
    return next((m for m in (p.search(text) for p in patterns) if m), None)


m = search(f"# renovate: datasource=docker depName=app packageName=ghcr.io/o/app versioning=loose registryUrl=https://ghcr.io\nAPP=1.2\n")
if not m or (m["packageName"], m["versioning"], m["registryUrl"]) != ("ghcr.io/o/app", "loose", "https://ghcr.io"):
    errors.append(f"shell manager: optional annotation fields not captured: {m and m.groupdict()}")

file_patterns = [compile_js(p.strip("/")) for p in shell["managerFilePatterns"]]
for path, want in {
    "tests/setup_libs.sh": True,
    "scripts/dccd.sh": True,
    "home/dot_local/bin/executable_x.sh.tmpl": True,
    "tests/foo.bats": True,
    "a.bash": True,
    "README.md": False,
    "Makefile": False,
}.items():
    if any(p.search(path) for p in file_patterns) != want:
        errors.append(f"shell manager managerFilePatterns: {path} should {'' if want else 'not '}match")

# Every annotation manager matches CRLF files, and each annotated line is
# extracted by exactly one manager.
samples = {
    ".github/workflows/ci.yml": '      # renovate: datasource=github-releases depName=jdx/mise\n      version: "2026.10.19"\n',
    ".github/workflows/x.yml": f'      # renovate: datasource=docker depName=mcr.microsoft.com/devcontainers/base\n      source: "mcr.microsoft.com/devcontainers/base:debian-12@{digest}"\n',
    ".mise.toml": '# renovate: datasource=github-releases depName=jdx/mise\nmin_version = "2026.4.3"\n',
    "ansible/inventory/group_vars/all.yml": '  # renovate: datasource=github-releases depName=getsops/sops\n  sops_version: "v3.11.0"\n',
    "scripts/dccd.sh": f'{gr}getsops/sops\nSOPS_VERSION="v3.13.3"\n',
}
for path, text in samples.items():
    for variant, label in ((text, "LF"), (text.replace("\n", "\r\n"), "CRLF")):
        hits = []
        for m in managers:
            if not any(compile_js(p.strip("/")).search(path) for p in m["managerFilePatterns"]):
                continue
            if any(compile_js(s).search(variant) for s in m.get("matchStrings", [])):
                hits.append(m["description"])
        if len(hits) != 1:
            errors.append(f"{path} ({label}): expected exactly one manager to extract it, got {hits}")

if errors:
    print("error: Renovate shell annotation manager:\n  " + "\n  ".join(errors), file=sys.stderr)
    sys.exit(1)
print("Renovate shell annotation manager: OK")
PY

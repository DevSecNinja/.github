#!/usr/bin/env bash
#
# Prints the repository's tracked files of language $1, NUL-separated.
# Used by the language linters of .github/workflows/lint.yml, which run only
# when this lists a file.
#
# Generated and vendored paths are skipped: the excludes of the shared
# config-sync/files/dprint.json (Spec Kit output, APM-deployed agent files,
# node_modules and Python virtualenvs). tests/lint-scripts.sh fails when a
# dprint.json exclude is missing here.

set -eo pipefail

case "$1" in
python) patterns=('**/*.py' '**/*.pyi') ;;
# JavaScript, TypeScript, JSON and CSS: what Biome checks.
web)
    patterns=('**/*.js' '**/*.mjs' '**/*.cjs' '**/*.jsx' '**/*.ts' '**/*.mts' '**/*.cts' '**/*.tsx'
        '**/*.json' '**/*.jsonc' '**/*.css')
    ;;
# ESLint configs: Biome steps aside for repositories that lint with ESLint.
eslint) patterns=('**/eslint.config.*' '**/.eslintrc' '**/.eslintrc.*') ;;
powershell) patterns=('**/*.ps1' '**/*.psm1' '**/*.psd1') ;;
*)
    echo "::error::language-files.sh: unknown language '$1'" >&2
    exit 2
    ;;
esac

excludes=(
    '**/node_modules/**'
    'apm_modules/**'
    '.github/prompts/**'
    '.github/instructions/**'
    '.github/agents/**'
    '.github/chatmodes/**'
    '.claude/**'
    '.cursor/**'
    '.opencode/**'
    '.gemini/**'
    '.windsurf/**'
    '.kiro/**'
    '.agents/**'
    '.github/skills/**'
    '.specify/**'
    '.venv*/**'
)

pathspecs=()
for pattern in "${patterns[@]}"; do
    pathspecs+=(":(glob)${pattern}")
done
for pattern in "${excludes[@]}"; do
    pathspecs+=(":(glob,exclude)${pattern}")
done

git ls-files -z -- "${pathspecs[@]}"

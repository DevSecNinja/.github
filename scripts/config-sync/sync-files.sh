#!/usr/bin/env bash
#
# Copies the central config files (and templates) into the calling repository
# (job sync of .github/workflows/config-sync.yml).
# Env: SYNC_TEMPLATES, IGNORE_FILE, SOURCE_DIR.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
updated=0
source_sha=$(git -C .config-sync-source rev-parse HEAD)
echo "Source: DevSecNinja/.github @ ${source_sha}"
echo "source_sha=${source_sha}" >>"${GITHUB_OUTPUT}"

# Load ignore list (paths relative to repo root, one per line).
ignored=""
if [ -f "${IGNORE_FILE}" ]; then
    ignored=$(cat "${IGNORE_FILE}")
    echo "Loaded ignore list from ${IGNORE_FILE}:"
    while IFS= read -r line; do
        [ -z "${line}" ] && continue
        case "${line}" in \#*) continue ;; *) ;; esac
        echo "  - ${line}"
    done <<<"${ignored}"
fi

is_ignored() {
    local target="$1"
    local pattern trimmed
    [ -z "${ignored}" ] && return 1
    while IFS= read -r pattern; do
        trimmed="${pattern#"${pattern%%[![:space:]]*}"}"
        trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
        [ -z "${trimmed}" ] && continue
        case "${trimmed}" in \#*) continue ;; *) ;; esac
        if [ "${target}" = "${trimmed}" ]; then
            return 0
        fi
    done <<<"${ignored}"
    return 1
}

# Files APM owns in this repository are left alone:
# - paths APM deploys here (`deployed_files` in apm.lock.yaml);
# - files generated from a package (their `<!-- config-sync:
#   source=<owner/repo>` marker) that this repository installs
#   whole through APM, even when its pinned release doesn't ship
#   them, so a later APM upgrade isn't blocked by a config-sync
#   copy. Subpath pins (`virtual_path`) only own what they deploy;
# - files generated from this repository itself.
apm_managed=""
apm_sources=""
if [ -f apm.lock.yaml ]; then
    apm_managed=$(sed -n 's/^[[:space:]]*-[[:space:]]\{1,\}\([^:[:space:]]\{1,\}\)[[:space:]]*$/\1/p' apm.lock.yaml)
    apm_sources=$(awk '
        function flush() { if (repo != "" && !virtual) print tolower(repo); repo = ""; virtual = 0 }
        /^[^[:space:]-]/ { flush(); in_deps = ($0 ~ /^dependencies:/); next }
        !in_deps { next }
        /^- / { flush() }
        { line = $0; sub(/^- /, "  ", line) }
        line ~ /^  repo_url:/ { repo = line; sub(/^  repo_url:[[:space:]]*/, "", repo); sub(/[[:space:]].*/, "", repo) }
        line ~ /^  virtual_path:/ { virtual = 1 }
        END { flush() }
    ' apm.lock.yaml)
fi
self_repo=$(tr '[:upper:]' '[:lower:]' <<<"${GITHUB_REPOSITORY:-}")

apm_owner() {
    local dest="$1" src="$2" source
    if [ -n "${apm_managed}" ] && grep -Fxq -- "${dest}" <<<"${apm_managed}"; then
        echo "deployed by APM, see apm.lock.yaml"
        return 0
    fi
    source=$(sed -n 's/^<!-- config-sync: source=\([^[:space:]]*\) .*/\1/p;/^<!-- config-sync: /q' "${src}" | tr '[:upper:]' '[:lower:]')
    [ -n "${source}" ] || return 1
    if [ -n "${apm_sources}" ] && grep -Fxq -- "${source}" <<<"${apm_sources}"; then
        echo "${source} is installed whole through APM, see apm.lock.yaml"
        return 0
    fi
    if [ "${source}" = "${self_repo}" ]; then
        echo "generated from this repository"
        return 0
    fi
    return 1
}

# A template is not bootstrapped when the repository configures the tool in
# another file already: ruff.toml would take precedence over [tool.ruff] in
# pyproject.toml and silently replace its settings.
configured_elsewhere() {
    case "$1" in
    ruff.toml)
        if [ -e .ruff.toml ]; then
            echo ".ruff.toml"
            return 0
        fi
        if [ -f pyproject.toml ] && grep -Eq '^[[:space:]]*\[tool\.ruff[].]' pyproject.toml; then
            echo "[tool.ruff] in pyproject.toml"
            return 0
        fi
        ;;
    *) ;;
    esac
    return 1
}

sync_tree() {
    local kind="$1"     # "files" or "templates"
    local only="${2:-}" # optional: sync just this path
    local src_root="${SOURCE_DIR}/${kind}"

    if [ ! -d "${src_root}" ]; then
        echo "  (no ${kind} directory in central repo, skipping)"
        return
    fi

    # README.md inside templates/ is documentation, never synced.
    local find_args=()
    if [ "${kind}" = "templates" ]; then
        find_args=(-not -path "${src_root}/README.md")
    fi

    # shellcheck disable=SC2312 # src_root exists (checked above); find failures were never fatal.
    while IFS= read -r src; do
        local rel="${src#"${src_root}/"}"
        local dest="${rel}"
        local reason

        if [ -n "${only}" ] && [ "${dest}" != "${only}" ]; then
            continue
        fi

        # shellcheck disable=SC2310 # is_ignored only tests; its status is the answer.
        if is_ignored "${dest}"; then
            echo "  ⊘ ${dest} (ignored via ${IGNORE_FILE})"
            continue
        fi

        # shellcheck disable=SC2310 # apm_owner only tests; its status is the answer.
        if reason=$(apm_owner "${dest}" "${src}"); then
            echo "  ⊘ ${dest} (${reason})"
            continue
        fi

        if [ "${kind}" = "templates" ] && [ -e "${dest}" ]; then
            echo "  ✔ ${dest} already exists (templates are not overwritten)"
            continue
        fi

        # shellcheck disable=SC2310 # configured_elsewhere only tests; its status is the answer.
        if [ "${kind}" = "templates" ] && reason=$(configured_elsewhere "${dest}"); then
            echo "  ✔ ${dest} skipped: configured in ${reason}"
            continue
        fi

        mkdir -p "$(dirname "${dest}")"

        if [ -f "${dest}" ] && cmp -s "${src}" "${dest}"; then
            echo "  ✓ ${dest} is up to date"
            continue
        fi

        if [ -f "${dest}" ]; then
            echo "  ⬆ Updated ${dest}"
        else
            echo "  ➕ Added ${dest}"
        fi
        cp "${src}" "${dest}"
        updated=1
    done < <(find "${src_root}" -type f "${find_args[@]}")
}

echo "=== Syncing config files ==="
sync_tree files

if [ "${SYNC_TEMPLATES}" = "true" ]; then
    echo ""
    echo "=== Syncing template files (new files only) ==="
    sync_tree templates
else
    # The Renovate stub carries the org defaults, so every repo
    # gets one even without sync-templates.
    echo ""
    echo "=== Bootstrapping renovate.json5 (new file only) ==="
    sync_tree templates renovate.json5
fi

# renovate.json5 is repo-owned; only check that its top-level
# `extends` still pulls in the org defaults. The runner has no JSON5
# parser, so renovate-extends-preset.py tokenizes the file (strings,
# comments, brackets) with the Python standard library. Exit 0: preset
# extended.
extends_preset() {
    python3 "${script_dir}/renovate-extends-preset.py" "$1"
}
renovate_preset="github>DevSecNinja/.github//.renovate/default.json5"
# shellcheck disable=SC2310 # extends_preset only tests; its status is the answer.
if [ -f renovate.json5 ] && ! extends_preset "${renovate_preset}"; then
    echo "::warning file=renovate.json5,title=renovate.json5 does not extend the org preset::Add \"${renovate_preset}\" to extends and keep repo-specific rules below it. Without it the repo misses central Renovate changes. See https://github.com/DevSecNinja/.github/blob/main/config-sync/templates/README.md#renovatejson5"
fi

# Clean up the source checkout so it never lands in a PR.
rm -rf .config-sync-source

echo "updated=${updated}" >>"${GITHUB_OUTPUT}"

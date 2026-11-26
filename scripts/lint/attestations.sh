#!/usr/bin/env bash
#
# Verifies the GitHub artifact attestation of every image the repository pins
# from its owner's own GHCR namespace (ghcr.io/<owner>/...) in tracked dev
# container configs and Compose files, with `gh attestation verify`. The
# bundle is read from the registry (--bundle-from-oci), so the job needs no
# permission beyond contents: read, and the images must be attested with
# push-to-registry: true (docs/artifact-attestations.md). Third-party images
# are out of scope: few of them publish attestations.
# A step of .github/workflows/lint.yml, run the same way in both lint modes.
# Env: GITHUB_REPOSITORY_OWNER, GH_TOKEN, LINT_ATTESTATIONS_BLOCKING (true:
# errors, fail; false: warnings only).

set -euo pipefail
export LC_ALL=C

blocking="${LINT_ATTESTATIONS_BLOCKING:-false}"
case "${blocking}" in
true) level=error ;;
false) level=warning ;;
*)
    echo "::error::lint-attestations-blocking must be true or false (got '${blocking}')."
    exit 2
    ;;
esac
owner="${GITHUB_REPOSITORY_OWNER:?GITHUB_REPOSITORY_OWNER is not set}"
namespace="ghcr.io/$(tr '[:upper:]' '[:lower:]' <<<"${owner}")"

# Escapes the message of a workflow command, and (escape_property) a
# property value such as file=....
escape_data() {
    local value="$1"
    value="${value//%/%25}"
    value="${value//$'\r'/%0D}"
    value="${value//$'\n'/%0A}"
    printf '%s' "${value}"
}
escape_property() {
    local value
    value="$(escape_data "$1")"
    value="${value//:/%3A}"
    value="${value//,/%2C}"
    printf '%s' "${value}"
}

# A file, not a process substitution: `set -e` then stops on a failing
# `git ls-files` instead of passing with nothing to check.
listing="$(mktemp)"
pins="$(mktemp)"
output="$(mktemp)"
trap 'rm -f "${listing}" "${pins}" "${output}"' EXIT
git ls-files -z -- ':(glob)**/devcontainer.json' ':(glob)**/.devcontainer.json' \
    ':(glob)**/compose*.yml' ':(glob)**/compose*.yaml' \
    ':(glob)**/docker-compose*.yml' ':(glob)**/docker-compose*.yaml' >"${listing}"

# The image values the files pin, parsed (JSONC and YAML, any layout, anchors
# and Compose merge tags resolved; comments never count), as NUL-separated
# "<path>", "<image>" pairs, so any file name is safe; "<path>", "!<reason>"
# for a file that can't be parsed.
/usr/bin/python3 "$(dirname "${BASH_SOURCE[0]}")/attestation-images.py" <"${listing}" >"${pins}"

# The reference to verify for an image value; empty when a variable leaves it
# unresolved. With a digest the tag is informational: verify the digest itself.
resolve() {
    local value="$1" name digest base last
    if [[ "${value}" =~ @(sha256:[0-9a-f]{64})$ ]]; then
        digest="${BASH_REMATCH[1]}"
        name="${value%@*}"
        base="${name%/*}" last="${name##*/}"
        name="${base}/${last%%:*}"
        [[ "${name}" == *'$'* ]] || printf '%s@%s' "${name}" "${digest}"
    elif [[ "${value}" != *'$'* ]]; then
        printf '%s' "${value}"
    fi
}

# The first file that pins each value, in a stable order.
declare -A first_file=()
values=()
unreadable_paths=()
unreadable_reasons=()
while IFS= read -r -d '' path && IFS= read -r -d '' value; do
    if [[ "${value}" == '!'* ]]; then
        unreadable_paths+=("${path}")
        unreadable_reasons+=("${value#!}")
        continue
    fi
    [[ "$(tr '[:upper:]' '[:lower:]' <<<"${value}")" == "${namespace}/"* ]] || continue
    [ -z "${first_file[${value}]+set}" ] || continue
    first_file["${value}"]="${path}"
    values+=("${value}")
done <"${pins}"

if [ "${#values[@]}" -eq 0 ] && [ "${#unreadable_paths[@]}" -eq 0 ]; then
    echo "✓ No ${namespace}/ image is pinned in a dev container or Compose file."
    exit 0
fi

failed=0
for i in "${!unreadable_paths[@]}"; do
    failed=$((failed + 1))
    path="${unreadable_paths[${i}]}"
    echo "::${level} file=$(escape_property "${path}"),title=Unreadable file::$(escape_data "${path}") can't be parsed ($(escape_data "${unreadable_reasons[${i}]}")), so its images can't be checked."
done
declare -A verified=()
for value in "${values[@]}"; do
    path="${first_file[${value}]}"
    # Values come from repository files: one with whitespace or a control
    # character isn't an image reference, and must not reach a log command.
    if [[ "${value}" == *[[:space:][:cntrl:]]* ]]; then
        failed=$((failed + 1))
        echo "::${level} file=$(escape_property "${path}"),title=Invalid image::$(escape_data "${value}") is not a valid image reference."
        continue
    fi
    ref="$(resolve "${value}")"
    if [ -z "${ref}" ]; then
        failed=$((failed + 1))
        echo "::${level} file=$(escape_property "${path}"),title=Unresolved image::$(escape_data "${value}") uses a variable, so the image it pulls can't be verified. Pin a literal digest (name@sha256:…)."
        continue
    fi
    [ -z "${verified[${ref}]+set}" ] || continue
    verified["${ref}"]=1
    if gh attestation verify "oci://${ref}" --owner "${owner}" --bundle-from-oci >"${output}" 2>&1; then
        echo "✓ ${ref} is attested by a ${owner} workflow."
        continue
    fi
    failed=$((failed + 1))
    echo "::group::gh attestation verify oci://$(escape_data "${ref}")"
    cat "${output}"
    echo "::endgroup::"
    # The job has no registry login (it would need packages: read from every
    # caller), so a private image can't be read; that is not a missing attestation.
    if grep -Eiq 'unauthorized|denied|authentication required|\b40[13]\b' "${output}"; then
        echo "::${level} file=$(escape_property "${path}"),title=Unreadable image::$(escape_data "${ref}") can't be read from the registry without a login (a private image?), so its attestation can't be checked."
    else
        echo "::${level} file=$(escape_property "${path}"),title=Unattested image::$(escape_data "${ref}") has no GitHub artifact attestation from a ${owner} workflow in the registry."
    fi
done

[ "${failed}" -gt 0 ] || exit 0
echo "::${level} title=Unattested image::${failed} of $((${#values[@]} + ${#unreadable_paths[@]})) pinned ${namespace}/ image(s) or file(s) failed attestation verification. Pin a literal digest that the publishing workflow attested with actions/attest and push-to-registry: true (docs/artifact-attestations.md in DevSecNinja/.github)."
[ "${blocking}" = false ] || exit 1

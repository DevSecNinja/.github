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
# resolved; comments never count): "<path>\t<image>", or "<path>\t!<reason>"
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
unreadable=()
while IFS=$'\t' read -r path value; do
    if [[ "${value}" == '!'* ]]; then
        unreadable+=("${path}"$'\t'"${value#!}")
        continue
    fi
    [[ "$(tr '[:upper:]' '[:lower:]' <<<"${value}")" == "${namespace}/"* ]] || continue
    [ -z "${first_file[${value}]+set}" ] || continue
    first_file["${value}"]="${path}"
    values+=("${value}")
done <"${pins}"

if [ "${#values[@]}" -eq 0 ] && [ "${#unreadable[@]}" -eq 0 ]; then
    echo "✓ No ${namespace}/ image is pinned in a dev container or Compose file."
    exit 0
fi

failed=0
for entry in "${unreadable[@]}"; do
    failed=$((failed + 1))
    echo "::${level} file=$(escape_property "${entry%%$'\t'*}"),title=Unreadable file::$(escape_data "${entry%%$'\t'*}") can't be parsed ($(escape_data "${entry#*$'\t'}")), so its images can't be checked."
done
declare -A verified=()
for value in "${values[@]}"; do
    path="${first_file[${value}]}"
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
    echo "::group::gh attestation verify oci://${ref}"
    cat "${output}"
    echo "::endgroup::"
    echo "::${level} file=$(escape_property "${path}"),title=Unattested image::$(escape_data "${ref}") has no GitHub artifact attestation from a ${owner} workflow in the registry."
done

[ "${failed}" -gt 0 ] || exit 0
echo "::${level} title=Unattested image::${failed} of $((${#values[@]} + ${#unreadable[@]})) pinned ${namespace}/ image(s) or file(s) failed attestation verification. Pin a literal digest that the publishing workflow attested with actions/attest and push-to-registry: true (docs/artifact-attestations.md in DevSecNinja/.github)."
[ "${blocking}" = false ] || exit 1

#!/usr/bin/env bash
#
# Writes the release notes for TAG to /tmp/release-notes.md (actions/release-publish,
# step "Generate release notes"): git-cliff's notes for the latest tag, plus the
# notes block of the EXTRA preset, if any. RELEASE_NOTES_FILE overrides the path
# for tests.

set -euo pipefail

notes_file="${RELEASE_NOTES_FILE:-/tmp/release-notes.md}"

# Always: --latest (just this tag's slice) + --strip all (no header,
# no footer, no version heading — pure body suitable for a Release).
mise exec -- git-cliff --latest --strip all >"${notes_file}"

case "${EXTRA}" in
"") ;;
log-sh)
    # shellcheck disable=SC2016 # Backticks are Markdown, not command substitution.
    {
        printf '\n---\n\n'
        printf '## log.sh distribution\n\n'
        printf 'This release includes a vendorable copy of `log.sh`. See '
        printf '[docs/logging.md](https://github.com/%s/blob/%s/docs/logging.md#consuming-logsh-from-other-repositories) ' \
            "${REPO}" "${TAG}"
        printf 'for the consumption snippet.\n\n'
        printf '```sh\n'
        printf 'curl -fsSL https://github.com/%s/releases/download/%s/log.sh -o scripts/lib/log.sh\n' \
            "${REPO}" "${TAG}"
        printf 'curl -fsSL https://github.com/%s/releases/download/%s/log.sh.sha256 -o scripts/lib/log.sh.sha256\n' \
            "${REPO}" "${TAG}"
        printf '( cd scripts/lib && sha256sum -c log.sh.sha256 )\n'
        printf '```\n\n'
        printf '### Verifying provenance\n\n'
        printf 'Each binary asset is attested via [GitHub Artifact Attestations](https://docs.github.com/actions/security-guides/using-artifact-attestations-to-establish-provenance-for-builds). '
        printf 'Verify with the GitHub CLI:\n\n'
        printf '```sh\n'
        printf 'gh attestation verify ./log.sh --repo %s\n' "${REPO}"
        printf 'gh attestation verify ./log-sh-%s.tar.gz --repo %s\n' "${TAG}" "${REPO}"
        printf '```\n'
    } >>"${notes_file}"
    ;;
*)
    printf 'Unknown extra-notes preset: %s\n' "${EXTRA}" >&2
    exit 1
    ;;
esac

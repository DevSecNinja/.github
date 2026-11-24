# Artifact attestations

How `DevSecNinja/*` repos prove where a published artifact came from. We
use GitHub's native [artifact attestations][gh-docs]: keyless Sigstore
signing through the workflow's OIDC token, stored in the GitHub
attestations API and checked with `gh attestation verify`. No cosign
keys, no extra tooling, and only first-party actions.

[gh-docs]: https://docs.github.com/actions/security-guides/using-artifact-attestations-to-establish-provenance-for-builds

## When to attest

Attest every artifact that someone else downloads, pulls or installs:

- container images pushed to GHCR;
- release assets (binaries, archives, installers, scripts);
- SBOMs that ship next to those assets (as an SBOM attestation).

Don't attest:

- **Sites** (GitHub Pages, Cloudflare Pages, Azure Static Web Apps).
  Nothing checks an attestation when a browser loads a page, so it costs
  minutes for no verifier.
- **Mirrors of upstream images.** We didn't build them; a provenance
  statement from our workflow would be misleading.
- **Notes-only releases.** There is no file to attest.
- **Private repos.** Attestations need GitHub Enterprise Cloud for
  private repos, so on our plan they're public-repo only. Use sha256
  checksums and immutable releases instead.

## Where the step goes

Put the attest step **in the caller's job, right after the build**, not
in a reusable workflow. Attestations made inside a reusable workflow are
signed by `DevSecNinja/.github`, so every verifier would need
`--signer-repo DevSecNinja/.github`. That's also why
[`release-publish`](../actions/release-publish/README.md) only publishes
the release and leaves attestation to the caller.

Use [`actions/attest`][attest] for everything: it writes SLSA build
provenance by default and an SBOM attestation when you pass `sbom-path`.
`actions/attest-build-provenance` is a thin wrapper around it and is
fine to keep where it's already in use.

[attest]: https://github.com/actions/attest

The job needs these permissions (keep the workflow default at
`permissions: {}` or `contents: read`):

```yaml
permissions:
  contents: read         # or write, when the same job creates the release
  id-token: write        # mint the OIDC token for the Sigstore certificate
  attestations: write    # store the attestation for this repo
```

Images pushed with `push-to-registry: true` also need `packages: write`
and `artifact-metadata: write` (the storage record that links the image
to the attestation).

## Release assets

Build, attest, then publish with `release-publish` in the same job:

```yaml
- name: Attest release assets
  uses: actions/attest@1e69f48acb82d1966a394da916b4c1698aa569d6 # v4.2.2
  with:
    subject-path: |
      dist/tool-${{ github.ref_name }}-linux-x64.tar.gz
      dist/tool-${{ github.ref_name }}-windows-x64.zip
```

List paths explicitly, the same way `release-publish` takes its
`assets`. Don't attest the `.sha256` sidecars; they're derived from the
files that are attested.

Verify, naming the workflow that publishes the asset:

```sh
gh attestation verify tool-v1.2.3-linux-x64.tar.gz --repo DevSecNinja/<repo> \
    --signer-workflow DevSecNinja/<repo>/.github/workflows/release.yml
```

## Container images

Attest the digest that was pushed, and push the attestation to the
registry so it travels with the image:

```yaml
- name: Log in to GHCR
  uses: docker/login-action@<sha> # vX.Y.Z
  with:
    registry: ghcr.io
    username: ${{ github.actor }}
    password: ${{ secrets.GITHUB_TOKEN }}

- name: Build and push
  id: push
  uses: docker/build-push-action@<sha> # vX.Y.Z
  with:
    push: true
    tags: ghcr.io/devsecninja/<image>:${{ github.sha }}

- name: Attest image
  uses: actions/attest@1e69f48acb82d1966a394da916b4c1698aa569d6 # v4.2.2
  with:
    subject-name: ghcr.io/devsecninja/<image>
    subject-digest: ${{ steps.push.outputs.digest }}
    push-to-registry: true
```

- `subject-name` is the image name without a tag, lowercased.
- For a multi-arch image, attest the **manifest list** digest after the
  merge step, not each per-platform digest. Consumers pin the list.
- Attest every push that consumers may pin, including `latest` and
  scheduled rebuilds, not only release tags. An unattested digest can't
  be told apart from one pushed by someone else.
- BuildKit's `provenance:` and `sbom:` options write unsigned
  attestations. They're useful metadata but prove nothing about who
  built the image; keep the signed attestation as the source of truth.

Verify:

```sh
gh attestation verify oci://ghcr.io/devsecninja/<image>@sha256:<digest> --owner DevSecNinja \
    --signer-workflow DevSecNinja/<repo>/.github/workflows/<workflow>.yml
```

## SBOMs

When a release ships an SBOM, attest it against the artifact it
describes:

```yaml
- name: Attest SBOM
  uses: actions/attest@1e69f48acb82d1966a394da916b4c1698aa569d6 # v4.2.2
  with:
    subject-path: dist/tool-${{ github.ref_name }}-windows-x64.zip
    sbom-path: dist/tool-${{ github.ref_name }}-windows-x64.cdx.json
```

Verify with the predicate type of the SBOM format:

```sh
gh attestation verify tool-v1.2.3-windows-x64.zip --repo DevSecNinja/<repo> \
    --signer-workflow DevSecNinja/<repo>/.github/workflows/release.yml \
    --predicate-type https://cyclonedx.org/bom   # or https://spdx.dev/Document/v2.3
```

## Why `--signer-workflow`

`--owner DevSecNinja` or `--repo DevSecNinja/<repo>` alone accepts an
attestation from any workflow in that owner or repo.
`--signer-workflow` also pins the workflow that built the artifact, so a
compromised unrelated workflow can't vouch for it. Use it whenever you
know the publishing workflow, as in the examples above:

```sh
gh attestation verify oci://ghcr.io/devsecninja/dotfiles-devcontainer:v0.6.0 \
    --repo DevSecNinja/dotfiles \
    --signer-workflow DevSecNinja/dotfiles/.github/workflows/devcontainer-prebuild.yaml
```

## Examples in the fleet

- `DevSecNinja/note-iq` `release.yml`: release zips with provenance and
  CycloneDX SBOM attestations.
- `DevSecNinja/dotfiles` `release.yml`: attests the script assets in the
  caller, uploads them to the release-please draft and publishes it with
  `gh release`.
- `DevSecNinja/dotfiles` `devcontainer-prebuild.yaml`: multi-arch image
  with `push-to-registry: true`.

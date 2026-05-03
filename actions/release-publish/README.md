# `release-publish` composite action

Generate Conventional-Commit release notes via [git-cliff][cliff] and
publish a single-shot, [Immutable-Releases][imm]–compatible GitHub
Release. Optional asset upload and preset notes blocks.

[cliff]: https://git-cliff.org/
[imm]: https://docs.github.com/repositories/releasing-projects-on-github/about-releases#immutable-releases

## Why a composite action (and not a reusable workflow)?

Reusable workflows run with the OIDC subject of _the workflow file's
repository_. That breaks `actions/attest-build-provenance` when the
attestation needs to verify against the _caller's_ repo. Composite
actions run inside the caller's job, inheriting its OIDC subject —
which is what consumers expect when they run
`gh attestation verify ... --repo <owner>/<caller-repo>`.

Move the build + attestation steps into the caller, then call this
action to publish.

## Inputs

| Name           | Required | Default               | Description                                                                |
| -------------- | -------- | --------------------- | -------------------------------------------------------------------------- |
| `mise-version` | yes      | —                     | mise version to install. Used to provision `git-cliff`.                    |
| `tag`          | yes      | —                     | Git tag (e.g. `v1.2.0`). Usually `${{ github.ref_name }}`.                 |
| `assets`       | no       | `""`                  | Newline-delimited list of file paths to attach. No globbing — be explicit. |
| `extra-notes`  | no       | `""`                  | Preset key for an appended notes block. See [Presets](#presets).           |
| `github-token` | no       | `${{ github.token }}` | Token used by `gh release create`.                                         |

## Presets

| Key      | Effect                                                                                |
| -------- | ------------------------------------------------------------------------------------- |
| `""`     | No extra notes (default).                                                             |
| `log-sh` | Appends the standard `log.sh` consumption snippet + attestation-verification snippet. |

Add new presets here when a recurring asset-distribution pattern shows up
in two or more repos.

## Caller responsibilities

- Check out the repo _before_ calling this action (`actions/checkout` with
  `fetch-depth: 0` so `git-cliff` can see history).
- Set job permissions yourself: at minimum `contents: write`. Add
  `id-token: write` and `attestations: write` if you also call
  `actions/attest-build-provenance` in the same job.
- Build any artifacts and call `attest-build-provenance` _before_ this
  action so the attestation is bound to the caller's OIDC.

## Example — notes-only release

```yaml
name: Release
on: { push: { tags: ['v*'] } }
permissions: { contents: read }

jobs:
  release:
    runs-on: ubuntu-24.04
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@v6
        with: { fetch-depth: 0, persist-credentials: false }
      - uses: DevSecNinja/.github/actions/release-publish@<sha>
        with:
          mise-version: "2026.4.9"
          tag: ${{ github.ref_name }}
```

## Example — assets + attestations + preset notes

```yaml
name: Release
on: { push: { tags: ['v*'] } }
permissions: { contents: read }
concurrency:
  group: release-${{ github.ref }}
  cancel-in-progress: false

jobs:
  release:
    runs-on: ubuntu-24.04
    permissions:
      contents: write
      id-token: write
      attestations: write
    steps:
      - uses: actions/checkout@v6
        with: { fetch-depth: 0, persist-credentials: false }

      - name: Build artifacts
        run: ./script/build-log-sh-release.sh "${{ github.ref_name }}" dist

      - uses: actions/attest-build-provenance@v4
        with:
          subject-path: |
            dist/log.sh
            dist/log-sh-${{ github.ref_name }}.tar.gz

      - uses: DevSecNinja/.github/actions/release-publish@<sha>
        with:
          mise-version: "2026.4.9"
          tag: ${{ github.ref_name }}
          extra-notes: log-sh
          assets: |
            dist/log.sh
            dist/log.sh.sha256
            dist/log-sh-${{ github.ref_name }}.tar.gz
            dist/log-sh-${{ github.ref_name }}.tar.gz.sha256
```

## Pitfalls baked in

These are the lessons captured in `DevSecNinja/dotfiles`'s
`commit-and-release` skill — encoded into the composite so consumers don't
have to re-learn them:

- **`gh release create` is single-shot.** Notes, title, and all assets go
  in one call. No later `gh release upload --clobber` or
  `gh release edit` (rejected on Immutable-Releases repos).
- **`git-cliff` is invoked with `--latest --strip all`** for fleet-wide
  consistency. Don't override per-repo.
- **Attestation must stay in the caller**, never inside this action.
- **Asset list is literal, not globbed**, so the audit trail is the YAML.

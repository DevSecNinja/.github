# ADR 0006: Deploy prebuilt artifacts instead of passing credentials into builds

## Status

Accepted

## Context

Some sites deployed through the shared `pages.yml` workflow are generated from
data that is not in the repository — for example a static site built from
published GitHub Issues. Those builds need an authenticated GitHub API call at
build time, and `pages.yml` exposes no credentials to `build-command`.

The obvious fix is to add a token secret that the workflow exports for the build
step. That is uncomfortable, because `pages.yml` runs `build-command` in three
jobs, and one of them — `deploy-preview` — checks out and builds the **pull
request head**, i.e. code a contributor controls. Handing a token to a build
command is handing it to arbitrary code, and Actions secret masking does not
stop a build script from transforming a value it can read. Any such input has to
arrive with a careful, easily-forgotten set of caveats about which jobs it
applies to.

There is a more general problem behind it. `pages.yml` already carries
`node-version`, `node-cache`, `go-version`, `go-version-file`, `install-command`,
`test-setup-command`, `test-command` and `build-command`. Every build need that
the workflow does not anticipate becomes another input and another pull request
against this repository. The genuinely reusable part of the workflow is
*deploying a directory* to GitHub Pages and Cloudflare Pages, including project
creation, preview lifecycle, PR comments and environment wiring. Building is the
part that varies per repository.

## Decision

Add an optional `artifact-name` input. When set, the deploy jobs download that
artifact into `artifact-path` and deploy it as-is, skipping Node/Go setup,
`install-command` and `build-command`. `artifact-name` and `build-command` are
mutually exclusive and validated as such.

Callers whose build needs credentials or unusual tooling run it in their own job
— where they already control permissions, secrets and environment — upload the
result, and have the `uses:` job `needs:` that build job.

**No credential is ever passed into this workflow for the purpose of running
caller build code.** Artifacts are scoped to a workflow run, and a reusable
workflow's jobs are part of the caller's run, so the handover needs no extra
permissions and no token.

`build-command` mode is unchanged and remains the simple path for builds that
need nothing beyond Node/Go.

## Alternatives considered

- **A `BUILD_GITHUB_TOKEN` secret exported to the build step.** The first
  attempt. Workable if restricted to the production-branch jobs and never
  exposed to previews or the test job, but it puts the security of the caller's
  credential in this workflow's control flow, where a later refactor could
  quietly widen it. Rejected once `artifact-name` made it unnecessary: keeping
  both would leave a second, riskier way to do the same job.
- **A generic `build-env` string input.** Rejected: an arbitrary key/value
  string cannot be masked by Actions secret masking and invites callers to pass
  secrets through a plain input.
- **Keep adding per-need inputs (more toolchains, more env).** Rejected: it
  grows the shared interface without bound and couples every caller's build
  requirements to this repository's release cycle.
- **Let callers fetch data and commit it.** Rejected: bot commits on every
  content change, and it couples content updates to git history.
- **Unauthenticated API calls from the build.** Rejected: the 60 requests/hour
  per-IP limit is shared across GitHub-hosted runners.

## Consequences

- The build/deploy boundary is explicit. This workflow's contract becomes "give
  me a directory, or a command that produces one, and I will deploy it".
- Callers using `artifact-name` take on a little more boilerplate: an upload
  step and a `needs:`.
- The same artifact is deployed to previews and to production. A caller that
  wants previews built without credentials must branch on `github.event_name`
  in its own build job. That decision now lives in the caller's workflow, where
  it is visible, rather than being an implicit property of this one.
- `actions/upload-artifact` v4+ omits hidden files unless
  `include-hidden-files: true` is set, which matters for `.well-known`,
  `.nojekyll` and similar. Documented in `docs/architecture.md`.
- Artifact upload and download add roughly 10–20 seconds per deploy.

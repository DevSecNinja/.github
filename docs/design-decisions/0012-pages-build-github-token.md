# ADR 0012: Build with the read-only workflow token in the Pages test job

## Status

Accepted. Narrows the rejected-alternatives section of
[ADR 0006](0006-prebuilt-artifact-deploys.md).

## Context

Sites that call the GitHub API at build time (for example a snapshot of a
user's public repositories) fail on the unauthenticated 60 requests/hour limit,
which is shared across GitHub-hosted runners. ADR 0006 solved credentialed
builds by having the caller build in its own job and hand over an artifact. That
works, but every caller then needs its own checkout, Node setup, install, build
and upload steps, plus the extra action pins Renovate has to keep current.

ADR 0006 rejected exporting a token to the build step because the deploy jobs
hold write permissions (`deployments`, `pages`, `pull-requests`, `issues`,
`id-token`) and `deploy-preview` builds pull request head code.

## Decision

Add an opt-in `build-github-token` input (default `false`). When set together
with `build-command`:

- `build-command` runs once, in the `test` job, which already has only
  `contents: read` and already runs the pull request's own code.
- That step receives `GITHUB_TOKEN` (`github.token`). Public data needs no
  permission, so a `contents: read` token is enough to lift the rate limit.
- The built `artifact-path` is uploaded as `pages-build-<cloudflare-project-name
  or site>`; the deploy jobs download it instead of building.

No deploy job ever exposes a token to build code. No caller-supplied secret is
involved, so nothing here widens a credential's reach.

## Consequences

- Callers keep a one-line change instead of a build job and three extra action
  pins; those pins stay in this repository.
- The build uses the test job's package-manager cache setting (`node-cache`),
  not the cache-free configuration of the deploy jobs.
- As with `artifact-name`, previews and production deploy the same artifact.
- A caller that needs a credential beyond `contents: read` should still use
  `artifact-name`.

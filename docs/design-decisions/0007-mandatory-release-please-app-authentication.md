# ADR 0007: Require GitHub App authentication for Release Please

## Status

Accepted

## Context

GitHub suppresses downstream workflow runs for events created with a
repository's `GITHUB_TOKEN`. A Release Please caller that supplied an
empty App ID could therefore fall back silently, open a release PR
without its required CI, and create a tag that did not trigger the
repository's publisher.

The central onboarding contract already requires the Release Please
GitHub App installation, an App ID, a private key, and the repository
setting that allows Actions to create and approve pull requests. All
known callers supply the corresponding variable and secret. Keeping a
fallback provides no supported capability and hides broken onboarding.

Repositories publish in two ways. Some let Release Please create the
GitHub Release directly. Others let Release Please create only the tag
and hand publication, assets, and attestations to a tag-triggered
workflow. Both depend on App-authenticated events.

## Decision

The central Release Please reusable workflow requires `app-id` and
`app-private-key`. It validates that neither value is empty or
whitespace-only before minting a token. The App token action is
unconditional after that preflight, and Release Please receives only
the minted App token. There is no `GITHUB_TOKEN` fallback.

The App token and release job retain only Contents and Pull requests
write permissions; Metadata read access is automatic. Every caller must
also enable **Allow GitHub Actions to create and approve pull requests**
in repository Actions settings.

Two publication patterns are supported:

1. **Direct Release Please GitHub Release:** set
   `skip-github-release: false` and do not configure a competing tag
   publisher. This is the default for simple consumers.
2. **Split tag publisher:** set `skip-github-release: true` and publish
   from a workflow triggered by `push` on version tags. Release Please
   still creates the tag; this option skips only formal Release
   creation. Use it only for assets, attestations, custom notes, or
   other publication work.

## Consequences

- Misconfigured callers fail before Release Please can mutate repository
  state.
- Release PRs run normal pull-request CI, and version tags can trigger
  split publishers reliably.
- Adopting the central workflow requires the App installation, both
  credentials, and the Actions PR-creation setting.
- Making previously optional inputs required is a breaking reusable
  workflow contract change and requires a major central release.
- Consumer repositories do not need edits before that release because
  all currently discovered callers already pass both credentials.

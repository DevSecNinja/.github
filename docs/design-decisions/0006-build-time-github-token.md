# ADR 0006: Build-time GitHub token for Pages, production builds only

## Status

Accepted

## Context

Some sites deployed through the shared `pages.yml` workflow are generated from
data that lives in the GitHub API rather than in the repository — for example a
static site whose content is built from published GitHub Issues. Those builds
need an authenticated GitHub API call at build time.

`pages.yml` runs the caller-supplied `build-command` in three different jobs:

- `deploy` (GitHub Pages) — runs only on the production branch.
- `deploy-cloudflare` (production / acceptance) — runs only on the production
  branch.
- `deploy-preview` (Cloudflare PR previews) — checks out and builds the
  **pull request head**, i.e. code that a contributor can change in the PR.

Handing a token to a build command is handing it to arbitrary code. In the
preview job that code is attacker-controlled from the moment a PR is opened
(the job is already restricted to same-repository PRs and non-bot actors, but
that still includes anyone who can push a branch). A token exposed there could
be exfiltrated, and workflow secret masking does not prevent a build script from
transforming and leaking a value it can read.

## Decision

Add an **optional** `BUILD_GITHUB_TOKEN` secret to `pages.yml`, subject to four
constraints:

1. **Opt-in.** Callers that do not pass the secret see no behaviour change, and
   no `GITHUB_TOKEN` variable is set at all — the build step exports it only
   when the value is non-empty, so a build never receives an empty token.
2. **Production builds only.** It is exposed to the `build-command` step of the
   `deploy` and `deploy-cloudflare` jobs, which run exclusively on the
   production branch and therefore build reviewed, merged code. It is *not*
   exposed to `deploy-preview` or to the `test` job.
3. **Step-scoped.** It is set as `env:` on the single build step rather than
   written to `$GITHUB_ENV`, so later steps in the same job (including the
   Wrangler deploy) never see it.
4. **Caller-scoped privileges.** The workflow does not mint or widen a token of
   its own. The caller passes one explicitly — typically `${{ github.token }}`
   narrowed by its own `permissions:` block (e.g. `issues: read`).

## Alternatives considered

- **Expose the token in every job, including previews.** Rejected: it would put
  a repository token in the hands of unreviewed pull request code.
- **A generic `build-env` string input.** Rejected: an arbitrary key/value
  string cannot be masked by Actions secret masking, invites callers to smuggle
  secrets through a plain input, and is far harder to reason about than one
  named, purpose-built secret.
- **Always set `GITHUB_TOKEN` from the secret, empty when absent.** Rejected:
  an empty-but-set `GITHUB_TOKEN` changes the behaviour of tools that check
  only for the variable's presence.
- **Write the token to `$GITHUB_ENV`.** Rejected: it would leak into every
  subsequent step of the job for no benefit.
- **Let callers fetch data in their own workflow and commit it.** Rejected as a
  general answer: it produces bot commits on every content change and couples
  content updates to the git history.
- **Unauthenticated GitHub API calls from the build.** Rejected: the 60
  requests/hour per-IP limit is shared across GitHub-hosted runners.

## Consequences

- Pull request previews build without a token. Sites that need API data must
  fall back to committed fixture data in previews, which keeps preview builds
  hermetic but means a preview can show slightly stale or sample content.
- Only production-branch builds can reach the GitHub API, so a build-time API
  regression is not caught until merge. Callers should keep the fixture-based
  path exercised by their test suite.
- The blast radius of a compromised build script on the production branch now
  includes the caller-scoped token; callers must keep their `permissions:`
  block minimal.

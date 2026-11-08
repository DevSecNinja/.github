# ADR 0011: One GitHub App for every central automation that opens pull requests

## Status

Accepted. Amends [ADR 0007](0007-mandatory-release-please-app-authentication.md)
(credential names and the Actions PR-creation setting).

## Context

Three central workflows push branches and open pull requests in consuming
repositories: Config Sync, Release Please and APM Sync. Only Release Please
and APM authenticated with a GitHub App — the **DevSecNinja Automation** App
(ID `3563533`), stored per repository as `RELEASE_PLEASE_APP_ID` /
`RELEASE_PLEASE_APP_PRIVATE_KEY` (12 repositories). Config Sync used
`GITHUB_TOKEN`.

Two problems followed:

- Config Sync failed in 42 of the 61 repositories that ran it with
  `GitHub Actions is not permitted to create or approve pull requests`,
  because those repositories keep _Allow GitHub Actions to create and approve
  pull requests_ off. Enabling it everywhere would also let any workflow
  approve pull requests, and the PRs `GITHUB_TOKEN` opens still would not run
  CI.
- The reusable Config Sync requested `issues: write` (for its label) since
  v2.2.0, which made every caller that granted only `contents` and
  `pull-requests` fail with `startup_failure`.

Meanwhile the `GitHubRepoConfig` module in DevSecNinja/dotfiles provisions one
App credential under standard names — variable `AUTOMATION_APP_ID`, secret
`AUTOMATION_APP_PRIVATE_KEY` — from 1Password into every repository, inside an
Actions environment `production` pinned to the default branch on public
repositories and at repository level on private ones (GitHub Free has no
private environments).

## Decision

Every central workflow that opens pull requests authenticates as the
DevSecNinja Automation App through one shared contract:

1. **Credential resolution.** The App ID comes from the `app-id` input, else
   the caller repository's `AUTOMATION_APP_ID` variable (in a reusable
   workflow `vars` refers to the caller). The private key comes from the
   `app-private-key` secret, else the `AUTOMATION_APP_PRIVATE_KEY` secret,
   which the caller passes by name (or with `secrets: inherit`). Explicit
   values win, so existing `RELEASE_PLEASE_APP_*` callers keep working.
2. **Environment.** The job runs in the environment named by
   `app-environment` (default `production`) with `deployment: false`: it sees
   environment-scoped credentials, creates no deployment records, and still
   honours the environment's branch pin. Repository-level credentials resolve
   the same way.
3. **Least-privilege token.** `actions/create-github-app-token` mints a token
   with `client-id`, `repositories: ${{ github.repository }}`, and exactly
   `permission-contents: write` and `permission-pull-requests: write`. The App
   installation itself is limited to Contents and Pull requests (read and
   write) plus Metadata; never Administration, Workflows, Secrets or Actions.
   **Issues is not required**: GitHub authorises creating labels and labelling
   pull requests with Pull requests: write.
4. **Failure behaviour.** Release Please keeps failing closed (ADR 0007).
   Config Sync and APM Sync fall back to `GITHUB_TOKEN` with a warning that
   names the missing piece, so the rollout can proceed repository by
   repository without breaking v3.x callers.
5. **No Actions PR-creation setting.** That setting governs `GITHUB_TOKEN`
   only; App tokens open pull requests with it off. Repositories keep it off,
   and onboarding no longer requires it.
6. **Config Sync drops `issues: write`.** The job requests only `contents:
   write` and `pull-requests: write`, which every existing caller grants.

The full contract, caller snippet and migration steps live in
[`docs/automation-app.md`](../automation-app.md);
`tests/automation-app-contract.sh` enforces it.

## Alternatives considered

- **Enable _Allow GitHub Actions to create and approve pull requests_
  everywhere.** Rejected: it widens what any workflow can do (approve PRs),
  and `GITHUB_TOKEN` PRs still would not run required checks.
- **A separate App per workflow.** Rejected: one more private key to rotate
  and provision per App, for no isolation gain — each would hold the same
  Contents and Pull requests permissions.
- **Keep the `RELEASE_PLEASE_APP_*` names.** Rejected: the App is no longer
  Release Please–specific, and the dotfiles provisioning already standardised
  on `AUTOMATION_APP_*`.
- **Fail closed in Config Sync.** Rejected for now: no current caller passes
  any secret, so a hard failure on the version bump would block Renovate's
  update PRs until every caller is edited. The fallback warning makes the gap
  visible instead.
- **`secrets: inherit` in templates.** Rejected: it hands every repository
  secret to the reusable workflow. Templates map only the App key.

## Consequences

- A repository needs three things for App-authenticated automation: the App
  installed, `AUTOMATION_APP_ID` / `AUTOMATION_APP_PRIVATE_KEY` provisioned,
  and a caller that passes `AUTOMATION_APP_PRIVATE_KEY`.
- Callers that grant only `contents` and `pull-requests` work with Config Sync
  again, and the repositories with the Actions PR-creation setting off get
  working sync PRs that run CI once their callers pass the secret.
- Referencing the `production` environment creates it (unprotected and empty)
  in a public repository that does not have it yet; the dotfiles module pins it
  to the default branch before it writes any secret into it.
- A run dispatched from a non-default branch of a public repository fails at
  job start when the environment is pinned. That is the protection working.
- The legacy `RELEASE_PLEASE_APP_*` variable and secret can be deleted from a
  repository once its callers use the standard names.

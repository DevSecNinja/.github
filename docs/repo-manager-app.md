# Repo Manager GitHub App

This account uses a single GitHub App — **DevSecNinja Repo Manager**
— to authenticate every cross-repo automation that needs to push
branches or open pull requests. The App replaces the default
`GITHUB_TOKEN` for those flows so we never have to enable the
account-wide _"Allow GitHub Actions to create and approve pull
requests"_ toggle, and so each push appears in the audit log as a
named bot rather than the generic `github-actions[bot]`.

## Why an App, not a PAT or the toggle

| Option | Verdict |
|---|---|
| Account toggle "Allow Actions to create PRs" | Works, but the toggle is account-wide — every workflow on every repo gets the capability whether it needs it or not. Discouraged. |
| Personal Access Token (PAT) | Long-lived, owned by a human, scoped to the entire user account. Worst of all worlds: rotation friction + over-permissioned. |
| GitHub App | Per-permission scope, per-repo install, **1-hour token TTL**, distinct bot identity in audit logs. Industry standard for this pattern. |

The trust boundary stays the branch-protection rules on each consumer
repo (CODEOWNERS-required review on `main`). The App can _open_ PRs
but cannot merge them past the protection gate.

## Permissions granted to the App

Repository permissions:

- **Contents: read & write** — push the working branch (`chore/config-sync`, `chore/vendored-file-sync`).
- **Pull requests: read & write** — create the PR and update its
  body.
- **Issues: read & write** — `gh label create` to ensure the
  `config-sync` label exists (labels are part of the Issues API).
- **Metadata: read** — required by every App.

Account permissions: none.

The App does **not** receive `Workflows: write`. If a future
config-sync use case needs to ship `.github/workflows/*.yml` from the
central repo to consumers, that permission can be added — but it
materially expands the App's blast radius and should be a deliberate
decision.

## One-time setup

1. https://github.com/settings/apps/new (account-level App, owned by
   `DevSecNinja`).
2. **Name**: `DevSecNinja Repo Manager`.
3. **Homepage URL**: `https://github.com/DevSecNinja/.github`.
4. **Webhook**: disable (we use this App as a token-minter, not as an
   event consumer).
5. **Repository permissions**: as listed above.
6. **Where can this GitHub App be installed**: _"Only on this
   account."_
7. Create the App, then on the App settings page:
   - Note the numeric **App ID**.
   - Generate a **private key**, download the `.pem` file. Keep it
     locally; it is also stored as a per-repo secret below.
8. Click **Install App** and pick the consumer repos. _Selected
   repositories_ is preferred over _All repositories_ so a future
   repo doesn't silently inherit write access — installing on a new
   repo is a deliberate act.

## Per-repo secret distribution

Every consumer repo that calls a reusable workflow which needs the
App must have these two repository secrets set:

| Secret name | Value |
|---|---|
| `REPO_MANAGER_APP_ID` | The numeric App ID from step 7 above |
| `REPO_MANAGER_APP_PRIVATE_KEY` | The full contents of the `.pem` file (including the `-----BEGIN ...-----` markers) |

Set them either via the web UI (Settings → Secrets and variables →
Actions → Repository secrets) or via the `gh` CLI once authenticated:

```bash
gh secret set REPO_MANAGER_APP_ID         --repo DevSecNinja/<repo> --body "<app-id>"
gh secret set REPO_MANAGER_APP_PRIVATE_KEY --repo DevSecNinja/<repo> < path/to/private-key.pem
```

There is no account-level secret store for user accounts (only orgs
have those), so the secrets must be copied per repo. This is a
one-time cost; private-key rotation can be scripted with the same
two `gh secret set` invocations per repo.

## How a consumer wires it up

```yaml
# .github/workflows/config-sync.yml in any consumer repo
---
name: Config Sync

on:
  schedule: [{ cron: "0 0 * * 1" }]
  workflow_dispatch:

permissions:
  contents: read

jobs:
  sync:
    # renovate: datasource=github-tags depName=DevSecNinja/.github
    uses: DevSecNinja/.github/.github/workflows/config-sync.yml@v2.0.0
    permissions:
      contents: read
    secrets:
      app-id:      ${{ secrets.REPO_MANAGER_APP_ID }}
      private-key: ${{ secrets.REPO_MANAGER_APP_PRIVATE_KEY }}
```

The `permissions:` block stays read-only because the workflow no
longer touches `GITHUB_TOKEN` for writes — every push and every
`gh` API call is authenticated with the freshly-minted App token.

The reusable workflow mints the token via
`actions/create-github-app-token`, which scopes it to the calling
repo automatically (no `owner` / `repositories` input required).

## Rotation runbook

1. App settings → **Generate a new private key** → download the new
   `.pem`.
2. For each consumer repo (script with `gh secret set`):
   ```bash
   gh secret set REPO_MANAGER_APP_PRIVATE_KEY \
     --repo DevSecNinja/<repo> < path/to/new-key.pem
   ```
3. Verify by running one workflow on workflow_dispatch.
4. Revoke the old key on the App settings page.

App tokens minted with the old key continue to work until they
expire (≤1h). There is no need to coordinate the rotation tightly.

## Audit & monitoring

- Every push lands as `devsecninja-repo-manager[bot]` (or whatever
  username the App ends up with). Filter the audit log with that
  actor to see all automated activity at a glance.
- The App's installation page shows last-used timestamps for each
  permission. Anomalies (e.g. `contents: write` used on a repo that
  isn't supposed to be touched) are visible there.
- If a private-key copy ever leaks, **rotate immediately**: the App
  cannot revoke individual installation tokens, but rotating the
  private key invalidates every token still in flight.

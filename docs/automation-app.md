# DevSecNinja Automation GitHub App

One GitHub App, **DevSecNinja Automation** (`devsecninja-automation`, App ID
`3563533`), is the identity for every central workflow that pushes a branch or
opens a pull request:

| Workflow                                                                 | Uses the App to                          | Without App credentials        |
| ------------------------------------------------------------------------ | ---------------------------------------- | ------------------------------ |
| [`config-sync.yml`](../.github/workflows/config-sync.yml)                | Push `chore/config-sync`, label, open PR | Falls back to `GITHUB_TOKEN` ⚠ |
| [`release-please.yml`](../.github/workflows/release-please.yml)          | Open the release PR, create tags         | **Fails** (fail closed)        |
| [`apm-sync.yml`](../.github/workflows/apm-sync.yml)                      | Push `chore/apm-sync`, open PR           | Falls back to `GITHUB_TOKEN` ⚠ |
| [`apm-materialize.yml`](../.github/workflows/apm-materialize.yml) (here) | Push `chore/apm-materialize`, open PR    | Fails                          |

See [ADR 0011](design-decisions/0011-single-automation-github-app.md) for the
decision.

## Why an App instead of `GITHUB_TOKEN`

- **Pull requests and tags made with `GITHUB_TOKEN` do not trigger
  workflows**, so required checks never run on them and tag-triggered
  publishers never fire. App-made events trigger workflows normally.
- **`GITHUB_TOKEN` can only open pull requests when the repository enables
  _Allow GitHub Actions to create and approve pull requests_.** That setting
  governs `GITHUB_TOKEN` only; App tokens open pull requests with it off. Keep
  it **off**: it would also let any workflow approve pull requests.

## App permissions

Repository permissions — nothing else:

| Permission    | Access         | Why                                               |
| ------------- | -------------- | ------------------------------------------------- |
| Contents      | Read and write | Push working branches, release commits and tags   |
| Pull requests | Read and write | Open/update PRs; create labels and label PRs (\*) |
| Metadata      | Read-only      | Mandatory for every App                           |

(\*) GitHub accepts `POST`/`PATCH /repos/{owner}/{repo}/labels` and adding
labels to a pull request with **Pull requests: write**, so **Issues is not
needed**. See
[Permissions required for GitHub Apps](https://docs.github.com/en/rest/authentication/permissions-required-for-github-apps).

> [!CAUTION]
> Never add **Administration**, **Workflows**, **Secrets** or **Actions**. The
> private key is an Actions secret in every repository, so anyone who can edit
> a workflow in any of them can mint a token with the App's _full_
> installation permissions — the `permission-*` downscoping in
> `actions/create-github-app-token` is a self-imposed request, not a platform
> limit. Change repository settings from your own `gh` login instead.

Each workflow still mints its token with only `permission-contents: write`
and `permission-pull-requests: write`, scoped to the calling repository
(`repositories: ${{ github.repository }}`).

The App must be **installed** on every repository that uses these workflows.

## Per-repository credentials

| Name                         | Kind     | Value                                                          |
| ---------------------------- | -------- | -------------------------------------------------------------- |
| `AUTOMATION_APP_ID`          | Variable | The numeric App ID (`3563533`) — not the client ID or the slug |
| `AUTOMATION_APP_PRIVATE_KEY` | Secret   | The full PEM, including the `-----BEGIN/END …-----` lines      |

Provision them from 1Password (`op://Private/GitHub Automation App/app-id` and
`.../private-key`) with the `GitHubRepoConfig` module in
[DevSecNinja/dotfiles](https://github.com/DevSecNinja/dotfiles/blob/main/docs/github-repo-config.md#app-credentials):

```powershell
$cred = Get-GitHubAppCredential   # 1Password asks for approval

# Preview the drift, then apply it (same command without -WhatIf):
Get-GitHubRepoConfig -All -Check AppCredential | Set-GitHubRepoConfig -Category AppCredential -AppCredential $cred -WhatIf
Get-GitHubRepoConfig -All -Check AppCredential | Set-GitHubRepoConfig -Category AppCredential -AppCredential $cred

# Or a single repository:
Get-GitHubRepoConfig -Repository notes -Check AppCredential | Set-GitHubRepoConfig -Category AppCredential -AppCredential $cred
```

`-Category AppCredential` limits the change to the credential; drop it to
remediate the rest of the repository baseline as well. The 1Password CLI's
desktop-app integration must be enabled (_Settings → Developer → Integrate
with 1Password CLI_).

On **public** repositories the module stores both in the Actions environment
`production`, pinned to the default branch, so a workflow running on any other
branch cannot read the key. On **private** repositories (GitHub Free has no
private environments) they are stored at repository level.

## How the central workflows read them

The variable is read automatically: in a reusable workflow, `vars` refers to
the **caller** repository. The secret must be passed by the calling job. The
job runs in the environment named by the `app-environment` input (default
`production`) with `deployment: false`, which exposes the environment's
values without creating a deployment record. Repository-level credentials work
with the same default — environment values only take precedence when they
exist — and so do private repositories. GitHub creates the environment, empty
and unprotected, the first time a job references it in a repository that
lacks it; that is harmless, and the dotfiles module pins it to the default
branch before it ever writes a secret into it.

**Caller snippet** (all three reusables, v3.4.0+):

```yaml
jobs:
  sync:
    uses: DevSecNinja/.github/.github/workflows/config-sync.yml@<sha> # v3.4.0
    permissions:
      contents: write
      pull-requests: write
    secrets:
      AUTOMATION_APP_PRIVATE_KEY: ${{ secrets.AUTOMATION_APP_PRIVATE_KEY }}
```

Pass the secret **by name** like this even when it only exists in the
`production` environment: GitHub resolves it for the job that sets the
environment. `secrets: inherit` also works, but hands every secret of the
repository to the reusable workflow (zizmor flags it), so prefer the explicit
mapping.

Resolution order, identical in every workflow:

| Value       | Explicit override (wins) | Standard name                       |
| ----------- | ------------------------ | ----------------------------------- |
| App ID      | input `app-id`           | variable `AUTOMATION_APP_ID`        |
| Private key | secret `app-private-key` | secret `AUTOMATION_APP_PRIVATE_KEY` |
| Environment | input `app-environment`  | `production`                        |

`config-sync` and `apm-sync` fall back to `GITHUB_TOKEN` with a warning when
either value is missing — the warning names which one. That PR only opens if
the repository enables the Actions PR-creation setting, and it does not run
CI. `release-please` fails before Release Please runs.

The calling job still grants `contents: write` and `pull-requests: write`:
the fallback path (and Release Please's own job) need them. **`issues: write`
is not needed.**

## Migrating from `RELEASE_PLEASE_APP_*`

Repositories onboarded to Release Please before v3.4.0 hold the **same App**
under `RELEASE_PLEASE_APP_ID` / `RELEASE_PLEASE_APP_PRIVATE_KEY` and map them
explicitly:

```yaml
with:
  app-id: ${{ vars.RELEASE_PLEASE_APP_ID }}
secrets:
  app-private-key: ${{ secrets.RELEASE_PLEASE_APP_PRIVATE_KEY }}
```

That keeps working unchanged — explicit values win. To move a repository to
the standard names:

1. Provision `AUTOMATION_APP_ID` / `AUTOMATION_APP_PRIVATE_KEY` (above).
2. Bump the workflow pin to v3.4.0 or later and replace the `app-id` /
   `app-private-key` mapping with the caller snippet above.
3. After a successful run, delete the `RELEASE_PLEASE_APP_ID` variable and
   `RELEASE_PLEASE_APP_PRIVATE_KEY` secret.

## Troubleshooting

| Symptom                                                                                 | Cause and fix                                                                                                                            |
| --------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| Warning `… falls back to GITHUB_TOKEN`: "does not pass the … secret"                    | The variable is visible but the calling job has no `secrets:` mapping. Add the caller snippet.                                           |
| `GitHub Actions is not permitted to create or approve pull requests`                    | The run used `GITHUB_TOKEN` (see the fallback warning). Provision the App credentials; do not enable the setting.                        |
| `Bad credentials` / `A JSON web token could not be decoded`                             | The key is incomplete (missing header/footer lines) or `AUTOMATION_APP_ID` holds the client ID or installation ID instead of the App ID. |
| `Not Found` or "integration not installed" from `create-github-app-token`               | The App is not installed on this repository.                                                                                             |
| `The permissions requested are not granted to this installation`                        | The installation lacks Contents or Pull requests write. Accept the App's permission update in the installation settings.                 |
| `Branch "…" is not allowed to deploy to production due to environment protection rules` | The workflow ran from a branch other than the default branch. Run it from the default branch; the pin is what protects the key.          |
| `startup_failure` before any step runs                                                  | The calling job grants fewer permissions than the reusable job requests. Grant `contents: write` and `pull-requests: write`.             |

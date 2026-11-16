# `open-pr` composite action

Open (or update) a pull request from the current working tree.

After your job has produced changes to commit (signed scripts, formatted
files, regenerated configs, …), this action stages them, commits them
as one commit on top of the checked-out commit to a stable working
branch, and opens a PR via the preinstalled `gh` CLI. Repeat runs reuse
the same PR rather than spamming new ones.

By default the commit is made through the GitHub API, so **GitHub signs
it** and the PR can merge into a branch that requires signed commits
(see [Signed commits](#signed-commits-commit-method-api)).

Designed for jobs that should land via PR review instead of pushing
directly to a protected branch — auto-formatting, artifact signing,
generated-content updates, etc. Branch protection on the base branch
stays fully enforced; no bypass actor required.

## Why a composite action (and not a reusable workflow)?

Composite actions run inside the caller's job, so they see the working
tree the caller just modified. A reusable workflow runs on its own
runner without access to those uncommitted changes.

This action also avoids pulling in third-party `create-pull-request`
actions: it uses only `git`, `jq` and the `gh` CLI that ship preinstalled
on GitHub-hosted runners.

## Inputs

| Name             | Required | Default                                                 | Description                                                                                                                                                                                                                                                                            |
| ---------------- | -------- | ------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `branch`         | yes      | —                                                       | Working branch to create or replace. Use a stable per-purpose name (e.g. `chore/sign-powershell-scripts`) so repeat runs reuse the same PR.                                                                                                                                            |
| `base`           | no       | `main`                                                  | Branch to merge into.                                                                                                                                                                                                                                                                  |
| `title`          | yes      | —                                                       | PR title (also default commit message). Should be a Conventional Commit subject.                                                                                                                                                                                                       |
| `body`           | no       | `""`                                                    | PR body, plain Markdown.                                                                                                                                                                                                                                                               |
| `commit-message` | no       | `title`                                                 | Commit message for the staged changes. Defaults to `title`.                                                                                                                                                                                                                            |
| `paths`          | no       | `.`                                                     | Newline-delimited pathspecs to `git add`. Globs are forwarded literally.                                                                                                                                                                                                               |
| `labels`         | no       | `""`                                                    | Newline-delimited labels to apply on PR creation.                                                                                                                                                                                                                                      |
| `draft`          | no       | `false`                                                 | Open as draft.                                                                                                                                                                                                                                                                         |
| `signoff`        | no       | `false`                                                 | Add a `Signed-off-by` trailer with `git-user-name` and `git-user-email`.                                                                                                                                                                                                               |
| `commit-method`  | no       | `api`                                                   | `api`: commit through GraphQL `createCommitOnBranch`, signed by GitHub and authored as the token's identity. `git`: local commit and leased force-push, authored as `git-user-name` and **unsigned**.                                                                                  |
| `if-no-changes`  | no       | `skip`                                                  | Behaviour when there's nothing to commit: `skip` (exit 0) or `fail` (exit non-zero).                                                                                                                                                                                                   |
| `git-user-name`  | no       | `github-actions[bot]`                                   | Author name for `commit-method: git`, and the `signoff` name.                                                                                                                                                                                                                          |
| `git-user-email` | no       | `41898282+github-actions[bot]@users.noreply.github.com` | Author email for `commit-method: git`, and the `signoff` email.                                                                                                                                                                                                                        |
| `github-token`   | no       | `${{ github.token }}`                                   | Token for the commit and the `gh` PR calls (needs Contents and Pull requests write). The default `GITHUB_TOKEN` will NOT retrigger workflows on the bot's commit, which is what you want inside loops like signing-on-push. Pass a GitHub App token to retrigger CI on the new branch. |

## Outputs

| Name        | Description                                                                                               |
| ----------- | --------------------------------------------------------------------------------------------------------- |
| `changed`   | `true` when there were uncommitted changes and a PR was opened or updated.                                |
| `created`   | `true` when a brand-new PR was opened, `false` when an existing PR for `branch` was reused, or no change. |
| `pr-number` | PR number. Empty when `changed=false`.                                                                    |
| `pr-url`    | PR URL. Empty when `changed=false`.                                                                       |

## Caller responsibilities

- Check out the repo before calling this action (`actions/checkout`).
- Set job permissions yourself: at minimum `contents: write` and
  `pull-requests: write`.
- Make whatever changes you want committed to the working tree before
  invoking the action.
- With `commit-method: api`, don't commit locally first: the commit is
  built on the checked-out commit, which must exist on GitHub.
  `actions/checkout` does not need to persist credentials for this
  method; `commit-method: git` still pushes with them.

## Signed commits (`commit-method: api`)

The default method stages the changes locally, then sends them with the
GraphQL [`createCommitOnBranch`](https://docs.github.com/en/graphql/reference/mutations#createcommitonbranch)
mutation. GitHub signs commits made this way, whichever token makes them
(a GitHub App token, `GITHUB_TOKEN` or a PAT), so the PR passes a
"require signed commits" ruleset without an admin bypass. The commit is
authored as the token's identity: the App's bot with an App token,
`github-actions[bot]` with `GITHUB_TOKEN`.

How a run commits:

1. Stage `paths` and read the changes from the index, including deletions
   and binary files (sent base64-encoded).
2. Read the working branch's tip. When it is already one commit on the
   same base with the same files, nothing is written (see below).
3. Create a temporary `open-pr-tmp/<run>` branch at the checked-out
   commit and commit the changes on it, with that commit as
   `expectedHeadOid`.
4. Point the working branch at the new commit and delete the temporary
   branch in one atomic `updateRefs` call, leased on the tip from step 2.

The temporary branch exists because `createCommitOnBranch` can only append
to an existing branch: resetting the working branch to its base first
would briefly leave an open PR with no changes, which can make GitHub
close it. A push to the working branch during the run fails the run
instead of being overwritten, and the temporary branch is deleted on any
failure.

Limits of the API method; use `commit-method: git` (unsigned) when one
applies:

- New executable files are committed as regular files (a warning is
  printed). Modified files keep their mode.
- Symlinks and submodules can't be committed (the run fails).
- The whole change goes in one request. Config-sized changes (a few MB)
  work; in testing, requests of 10 to 25 MB of base64 payload failed
  intermittently. No file may exceed 100 MiB.
- The checked-out commit must be on GitHub, so jobs that commit locally
  before this action need `git`.

## Pitfalls baked in

- **No third-party action dependency.** Only `git`, `jq` and `gh`, all
  preinstalled on GitHub-hosted runners.
- **Default `GITHUB_TOKEN` does not retrigger workflows on push.** Safe
  inside loops where the same workflow would otherwise re-run on the
  bot's commit (e.g. sign-on-push).
- **Every update is leased against the live branch tip.** The API method
  leases its `updateRefs` call on the tip it read; the `git` method reads
  the tip with `git ls-remote` and pushes with
  `--force-with-lease=<branch>:<tip>` (an empty tip means "must not exist
  yet"). A concurrent push to the working branch is never silently
  overwritten, and — unlike a bare `--force-with-lease`, which needs a
  remote-tracking ref that a fresh checkout does not have — an existing
  branch (an open PR, or one left behind after merge) no longer fails with
  `! [rejected] … (stale info)`. Fixed in v3.3.0; callers pinned to an
  older version can run `git fetch origin "+refs/heads/<branch>:refs/remotes/origin/<branch>"`
  before this action as a workaround.
- **No-op updates are skipped.** When the branch already holds the same
  changes on the same base commit, the action leaves it alone, so an
  unchanged scheduled run does not re-run the PR's CI. The existing PR is
  still looked up and reported (`changed=true`, `created=false`).
- **PR reuse on conflict.** If a PR already exists for the same
  `branch -> base` pair, its branch is replaced with the new commit and
  the existing PR is reused — no duplicate PRs across runs.
- **Branch protection stays enforced.** This action only ever writes
  to the working branch (and a short-lived temporary branch) and opens a
  PR; merging into the protected base branch is left to the normal
  review/automerge flow.

## Example — sign artifacts and open a PR

```yaml
name: Sign Scripts
on:
  push:
    branches: [main]
    paths: ['**.ps1']

jobs:
  sign:
    runs-on: windows-latest
    permissions:
      contents: write
      pull-requests: write
    steps:
      - uses: actions/checkout@v6
        with: { fetch-depth: 0 }

      - name: Sign scripts
        shell: pwsh
        run: ./sign.ps1   # leaves modified .ps1 files in the working tree

      - uses: DevSecNinja/.github/actions/open-pr@<sha>
        with:
          branch: chore/sign-scripts
          base: main
          title: 'chore: sign scripts'
          paths: '**/*.ps1'
          labels: |
            automated
            chore
          body: |
            Automated signing of scripts after merge to `main`.

            Triggered by commit ${{ github.sha }}.
```

## Example — auto-formatter

```yaml
- run: ./script/format.sh   # rewrites files in place

- uses: DevSecNinja/.github/actions/open-pr@<sha>
  with:
    branch: chore/auto-format
    title: 'style: auto-format'
    labels: automated
    if-no-changes: skip   # default
```

## Example — regenerate manifest, fail if no drift detected

Useful when you _expect_ the regeneration to produce changes (because
something else in the pipeline implies they should exist).

```yaml
- run: ./script/regen-manifest.sh

- uses: DevSecNinja/.github/actions/open-pr@<sha>
  with:
    branch: chore/regen-manifest
    title: 'chore: regenerate manifest'
    paths: 'manifest.json'
    if-no-changes: fail
```

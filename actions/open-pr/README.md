# `open-pr` composite action

Open (or update) a pull request from the current working tree.

After your job has produced changes to commit (signed scripts, formatted
files, regenerated configs, …), this action stages them, commits them
to a stable working branch, force-pushes, and opens a PR via the
preinstalled `gh` CLI. Repeat runs reuse the same PR rather than
spamming new ones.

Designed for jobs that should land via PR review instead of pushing
directly to a protected branch — auto-formatting, artifact signing,
generated-content updates, etc. Branch protection on the base branch
stays fully enforced; no bypass actor required.

## Why a composite action (and not a reusable workflow)?

Composite actions run inside the caller's job, so they see the working
tree the caller just modified. A reusable workflow runs on its own
runner without access to those uncommitted changes.

This action also avoids pulling in third-party `create-pull-request`
actions: it uses only `git` and the `gh` CLI that ship preinstalled on
GitHub-hosted runners.

## Inputs

| Name             | Required | Default                                                 | Description                                                                                                                                                                                                                                                         |
| ---------------- | -------- | ------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `branch`         | yes      | —                                                       | Working branch to create or force-push to. Use a stable per-purpose name (e.g. `chore/sign-powershell-scripts`) so repeat runs reuse the same PR.                                                                                                                   |
| `base`           | no       | `main`                                                  | Branch to merge into.                                                                                                                                                                                                                                               |
| `title`          | yes      | —                                                       | PR title (also default commit message). Should be a Conventional Commit subject.                                                                                                                                                                                    |
| `body`           | no       | `""`                                                    | PR body, plain Markdown.                                                                                                                                                                                                                                            |
| `commit-message` | no       | `title`                                                 | Commit message for the staged changes. Defaults to `title`.                                                                                                                                                                                                         |
| `paths`          | no       | `.`                                                     | Newline-delimited pathspecs to `git add`. Globs are forwarded literally.                                                                                                                                                                                            |
| `labels`         | no       | `""`                                                    | Newline-delimited labels to apply on PR creation.                                                                                                                                                                                                                   |
| `draft`          | no       | `false`                                                 | Open as draft.                                                                                                                                                                                                                                                      |
| `signoff`        | no       | `false`                                                 | Add a `Signed-off-by` trailer to the commit.                                                                                                                                                                                                                        |
| `if-no-changes`  | no       | `skip`                                                  | Behaviour when there's nothing to commit: `skip` (exit 0) or `fail` (exit non-zero).                                                                                                                                                                                |
| `git-user-name`  | no       | `github-actions[bot]`                                   | Author name for the commit.                                                                                                                                                                                                                                         |
| `git-user-email` | no       | `41898282+github-actions[bot]@users.noreply.github.com` | Author email for the commit.                                                                                                                                                                                                                                        |
| `github-token`   | no       | `${{ github.token }}`                                   | Token used for the `git push` and `gh` API call. The default `GITHUB_TOKEN` will NOT retrigger workflows on the bot's push, which is what you want inside loops like signing-on-push. Pass a PAT/App token for cross-repo PRs or to retrigger CI on the new branch. |

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

## Pitfalls baked in

- **No third-party action dependency.** Only `git` + `gh`, both
  preinstalled on GitHub-hosted runners.
- **Default `GITHUB_TOKEN` does not retrigger workflows on push.** Safe
  inside loops where the same workflow would otherwise re-run on the
  bot's commit (e.g. sign-on-push).
- **Force-push with `--force-with-lease`** so a concurrent push to the
  working branch is not silently overwritten.
- **PR reuse on conflict.** If a PR already exists for the same
  `branch -> base` pair, its contents are updated by the force-push
  and the existing PR is reused — no duplicate PRs across runs.
- **Branch protection stays enforced.** This action only ever pushes
  to the working branch and opens a PR; merging into the protected
  base branch is left to the normal review/automerge flow.

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

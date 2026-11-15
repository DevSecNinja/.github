# `ai-commits-badge` composite action

Generate an AI commits badge and README card from Git history. No git-ai,
third-party actions, Python packages, network calls or publishing are needed.
Run on Linux with Bash, Git and Python 3.8+ already available.

## What it measures

Each non-merge commit is classified once, in this order:

1. **AI agent:** its author matches a bundled AI identity.
2. **Bot automation:** its author contains `[bot]`, unless recognized above.
   Excluded from the denominator, including bot commits with AI trailers.
3. **Co-authored with AI:** a `Co-authored-by` trailer matches an AI identity.
4. **No recorded AI attribution:** neither author nor trailers match.

The percentage is `(agent + coauthored) / (agent + coauthored + unattributed)`.
This counts commits, not lines, effort or the percentage of code written by AI.
Missing attribution is **not proof of human authorship**. Squashing, lost
trailers and unrecognized tools affect the result. Tool counts use the first
matching identity, not every co-author. Defaults recognize Copilot, Claude,
Cursor, Devin, Jules and Aider; the exact rules live in
[`ai_commits_badge.py`](ai_commits_badge.py).

The card legend shortens the final category to **No recorded AI** to fit its
existing 480px layout. Tooltips and accessible hover text retain the full
**No recorded AI attribution** wording. The corresponding machine-readable
key and action output are `unattributed`.

## Inputs

| Input      | Default                    | Meaning                                                         |
| ---------- | -------------------------- | --------------------------------------------------------------- |
| `ref`      | `HEAD`                     | Commit, branch or tag reachable in the local checkout.          |
| `since`    | empty                      | Optional Git date filter, e.g. `90 days ago`.                   |
| `name`     | `${{ github.repository }}` | Name displayed on the card and in tooltips.                     |
| `label`    | `AI commits`               | Compact badge and Shields endpoint label.                       |
| `out`      | `badges`                   | Output directory relative to the caller's working directory.    |
| `themes`   | `"false"`                  | Set `"true"` to also write light/dark cards. Other values fail. |
| `repo-dir` | `.`                        | Checkout to measure; the action never changes it.               |

Identity rules are centralized and cannot be overridden per caller, so repos
using the same action revision use comparable classification rules. Add new
AI identities to the bundled list through a PR in this repository. Patterns
are case-insensitive and match `Name <email>` for authors and individual
trailers.

## Outputs and files

| Step output           | Meaning                                                   |
| --------------------- | --------------------------------------------------------- |
| `ai-percent`          | One-decimal percentage, or `n/a` when no commits qualify. |
| `commits`             | Denominator, excluding merge and automation commits.      |
| `ai-commits`          | Agent-authored plus AI-co-authored commits.               |
| `agent`               | AI-authored commits.                                      |
| `coauthored`          | AI-co-authored commits.                                   |
| `unattributed`        | No recorded AI attribution.                               |
| `excluded-automation` | Excluded non-merge bot commits.                           |

The badge displays a whole-number percentage; `ai-percent` and stats JSON
retain one decimal. Empty history produces a grey `n/a` badge.

| File in `out`                                           | Purpose                                                           |
| ------------------------------------------------------- | ----------------------------------------------------------------- |
| `ai-commits.svg`                                        | Compact badge with a proportional strip and hover breakdown.      |
| `ai-commits.json`                                       | Shields.io endpoint JSON (`schemaVersion: 1`).                    |
| `ai-commits-stats.json`                                 | Counts, tool breakdown, ref, date filter and UTC generation time. |
| `ai-commits-card.svg`                                   | Card following `prefers-color-scheme`.                            |
| `ai-commits-card-light.svg`, `ai-commits-card-dark.svg` | Additional cards when `themes: "true"`.                           |

The action writes files only. Callers own uploads, branch updates, permissions,
retention and publication. Counts and tool names become visible wherever you
publish these files. Publishing results from private or work repositories is a
separate, explicitly approved decision for each repository owner.

## Complete history is required

Use `actions/checkout` with `fetch-depth: 0`. The default shallow checkout fails
with an actionable message before writing files or step outputs; `since` does
not bypass this guard. The action never fetches history automatically.
Fetch any requested non-default ref in the caller as well.

## Example: add badges to a MkDocs site

In the docs workflow, add a daily refresh and generate **after** `mkdocs build`
(which cleans `site`) and **before** uploading the Pages artifact. Keep your
existing pinned MkDocs setup/build steps and Pages deployment configuration.

```yaml
---
name: Docs
on:
  push:
    branches: [main]
  workflow_dispatch:
  schedule:
    - cron: "17 4 * * *"
permissions:
  contents: read

jobs:
  build:
    runs-on: ubuntu-24.04
    steps:
      # renovate: datasource=github-tags depName=actions/checkout
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          fetch-depth: 0
          persist-credentials: false
      # Keep the site's existing pinned toolchain setup here.
      - run: mkdocs build
      - uses: DevSecNinja/.github/actions/ai-commits-badge@<release-commit-sha>
        id: ai
        with:
          out: site/badges
          themes: "true"
      - run: printf 'AI commits %s/%s (%s%%)\n' "$AI" "$TOTAL" "$PERCENT"
        env:
          AI: ${{ steps.ai.outputs.ai-commits }}
          TOTAL: ${{ steps.ai.outputs.commits }}
          PERCENT: ${{ steps.ai.outputs.ai-percent }}
      # renovate: datasource=github-tags depName=actions/upload-pages-artifact
      - uses: actions/upload-pages-artifact@fc324d3547104276b827a68afc52ff2a11cc49c9 # v5.0.0
        with:
          path: site
```

The snippet assumes MkDocs is already installed by your existing docs setup.
Keep the existing Pages deploy job after `build`, with `pages: write` and
`id-token: write`. The daily trigger regenerates rolling `since` windows even
when the source has no new commits.

In a README, reference the published site, for example:

```markdown
[![AI commits](https://example.org/badges/ai-commits.svg)](https://example.org/badges/ai-commits-stats.json)
```

Or use Shields with the publicly accessible, URL-encoded JSON endpoint:
`https://img.shields.io/endpoint?url=https%3A%2F%2Fexample.org%2Fbadges%2Fai-commits.json`.

## Example: standalone badge-only Pages site

For a repo without documentation, publish just the generated files to Pages.
Configure its Pages source as **GitHub Actions** first. This avoids committing
generated artifacts or needing a separate `badges` branch.

```yaml
---
name: Badges
on:
  push:
    branches: [main]
  workflow_dispatch:
  schedule:
    - cron: "17 4 * * *"
permissions:
  contents: read
concurrency:
  group: badges-pages
  cancel-in-progress: false

jobs:
  publish:
    runs-on: ubuntu-24.04
    permissions:
      contents: read
      pages: write
      id-token: write
    environment:
      name: github-pages
      url: ${{ steps.deploy.outputs.page_url }}
    steps:
      # renovate: datasource=github-tags depName=actions/checkout
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          fetch-depth: 0
          persist-credentials: false
      - uses: DevSecNinja/.github/actions/ai-commits-badge@<release-commit-sha>
        with:
          out: public/badges
          themes: "true"
      # renovate: datasource=github-tags depName=actions/upload-pages-artifact
      - uses: actions/upload-pages-artifact@fc324d3547104276b827a68afc52ff2a11cc49c9 # v5.0.0
        with:
          path: public
      # renovate: datasource=github-tags depName=actions/deploy-pages
      - uses: actions/deploy-pages@368f82528645a54fb793d4d04e342629a3f51346 # v5.0.1
        id: deploy
```

For a project site, the badge URL is
`https://OWNER.github.io/REPO/badges/ai-commits.svg`.
Do not use this workflow alongside another Pages site in the same repo: it
would replace that deployment. Use the docs-site pattern instead.

Both examples intentionally leave the new action's ref as
`<release-commit-sha>` until it is released. Replace it with the released full
40-character SHA and a version comment before use; let Renovate track the
release as with other centralized actions.

## Local checks

```sh
python3 tests/ai-commits-badge.py
python3 actions/ai-commits-badge/ai_commits_badge.py \
    --repo-dir . --ref HEAD --out /tmp/ai-badges --themes
```

The tests build isolated synthetic Git history and execute the composite
action's actual Bash step, including its environment wiring and outputs.

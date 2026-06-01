# ADR 0003: Use mise tasks as the task runner

## Status

Accepted

- **Date:** 2026-06-01
- **Scope:** `DevSecNinja/.github` — repository task automation (lint, test, etc.)

## Context

This repository already standardizes its entire toolchain on
[`mise`](https://mise.jdx.dev/): every linter, formatter, and security scanner
is pinned in [`.mise.toml`](../../.mise.toml) and executed via
`mise exec -- <tool>`. CI installs mise with `jdx/mise-action`, and the
devcontainer bootstraps it in `post-create.sh`.

When the repository gained its first scripted check
([`tests/renovate-custom-manager-coverage.sh`](../../tests/renovate-custom-manager-coverage.sh)),
we needed a consistent way to invoke it locally and in CI. mise ships a built-in
[task runner](https://mise.jdx.dev/tasks/), but dedicated runners such as
[`go-task`](https://taskfile.dev/) are also common. We had to decide whether to
introduce a separate task runner or reuse what mise already provides.

## Decision

> **Use mise tasks (declared in `.mise.toml` and invoked via `mise run <task>`)
> as the task runner for this repository. Do not introduce `go-task` or another
> standalone task runner unless task complexity clearly outgrows mise tasks.**

CI and contributors invoke automation through `mise run <task>` (for example
`mise run test`). Tasks rely on the mise-managed toolchain already being on
`PATH`, so task commands call tools directly rather than wrapping each in
`mise exec --`.

## Alternatives considered

- **`go-task` (Taskfile.yml).** A mature, expressive task runner with richer
  dependency graphs, `sources`/`generates` up-to-date checks, and parallel
  execution. Rejected for now because it adds a second orchestration tool with
  overlapping responsibility, an extra dependency to install, pin, and
  Renovate-track, and it would require wrapping commands in `mise exec --` to
  reach the toolchain.
- **Plain shell scripts invoked directly / a `Makefile`.** No version-pinned
  tool integration; contributors would have to manage tool availability
  manually, and `make` adds yet another dependency.
- **npm scripts.** Would pull in a Node.js toolchain this repository does not
  otherwise need.

## Consequences

### Pros

- **Single source of truth.** Task definitions and the tool versions they
  depend on live together in `.mise.toml`.
- **No new dependency.** mise is already installed in CI and the devcontainer,
  so there is nothing extra to bootstrap, pin, or track.
- **Tools are on `PATH` automatically.** Task commands invoke `pyjson5`, `jq`,
  and the like directly, with no `mise exec --` wrapper.
- **Consistent with the org convention** that all tooling is managed by mise.

### Cons

- **Less expressive than `go-task`** for complex dependency graphs, output
  fingerprinting, and large parallel build matrices.
- **Task runner is coupled to mise.** Contributors who do not use mise cannot
  run tasks without it.

## Guidance

- Define repository automation as `[tasks.<name>]` entries in `.mise.toml` and
  run them with `mise run <name>`.
- Keep task scripts callable on their own (a script under `tests/` or `scripts/`
  that the task simply invokes) so logic is easy to test and review.
- Revisit `go-task` only if task complexity grows substantially — for example
  build pipelines, code generation with caching, or large parallel task graphs.

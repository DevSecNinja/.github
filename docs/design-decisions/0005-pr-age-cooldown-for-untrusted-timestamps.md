# ADR 0005: PR-age cooldown for registries without a trusted release timestamp

## Status

Accepted

## Context

[ADR 0004](0004-automerge-non-major-after-soak.md) makes the `minimumReleaseAge`
soak (`14 days`, in [`.renovate/base.json5`](../../.renovate/base.json5)) a
load-bearing control: broad auto-merge is only safe because obviously bad
releases have time to be yanked or superseded before they merge.

Renovate's `minimumReleaseAge` is enforced from a **release timestamp** that the
datasource/registry must provide. Renovate 42+ defaults
`minimumReleaseAgeBehaviour` to `timestamp-required`, and it deliberately does
**not** trust the OCI `org.opencontainers.image.created` annotation (the
publisher controls it, so it could be forged to bypass the soak).

Several registries we use — **ghcr.io, lscr.io, quay.io** — expose no trusted
timestamp. With `timestamp-required`, every release from those registries is
marked "pending" forever: `internalChecksFilter: strict` then refuses to create
a branch, so the update sits under the dependency dashboard's "Pending Status
Checks" section and **no PR is ever opened** (observed in
`DevSecNinja/truenas-apps#115` — e.g. `ghcr.io/italypaleale/traefik-forward-auth`
stuck for months). The Renovate logs show it plainly:

```text
Marking N release(s) as pending, as they do not have a releaseTimestamp
  and we're running with minimumReleaseAgeBehaviour=timestamp-required
Branch renovate/ghcr.io-…-4.x creation is disabled
  because internalChecksFilter was not met
```

The two native options are both unacceptable on their own:

- `timestamp-required` (default): correct soak, but these updates never merge.
- `timestamp-optional`: PRs open again, but the soak is **skipped entirely** for
  timestamp-less releases — auto-merge with zero soak, contradicting ADR 0004.

## Decision

Keep the soak, but for these registries **measure it from PR age instead of
release age**.

1. For `docker` deps on `ghcr.io` / `lscr.io` / `quay.io`, set
   `minimumReleaseAgeBehaviour: "timestamp-optional"` (in
   [`.renovate/packageRules.json5`](../../.renovate/packageRules.json5)). Renovate
   opens the PR immediately and enables `platformAutomerge`.
2. A required **`pr-cooldown`** status check holds the merge until the PR branch
   head commit is at least 14 days old, provided by the reusable workflow
   [`renovate-pr-cooldown.yml`](../../.github/workflows/renovate-pr-cooldown.yml).
   GitHub auto-merge then merges the PR the moment the check turns green.

Age is measured from the **branch head commit**, not PR creation: when Renovate
rebases the PR to a newer version the clock correctly restarts, so the exact
content being merged has always soaked for the full period.

Datasources that DO provide a trusted timestamp (docker.io, github
tags/releases) are left on the default `timestamp-required` +
`internalChecksFilter: strict` path — their soak is enforced natively and they
are not gated by `pr-cooldown`.

## Consuming-repo wiring

A repo that hosts images from the gated registries must:

1. Add a caller workflow from
   [`workflow-templates/renovate-pr-cooldown.yml`](../../workflow-templates/renovate-pr-cooldown.yml)
   (triggers: `pull_request`, `schedule`, `workflow_dispatch`).
2. Add the `pr-cooldown` status check to the branch ruleset's **required status
   checks**. The workflow reports `success` for human and non-gated PRs, so the
   required check never blocks anything else.

## Alternatives considered

- **`timestamp-optional` alone.** Rejected: removes the soak for exactly the
  images most in need of it (no timestamp = no scrutiny window).
- **Stay on `timestamp-required`.** Rejected: the updates never merge and pile
  up on the dashboard, so they get force-created manually or ignored.
- **Custom datasource/regex to synthesise a timestamp.** Rejected: the only
  available timestamp is the publisher-controlled OCI annotation Renovate
  intentionally distrusts, so this would re-introduce the forgery risk.
- **Gate every registry (incl. docker.io) with `pr-cooldown`.** Rejected:
  double-soaks images that already have a trusted timestamp; only registries
  without one need the PR-age fallback.

## Consequences

- Updates from ghcr.io / lscr.io / quay.io flow again and auto-merge after a
  14-day PR-age soak, preserving the ADR 0004 risk posture without trusting a
  forgeable timestamp.
- The soak clock for these registries starts when Renovate first opens (or last
  rebases) the PR rather than at publish time; because Renovate opens the PR
  shortly after detecting a release, the two are close in practice.
- `pr-cooldown` becomes a load-bearing required check: it must stay in the
  branch ruleset, and the scheduled workflow must keep running for soaked PRs to
  merge.

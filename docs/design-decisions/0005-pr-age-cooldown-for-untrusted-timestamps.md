# ADR 0005: PR-age cooldown for registries without a trusted release timestamp

## Status

Accepted. Amended by
[ADR 0013](0013-rebase-automerge-branches-when-behind.md): the
non-strict branch protection this relies on is now a stated requirement
for repositories that require `pr-cooldown`. Amended again: the clock now
starts when the PR began proposing its current change, not at the latest
head commit (see "Clock start" below).

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

Renovate only derives a release timestamp for **Docker Hub**, and only via the
Hub-specific `hub.docker.com` API (`registryHost === DOCKER_HUB` in the docker
datasource). Every other registry is read through the OCI Registry V2
`/tags/list` endpoint, which returns bare tag names, so **no timestamp exists
regardless of what the registry stores internally** — this is a Renovate
limitation keyed on the registry host, not an omission by any given registry.

Registries we use that are affected include **ghcr.io, lscr.io, quay.io,
dhi.io, mcr.microsoft.com**. With `timestamp-required`, every release from
those registries is
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

1. For `docker` deps on **every registry except Docker Hub**, set
   `minimumReleaseAgeBehaviour: "timestamp-optional"` (in
   [`.renovate/packageRules.json5`](../../.renovate/packageRules.json5)). Renovate
   opens the PR immediately and enables `platformAutomerge`.

   This is expressed as a negated matcher (`/^[^/]*\./` plus
   `!/^docker\.io\//`) rather than a list of registries, mirroring Renovate's
   own internal condition. The positive pattern requires a dot in the first
   path segment — an explicit registry host — so bare Docker Hub names such as
   `nginx` keep their native soak. An allowlist was the original design and it
   failed silently: `dhi.io` was never added, and its images went ~3.5 months
   with no updates at all (`DevSecNinja/truenas-apps#634`). A registry nobody
   has wired up is now gated by default rather than slipping through.
2. A required **`pr-cooldown`** status check holds the merge until the PR has
   proposed its current change for at least 14 days, provided by the reusable
   workflow
   [`renovate-pr-cooldown.yml`](../../.github/workflows/renovate-pr-cooldown.yml).
   GitHub auto-merge then merges the PR the moment the check turns green.

### Clock start

The clock starts at the **oldest commit in the branch's force-push chain that
makes the same change as the head commit**, not at PR creation and not at the
latest push. "The same change" means the same changed lines (`+`/`-` lines of
every file's patch), so the exact content being merged has always been
proposed for the full period:

- a new version or digest changes those lines, so the clock restarts;
- a rebase onto a moved base, a retitle (for example a commit-type change in
  the shared presets) or an autoclose/reopen recreates the commit with the
  same lines, so the clock keeps running.

The first design measured the age of the head commit itself. Every Renovate
push restarted it, including pushes that did not change the version:
`DevSecNinja/truenas-apps#810` proposed traefik-forward-auth v4.14.4 for 18
days, but a conflict rebase on day 5 reset the clock and the next release
arrived before it passed again.

The workflow walks back through the PR's `HeadRefForcePushedEvent`s (one
GraphQL call, then one commit read per earlier push, at most 30) while each
earlier commit has the same changed lines. Anything it cannot compare falls
back to the head commit date, which can only make the soak longer: more than
one commit on the branch, a merge commit, a missing patch, a file list the
API pages (more than 300 files), a push chain that does not end at the head,
or an earlier commit that cannot be read.

The gated rule also sets **`rebaseWhen: "conflicted"`**. Renovate's default
(`auto`, which becomes `behind-base-branch` once automerge is enabled) would
rebase the PR every time `main` advances. Such a rebase no longer resets the
clock, but each one still costs a CI run. `conflicted` limits rebases to
genuine merge conflicts; branch protection is non-strict
(`strict_required_status_checks_policy: false`), so a behind-base gated PR still
auto-merges once the soak completes — no rebase required.

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

A repo that passes an explicit `gated-branch-prefixes` input (rather than
relying on the default) must switch it to `renovate/docker-gated-`, otherwise
its gate will look for branch names Renovate no longer produces.

Because the marker changes branch naming, open Renovate PRs for non-Docker-Hub
images are recreated once under the new prefix; their cooldown clock restarts.
Docker Hub branches are unaffected.

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
- **Keep an allowlist of timestamp-less registries.** Rejected: it must be kept
  in sync in two places (the Renovate rule and the workflow's branch prefixes),
  and a registry missing from both fails silently. Inverting only the Renovate
  half would be worse still — the dep would get `timestamp-optional` while the
  gate ignored its branch, auto-merging with **zero** soak. Both halves are now
  driven by one matcher via the `docker-gated-` branch marker, so they cannot
  drift apart.

## Consequences

- Updates from every timestamp-less registry flow again and auto-merge after a
  14-day PR-age soak, preserving the ADR 0004 risk posture without trusting a
  forgeable timestamp.
- The soak clock for these registries starts when Renovate first proposes the
  version (or digest) in the PR rather than at publish time; because Renovate
  opens or updates the PR shortly after detecting a release, the two are close
  in practice.
- An upstream that releases more often than every 14 days never merges on its
  own: each release restarts the clock (`DevSecNinja/truenas-apps#724`,
  `#829`). That is the price of soaking the exact version that merges; such
  PRs need the owner.
- `pr-cooldown` becomes a load-bearing required check: it must stay in the
  branch ruleset, and the scheduled workflow must keep running for soaked PRs to
  merge.

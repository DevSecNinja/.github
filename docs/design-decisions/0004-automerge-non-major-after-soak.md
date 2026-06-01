# ADR 0004: Auto-merge all non-major updates after a soak period

## Status

Accepted

## Context

DevSecNinja maintains many repositories that all consume the shared Renovate
presets under `.renovate/` (aggregated by `renovate.json5`). Manually reviewing
and merging routine dependency PRs across every repo each week is not a good use
of time. Dependencies still matter, but the day-to-day toil of merging minor,
patch, and digest bumps outweighs the marginal risk they carry — especially once
an update has been published for a while and the repository's own tests pass.

An earlier iteration tried to opt specific managers/datasources into automerge
one rule at a time, with extra `0.x` exclusions and per-publisher trust carve-
outs for GitHub Actions. That model produced a long, hard-to-maintain allow-list
and label/behaviour mismatches (for example, non-trusted `0.x` actions labelled
`merge: manual` while actually auto-merging).

## Decision

Auto-merge **every non-major update** once two conditions hold:

1. The update has cleared the global `minimumReleaseAge` soak time
   (`14 days`, defined in [`.renovate/base.json5`](../../.renovate/base.json5)).
2. The repository's required status checks pass (`platformAutomerge`).

This is expressed as a single rule in
[`.renovate/autoMerge.json5`](../../.renovate/autoMerge.json5):

```json5
{
  matchUpdateTypes: ["pin", "pinDigest", "digest", "minor", "patch"],
  automerge: true,
  automergeType: "pr",
  platformAutomerge: true,
}
```

- **Major updates always require manual review and merge.** They are the only
  category gated on a human.
- No `0.x` exclusion and no per-publisher trust list: the soak time plus passing
  tests are accepted as sufficient risk coverage for non-major updates.
- Labels in [`.renovate/labels.json5`](../../.renovate/labels.json5) mirror this
  exactly: non-major → `merge: auto`, major → `merge: manual`.
- Security (`vulnerabilityAlerts`) updates keep their own `minimumReleaseAge: 0`
  override in `base.json5` so fixes are not delayed by the soak.

Accepted trade-off: if a non-major update breaks something, that is tolerated.
The remediation is to add or strengthen a test so the same class of breakage is
caught automatically in the future, rather than to reintroduce manual gating.

## Alternatives considered

- **Per-manager opt-in allow-list (the previous approach).** Rejected. It
  required a rule per ecosystem, `0.x` carve-outs, and publisher trust lists,
  which were verbose and drifted out of sync with the labelling rules.
- **Deny-list (auto-merge everything except listed exceptions).** Rejected for
  major updates specifically — majors should fail closed to manual review.
- **Exclude `0.x` from automerge.** Rejected. Pinning + soak time + tests are
  considered enough; the maintenance cost of `0.x` carve-outs is not worth it
  for this org's risk appetite.
- **No soak time (`minimumReleaseAge: 0`).** Rejected. The 14-day soak is the
  main safeguard that makes broad automerge acceptable; it lets obviously bad
  releases get yanked or superseded before they ever merge.

## Consequences

- Routine dependency maintenance is effectively hands-off; only major upgrades
  land on a human's plate.
- "Automerge: Disabled by config" should now only appear for major updates;
  seeing it on a non-major update signals a real configuration problem.
- Risk tolerance is explicitly shifted toward "detect breakage with tests"
  rather than "prevent breakage with manual review".
- The soak time and required status checks become load-bearing controls and
  must stay enabled (branch protection, CI) for this policy to be safe.

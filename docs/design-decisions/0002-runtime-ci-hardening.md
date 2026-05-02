# ADR 0002: Use Harden-Runner for runtime CI hardening

## Status

Accepted

## Context

The existing shared lint workflow already runs static and repository-level
security checks such as gitleaks, checkov, trivy, and zizmor. Those tools catch
secrets, IaC issues, dependency or filesystem findings, and unsafe workflow
patterns, but they do not observe or restrict what an individual GitHub Actions
job does at runtime.

Runtime controls must execute in the same job as the build, test, or release
steps they protect. A reusable workflow in this repository would run on its own
runner, so it could harden only itself rather than the caller's job.

## Decision

Add `actions/harden-runner`, a composite action that wraps
`step-security/harden-runner` pinned to a full commit SHA.

Callers should place the action near the start of each sensitive job. The
wrapper defaults to `egress-policy: audit` so repositories can collect observed
network egress without breaking CI. After reviewing the observed endpoints,
callers can switch selected jobs to `egress-policy: block` with explicit
`allowed-endpoints`.

Harden-Runner complements the existing static scanners; it does not replace
gitleaks, checkov, trivy, zizmor, dependency scanning, CodeQL, or GitHub secret
scanning.

## Alternatives considered

- **Continue with only static scanners.** Kept the existing scanners, but they
  cannot detect or restrict unexpected runtime network egress.
- **zizmor only.** Valuable for GitHub Actions workflow static analysis, but it
  cannot monitor a running job.
- **OpenSSF Scorecard.** Useful for repository supply-chain posture and may be
  added separately, but it is not a per-job runtime control.
- **GitHub dependency scanning, CodeQL, and secret scanning.** Important
  platform controls, but they do not enforce runner egress allow-lists.
- **Self-hosted runner network policies or an outbound proxy.** Stronger
  central enforcement, but more operationally complex and not available to
  every repository using GitHub-hosted runners.
- **A reusable workflow wrapper.** Rejected because it would harden only the
  reusable workflow's runner, not the caller's job.

## Consequences

- Repositories can adopt runtime monitoring incrementally by adding one
  composite action step per job.
- Audit mode creates a safe migration path before enforcing block mode.
- High-value jobs still need reviewed allow-lists and least-privilege
  permissions.
- The repository now has a third-party action dependency that must remain
  pinned and reviewed when updated.

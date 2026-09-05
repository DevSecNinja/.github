# Design Decisions

Architecture / design decision records (ADRs) for the
`DevSecNinja/.github` repository. Each ADR documents a single significant
decision: the context that motivated it, the rule itself, and the trade-offs
we accepted.

New decisions are added as `NNNN-short-title.md`, numbered sequentially.
Once accepted, ADRs are immutable — changes are made by adding a new ADR
that supersedes the old one.

## Index

| ADR                                                         | Title                                                                | Status   |
| ----------------------------------------------------------- | -------------------------------------------------------------------- | -------- |
| [0001](0001-reusable-workflow-version-inputs.md)            | Reusable workflows must not default package versions                 | Accepted |
| [0002](0002-runtime-ci-hardening.md)                        | Use Harden-Runner for runtime CI hardening                           | Accepted |
| [0003](0003-task-runner-choice.md)                          | Use mise tasks as the task runner                                    | Accepted |
| [0004](0004-automerge-non-major-after-soak.md)              | Auto-merge all non-major updates after a soak period                 | Accepted |
| [0005](0005-pr-age-cooldown-for-untrusted-timestamps.md)    | PR-age cooldown for registries without a trusted release timestamp   | Accepted |
| [0006](0006-prebuilt-artifact-deploys.md)                   | Deploy prebuilt artifacts instead of passing credentials into builds | Accepted |
| [0007](0007-mandatory-release-please-app-authentication.md) | Require GitHub App authentication for Release Please                 | Accepted |
| [0008](0008-pages-custom-domain-registration.md)            | Register Pages domains without managing DNS                          | Accepted |
